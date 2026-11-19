// Global var `pulp` from the ceph-jenkins shared library.


def checkoutProject(String pulpProjectDir = null, String branch = "main") {
    def projectDir = pulpProjectDir ?: env.PULP_PROJECT_DIR
    if (!projectDir) {
        error("PULP_PROJECT_DIR is not set")
    }
    if (!env.PULP_PROJECT_REPO) {
        error("PULP_PROJECT_REPO is not set")
    }

    dir(projectDir) {
        checkout([
            $class: "GitSCM",
            branches: [[name: branch]],
            extensions: [
                [$class: "CloneOption", depth: 1, shallow: true, noTags: true]
            ],
            userRemoteConfigs: [
                [url: "${env.PULP_PROJECT_REPO}"]
            ]
        ])
    }
    sh "chmod +x ${projectDir}/scripts/*.sh"
}

def configureClient(String pulpProjectDir = null) {
    def projectDir = pulpProjectDir ?: env.PULP_PROJECT_DIR
    if (!projectDir) {
        error("PULP_PROJECT_DIR is not set")
    }

    withCredentials([usernamePassword(
        credentialsId: "pulp-credentials",
        usernameVariable: "PULP_USER",
        passwordVariable: "PULP_PASS"
    )]) {
        sh """
            ${projectDir}/scripts/configure-client.sh \
                --username "\$PULP_USER" \
                --password "\$PULP_PASS" \
                --overwrite
        """
    }
}

def publishPackages(
    String artifactPath,
    String distro,
    String distroVersion,
    String arch,
    String flavor = "default"
) {
    def projectDir = env.PULP_PROJECT_DIR
    if (!projectDir) {
        error("PULP_PROJECT_DIR is not set")
    }
    def publishScript = "${projectDir}/scripts/publish-packages.sh"

    sh """
        set -e
        ${publishScript} '${artifactPath}' \
            --branch '${params.CEPH_BRANCH}' \
            --sha1 '${env.SHA1}' \
            --version '${env.VERSION}' \
            --distro '${distro}' \
            --distro-version '${distroVersion}' \
            --arch '${arch}' \
            --flavor '${flavor}'
    """
}

def publishDistroArtifacts(String flakeDistro, String flavor = "default") {
    def artifactsDir = env.ARTIFACTS_DIR
    if (!artifactsDir) {
        error("ARTIFACTS_DIR is not set")
    }

    def name = distName(flakeDistro)
    def version = distVersion(flakeDistro)
    configureClient()
    ["x86_64", "noarch", "SRPMS"].each { arch ->
        def artifactPath = "${artifactsDir}/${flakeDistro}/${arch}"
        if (fileExists(artifactPath)) {
            publishPackages(artifactPath, name, version, arch, flavor)
        }
    }
}

def distName(String flakeDistro) {
    if (flakeDistro.startsWith("centos")) {
        return "centos"
    }
    if (flakeDistro.startsWith("rocky")) {
        return "rocky"
    }
    if (flakeDistro.startsWith("fedora")) {
        return "fedora"
    }
    return flakeDistro
}

def distVersion(String flakeDistro) {
    // Avoid java.util.Matcher in Pipeline CPS (not reliably serializable).
    def prefix = ["centos", "rocky", "fedora"].find { flakeDistro.startsWith(it) }
    if (!prefix) {
        return flakeDistro
    }
    def rest = flakeDistro.substring(prefix.length())
    return rest ==~ /^\d+$/ ? rest : flakeDistro
}

// Pulp RPM content URL used as yum baseurl when building container images.
def contentRepoUrl(
    String branch = null,
    String sha1 = null,
    String distro = null,
    String distroVersion = null,
    String flavor = null
) {
    def b = branch ?: params.CEPH_BRANCH
    def s = sha1 ?: env.SHA1
    def d = distro ?: env.DISTRO ?: env.DIST
    def v = distroVersion ?: env.RELEASE ?: env.DIST_VERSION
    def f = flavor ?: (params.FLAVOR ?: "default")

    if (!env.PULP_SERVER_URL) {
        error("PULP_SERVER_URL is not set")
    }
    if (!b || !s || !d || !v) {
        error("contentRepoUrl requires branch, sha1, distro, and distroVersion")
    }

    return "${env.PULP_SERVER_URL}/pulp/content/repos/ceph/${b}/${s}/${d}/${v}/flavors/${f}/"
}

// Push a container image to the Pulp registry (ceph-ci/ceph tag convention):
//   SHA1, BRANCH-SHORTSHA1-BASEOS-ARCH-devel, BRANCH
def publishImage(
    String imageTag = null,
    String baseos = null,
    String arch = null,
    String basePath = "ceph-ci"
) {
    def tag = imageTag ?: "${env.DISTRO}-${env.RELEASE}-${env.ARCH}-${env.SHA1}"
    def os = baseos ?: env.BASEOS
    def a = arch ?: env.ARCH
    if (!env.SHA1 || !os || !a || !params.CEPH_BRANCH) {
        error("publishImage requires SHA1, BASEOS, ARCH, and CEPH_BRANCH")
    }

    def shortSha = env.SHA1.take(7)
    def develTag = "${params.CEPH_BRANCH}-${shortSha}-${os}-${a}-devel"
    def tags = [env.SHA1, develTag, params.CEPH_BRANCH]

    def projectDir = env.PULP_PROJECT_DIR
    if (!projectDir) {
        error("PULP_PROJECT_DIR is not set")
    }
    def publishScript = "${projectDir}/scripts/publish-image.sh"
    if (!env.PULP_SERVER_URL) {
        error("PULP_SERVER_URL is not set")
    }

    withCredentials([usernamePassword(
        credentialsId: "pulp-credentials",
        usernameVariable: "PULP_USER",
        passwordVariable: "PULP_PASS"
    )]) {
        tags.each { t ->
            sh """
                sudo bash ${publishScript} \
                    --image '${tag}' \
                    --registry '${env.PULP_SERVER_URL}' \
                    --base-path '${basePath}' \
                    --tag '${t}' \
                    --username "\$PULP_USER" \
                    --password "\$PULP_PASS"
            """
        }
    }

    tags.each { t ->
        echo "Published: ${env.PULP_SERVER_URL}/v2/${basePath}/ceph:${t}"
    }
}
