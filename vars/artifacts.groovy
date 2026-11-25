// Global var `artifacts` from the ceph-jenkins shared library.


def distroConfigs() {
    return distros.configs()
}

def config(String distro) {
    return distros.config(distro)
}

def initEnv() {
    // Recompute from JOB_NAME/BUILD_NUMBER; do not trust a shared env.SHARED_WS.
    def sharedWs = ceph.sharedWorkspace()
    env.SHARED_WS = sharedWs
    env.CEPH_DIR = "${sharedWs}/ceph"
    env.ARTIFACTS_DIR = "${sharedWs}/artifacts"
    if (!env.SHAMAN_CEPH_REPO_URL) {
        error("SHAMAN_CEPH_REPO_URL is not set (configure via Casc globalNodeProperties)")
    }
    env.BUILD_RPM = "${sharedWs}/deploy/images/agents/centos/build_rpm"
    env.BUILD_DEB = "${sharedWs}/deploy/images/agents/ubuntu/build_deb"
    // Consumed by deploy/.../build_rpm and build_deb.
    env.REPO_URL = env.REPO_URL ?: env.SHAMAN_CEPH_REPO_URL
    env.RPM_BUILD_OPTS = params.RPM_BUILD_OPTS ?: ""
    env.DEB_BUILD_OPTS = params.DEB_BUILD_OPTS ?: ""
}

def buildSelected(String distroParam = null, String archParam = null) {
    def selected = (distroParam ?: params.DISTRO).tokenize()
    def parallelStages = [:]

    selected.each { d ->
        def distro = d
        if (!distroConfigs().containsKey(distro)) {
            echo "Skipping ${distro}: no artifact config"
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
                    publish(distro)
                }
            }
        }
    }

    if (parallelStages.isEmpty()) {
        error("No DISTRO stages to run (DISTRO='${params.DISTRO}', ARCH='${params.ARCH}')")
    }
    parallel parallelStages
}

def packageDistro(String distro) {
    def cfg = config(distro)
    if (cfg.kind == "rpm") {
        buildRpm(distro, cfg)
    } else if (cfg.kind == "deb") {
        buildDeb(distro, cfg)
    } else {
        error("Unknown artifact kind '${cfg.kind}' for DISTRO='${distro}'")
    }
}

def buildRpm(String distro, Map cfg = null) {
    cfg = cfg ?: config(distro)
    def sharedWs = ceph.sharedWorkspace()
    def rpmBuildArea = "${sharedWs}/rpm/${distro}"
    def releaseBuildArea = "${sharedWs}/release/${distro}"

    echo "Running the Ceph RPM build script for ${cfg.display} ..."
    // withEnv is branch-local; env.RPM_BUILDAREA would race across parallel distros.
    withEnv([
        "RPM_BUILDAREA=${rpmBuildArea}",
        "RELEASE_BUILDAREA=${releaseBuildArea}",
        "DIST=${cfg.name}",
        "DIST_VERSION=${cfg.version}",
    ]) {
        dir("${sharedWs}/ceph") {
            sh "chmod +x ${env.BUILD_RPM} && ${env.BUILD_RPM}"
        }
    }
    collectRpmArtifacts(distro, cfg, rpmBuildArea)
}

def collectRpmArtifacts(String distro, Map cfg = null, String rpmBuildArea = null) {
    cfg = cfg ?: config(distro)
    def sharedWs = ceph.sharedWorkspace()
    def buildArea = rpmBuildArea ?: "${sharedWs}/rpm/${distro}"
    echo "RPMs for ${cfg.display} built successfully! Archiving ..."
    dir("${sharedWs}/artifacts/${distro}") {
        sh "mkdir -p x86_64 noarch SRPMS"
        sh """
            rsync -a \\
                ${buildArea}/RPMS/x86_64 \\
                ${buildArea}/RPMS/noarch \\
                ${buildArea}/SRPMS \\
                .
        """
    }
}

def buildDeb(String distro, Map cfg = null) {
    cfg = cfg ?: config(distro)
    def arch = cfg.arch ?: "x86_64"
    def sharedWs = ceph.sharedWorkspace()
    def debBuildArea = "${sharedWs}/deb/${cfg.version}"
    def releaseBuildArea = "${sharedWs}/release/${cfg.version}"

    echo "Running the Ceph DEB build script for ${cfg.display} ..."
    withEnv([
        "DIST=${cfg.name}",
        "DIST_VERSION=${cfg.version}",
        "DEB_BUILDAREA=${debBuildArea}",
        "RELEASE_BUILDAREA=${releaseBuildArea}",
        "ARCH=${arch}",
    ]) {
        dir("${sharedWs}/ceph") {
            sh "chmod +x ${env.BUILD_DEB} && ${env.BUILD_DEB}"
        }
    }
    collectDebArtifacts(distro, cfg, releaseBuildArea)
}

def collectDebArtifacts(String distro, Map cfg = null, String releaseBuildArea = null) {
    cfg = cfg ?: config(distro)
    def arch = cfg.arch ?: "x86_64"
    def sharedWs = ceph.sharedWorkspace()
    def releaseArea = releaseBuildArea ?: "${sharedWs}/release/${cfg.version}"
    echo "DEBs for ${cfg.display} built successfully! Archiving ..."
    dir("${sharedWs}/artifacts/${cfg.version}/${arch}") {
        sh """
            rsync -a \\
                ${releaseArea}/db \\
                ${releaseArea}/dists \\
                ${releaseArea}/pool \\
                .
        """
    }
}

def publish(String distro, String flavor = null) {
    def cfg = config(distro)
    def pubFlavor = flavor ?: (params.FLAVOR ?: "default")

    if (cfg.kind == "rpm") {
        pulp.publishDistroArtifacts(distro, pubFlavor)
    } else if (cfg.kind == "deb") {
        def arch = cfg.arch ?: "x86_64"
        pulp.configureClient()
        def artifactPath = "${ceph.sharedWorkspace()}/artifacts/${cfg.version}/${arch}/pool"
        if (fileExists(artifactPath)) {
            pulp.publishPackages(
                artifactPath, cfg.name, cfg.version, arch, pubFlavor
            )
        }
    } else {
        error("Unknown artifact kind '${cfg.kind}' for DISTRO='${distro}'")
    }

    echo "Published: ${env.PULP_SERVER_URL}/pulp/content/repos/ceph/${params.CEPH_BRANCH}/${env.SHA1}/${cfg.name}/${cfg.version}/flavors/${pubFlavor}/"
}
