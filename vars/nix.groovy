// Global var `nix` from the ceph-jenkins shared library.


def nixProfileBin() {
    return "/nix/var/nix/profiles/default/bin"
}

def nixBin() {
    return "${nixProfileBin()}/nix"
}

def makeDistAgent() {
    return "ceph-build-fedora39-agent"
}

// Kubernetes agents inherit PATH from the jnlp container (no Nix). Always prepend
// the image Nix profile for builder `sh` steps.
def withNixPath(Closure body) {
    def basePath = env.PATH ?: "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    def nixPath = nixProfileBin()
    def path = basePath.split(":").contains(nixPath) ? basePath : "${nixPath}:${basePath}"
    env.PATH = path
    withEnv(["PATH=${path}"]) {
        body()
    }
}

def initEnv() {
    withNixPath {
        echo "Using nix at ${nixBin()}"
    }
}

// Flake packaging uses shared RPM distro entries (centos9, rocky10).
def distroConfigs() {
    return distros.byKind("rpm")
}

def config(String distro) {
    def cfg = distroConfigs()[distro]
    if (!cfg) {
        error("No nix packaging config for DISTRO='${distro}'")
    }
    return cfg
}

def buildSelected(String distroParam = null, String archParam = null) {
    def selected = (distroParam ?: params.DISTRO).tokenize()
    def parallelStages = [:]

    selected.each { d ->
        def distro = d
        if (!distroConfigs().containsKey(distro)) {
            echo "Skipping ${distro}: no nix packaging config"
            return
        }
        if (distros.skipUnsupportedArch(distro, archParam)) {
            return
        }
        def cfg = config(distro)
        parallelStages[cfg.display] = {
            node(cfg.label) {
                packageDistro(distro)
                if (params.PUBLISH_ARTIFACTS) {
                    pulp.publishDistroArtifacts(distro)
                }
            }
        }
    }

    if (parallelStages.isEmpty()) {
        error(
            "No DISTRO stages to run (DISTRO='${params.DISTRO}', ARCH='${params.ARCH}')"
        )
    }
    parallel parallelStages
}

def buildDriverInvocations(String buildMode) {
    switch (buildMode) {
        case "source-only":
            return ["source-only on-host"]
        case "hermetic-lock":
            return ["hermetic-lock on-host"]
        case "hermetic":
            // Lock BuildRequires, then offline package rebuild (not the agent image).
            return ["hermetic-lock on-host", "hermetic on-host"]
        case "normal":
        default:
            return ["on-host"]
    }
}

def makeDist(String cephDir = null) {
    def targetDir = cephDir ?: env.CEPH_DIR
    if (!targetDir) {
        error("CEPH_DIR is not set")
    }

    dir(targetDir) {
        env.SHA1 = sh(
            script: "git rev-parse HEAD 2>/dev/null || echo unknown",
            returnStdout: true
        ).trim()
        // Match build-driver ceph_rpm_version() so Stage 2 reuses this tarball.
        def described = sh(
            script: "git describe --match 'v*'",
            returnStdout: true
        ).trim()
        env.CEPH_VERSION = described.replaceFirst(/^v/, "")
        env.VERSION = env.CEPH_VERSION

        echo "Shared make-dist via flake (CEPH_VERSION=${env.CEPH_VERSION})"
        withNixPath {
            // Absolute path: build env PATH comes from jnlp and omits Nix.
            sh "${nixBin()} --version"
            withEnv(["CEPH_VERSION=${env.CEPH_VERSION}"]) {
                sh "${nixBin()} develop .#packages -c ./make-dist \"\$CEPH_VERSION\""
            }
        }
        def tarball = "ceph-${env.CEPH_VERSION}.tar.bz2"
        if (!fileExists(tarball)) {
            error("Expected ${tarball} after make-dist")
        }
    }
}

def packageDistro(String distro, String buildMode = null) {
    def mode = buildMode ?: params.BUILD_MODE
    def targetDir = env.CEPH_DIR
    if (!targetDir) {
        error("CEPH_DIR is not set")
    }

    def invocations = buildDriverInvocations(mode)
    dir(targetDir) {
        invocations.each { modeArgs ->
            echo "Packaging ${distro}: build-driver.sh ${distro} ${modeArgs}"
            runOnHostPackaging(distro, modeArgs)
        }
    }
    collectArtifacts(distro)
}

def runOnHostPackaging(String distro, String modeArgs) {
    def tarball = "ceph-${env.CEPH_VERSION}.tar.bz2"
    if (!fileExists(tarball)) {
        error("Missing ${tarball}; run make-dist first")
    }

    // Workspace tree has .git; on-host skips nested thin-image podman.
    withNixPath {
        sh "command -v mock"
        withEnv(["CEPH_VERSION=${env.CEPH_VERSION}"]) {
            sh "${nixBin()} develop .#packages -c ./nix/build-driver.sh ${distro} ${modeArgs}"
        }
    }
}

def syncDir(String src, String dest) {
    if (!fileExists(src)) {
        return
    }
    sh "mkdir -p '${dest}' && rsync -a '${src}/' '${dest}/'"
}

def collectArtifacts(String distro) {
    def cephDir = env.CEPH_DIR
    def artifactsDir = env.ARTIFACTS_DIR
    if (!cephDir || !artifactsDir) {
        error("CEPH_DIR and ARTIFACTS_DIR must be set")
    }
    def outDir = "${artifactsDir}/${distro}"
    def rpmbuild = "${cephDir}/rpmbuild"

    ["x86_64", "noarch", "SRPMS", "hermetic"].each { subdir ->
        sh "mkdir -p '${outDir}/${subdir}'"
    }

    syncDir("${rpmbuild}/RPMS/x86_64", "${outDir}/x86_64")
    syncDir("${rpmbuild}/RPMS/noarch", "${outDir}/noarch")
    syncDir("${rpmbuild}/SRPMS", "${outDir}/SRPMS")

    // mock --resultdir often drops RPMs directly under rpmbuild/
    if (fileExists(rpmbuild)) {
        dir(rpmbuild) {
            findFiles(glob: "*.rpm").each { f ->
                def dest = f.name.endsWith(".src.rpm") \
                    ? "${outDir}/SRPMS" : "${outDir}/x86_64"
                sh "cp -f '${f.name}' '${dest}/'"
            }
        }
    }

    if (fileExists(cephDir)) {
        dir(cephDir) {
            findFiles(glob: "ceph-*.src.rpm").each { f ->
                sh "cp -f '${f.name}' '${outDir}/SRPMS/'"
            }
        }
    }

    syncDir("${rpmbuild}/hermetic/${distro}", "${outDir}/hermetic")
}
