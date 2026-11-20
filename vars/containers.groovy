// Global var `containers` from the ceph-jenkins shared library.


// Shared distro identity from distros.*; overlay buildah-specific fields.
def distroConfigs() {
    return [
        centos9: distros.config("centos9") + [
            label    : "ceph-build-buildah-agent",
            fromImage: "quay.io/centos/centos:stream9",
            arch     : "x86_64",
            baseos   : "centos-stream9",
        ],
        rocky10: distros.config("rocky10") + [
            label    : "ceph-build-buildah-agent",
            fromImage: "docker.io/rockylinux/rockylinux:10",
            arch     : "x86_64",
            baseos   : "rocky-10",
        ],
    ]
}

def config(String distro) {
    def cfg = distroConfigs()[distro]
    if (!cfg) {
        error("No container config for DISTRO='${distro}'")
    }
    return cfg
}

def buildSelected(String distroParam = null, String archParam = null) {
    def selected = (distroParam ?: params.DISTRO).tokenize()
    def parallelStages = [:]

    selected.each { d ->
        def distro = d
        if (!distroConfigs().containsKey(distro)) {
            echo "Skipping ${distro}: no container image config"
            return
        }
        if (distros.skipUnsupportedArch(distro, archParam)) {
            return
        }
        def cfg = config(distro)
        parallelStages[cfg.display] = {
            node(cfg.label) {
                buildImage(distro)
                pulp.publishImage()
            }
        }
    }

    if (parallelStages.isEmpty()) {
        error("No DISTRO stages to run (DISTRO='${params.DISTRO}', ARCH='${params.ARCH}')")
    }
    parallel parallelStages
}

def buildImage(String distro, Map cfg = null) {
    cfg = cfg ?: config(distro)

    env.FROM_IMAGE = cfg.fromImage
    env.DISTRO = cfg.name
    env.RELEASE = "${cfg.version}"
    env.ARCH = cfg.arch ?: "x86_64"
    env.BASEOS = cfg.baseos
    env.SHA1 = params.SHA1
    env.VERSION = params.VERSION
    env.REPO_URL = pulp.contentRepoUrl(
        params.CEPH_BRANCH, env.SHA1, env.DISTRO, env.RELEASE, params.FLAVOR
    )

    if (!env.SHA1 || !env.VERSION) {
        error("SHA1 and VERSION params are required to build container images")
    }
    if (!env.FROM_IMAGE || !env.REPO_URL) {
        error("FROM_IMAGE and REPO_URL must be set before buildah")
    }

    echo "Building Ceph container image for ${cfg.display} ..."

    def workDir = env.CEPH_DIR ?: env.SHARED_WS
    dir(workDir) {
        def imageTag = "${env.DISTRO}-${env.RELEASE}-${env.ARCH}-${env.SHA1}"
        def repoText = libraryResource("containers/ceph.repo.template")
            .replace("@REPO_URL@", env.REPO_URL)
        writeFile file: "ceph.repo", text: repoText

        def cntr = buildahFrom(env.FROM_IMAGE)
        buildahRun(cntr, "dnf install -y epel-release dnf-plugins-core")
        buildahRun(cntr, "dnf config-manager --set-enabled crb")
        buildahCopy(cntr, "ceph.repo", "/etc/yum.repos.d/ceph.repo")
        buildahRun(cntr, "dnf install -y ceph ceph-common ceph-osd ceph-mon ceph-mgr")
        buildahConfig(cntr, "--env CEPH_SHA1='${env.SHA1}'")
        buildahConfig(cntr, "--label ceph.version='${env.VERSION}'")
        buildahConfig(cntr, "--label 'maintainer=Ceph CI/CD'")
        buildahConfig(cntr, """--cmd '["/usr/bin/ceph"]'""")
        buildahCommit(cntr, imageTag)
        buildahImages(imageTag)
        echo "Successfully built ${imageTag}"
    }
}

def buildahFrom(String fromImage) {
    // buildah may print warnings on stdout; container id is the last non-empty line.
    def out = sh(
        script: "sudo buildah from '${fromImage}'",
        returnStdout: true
    ).trim()
    def lines = out.readLines().collect { it.trim() }.findAll { it }
    if (!lines) {
        error("buildah from '${fromImage}' produced no container id")
    }
    return lines.last()
}

def buildahRun(String container, String command) {
    sh "sudo buildah run '${container}' -- ${command}"
}

def buildahCopy(String container, String src, String dest) {
    sh "sudo buildah copy '${container}' '${src}' '${dest}'"
}

def buildahConfig(String container, String args) {
    sh "sudo buildah config ${args} '${container}'"
}

def buildahCommit(String container, String imageTag) {
    sh "sudo buildah commit '${container}' '${imageTag}'"
}

def buildahImages(String imageTag) {
    sh "sudo buildah images '${imageTag}'"
}
