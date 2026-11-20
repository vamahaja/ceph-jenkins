// Global var `ceph` from the ceph-jenkins shared library.


// Per-run id so concurrent builds do not share one directory on the RWX volume.
def runId() {
    def job = env.JOB_NAME
    def build = env.BUILD_NUMBER
    if (!job || !build) {
        error("JOB_NAME and BUILD_NUMBER are required for a per-run shared workspace")
    }
    def jobId = job.replaceAll("[^A-Za-z0-9._-]", "_")
    return "${jobId}/${build}"
}

def sharedWorkspace() {
    if (!env.SHARED_WORKSPACE) {
        error("SHARED_WORKSPACE is not set (configure via Casc globalNodeProperties)")
    }
    return "${env.SHARED_WORKSPACE}/${runId()}"
}

// Prefer env from initEnv(); fall back so post/cleanup never NPEs.
def resolveSharedWorkspace() {
    return env.SHARED_WS ?: sharedWorkspace()
}

def initEnv() {
    env.SHARED_WS = sharedWorkspace()
    env.CEPH_DIR = "${env.SHARED_WS}/ceph"
    env.ARTIFACTS_DIR = "${env.SHARED_WS}/artifacts"
    env.PULP_PROJECT_DIR = "${env.SHARED_WS}/pulp-project"
}

// OpenShift agents: remoting is jnlp; Nix/build tools are in builder. Podman is
// single-container, so container('builder') is skipped there.
def withBuilder(Closure body) {
    if (fileExists("/var/run/secrets/kubernetes.io/serviceaccount/namespace")) {
        container("builder") {
            body()
        }
    } else {
        body()
    }
}

def checkoutRepo(
    String cephDir = null,
    String repoUrl = null,
    String branch = null
) {
    def targetDir = cephDir ?: env.CEPH_DIR
    def url = repoUrl ?: params.CEPH_REPO
    def ref = branch ?: params.CEPH_BRANCH

    if (!targetDir) {
        error("CEPH_DIR is not set")
    }
    if (!url) {
        error("CEPH_REPO is not set")
    }
    if (!ref) {
        error("CEPH_BRANCH is not set")
    }

    echo "Checking out Ceph ${url} @ ${ref} into ${targetDir}"

    dir(targetDir) {
        checkout([
            $class: "GitSCM",
            branches: [[name: "${ref}"]],
            extensions: [
                [$class: "CleanBeforeCheckout",
                    deleteUntrackedNestedRepositories: true],
                [$class: "CloneOption", depth: 1, shallow: true,
                    noTags: false],
                [$class: "SubmoduleOption",
                    disableSubmodules: false,
                    parentCredentials: true,
                    recursiveSubmodules: true,
                    shallow: true]
            ],
            userRemoteConfigs: [[url: "${url}"]]
        ])
        sh(
            script: "git submodule status --recursive",
            label: "Verify submodules"
        )
        sh(
            script: "git fetch --tags --unshallow || git fetch --tags",
            label: "Fetch all tags"
        )
    }
}

// Set SHA1/VERSION and stage dist/ceph.spec + source tarball for RPM/DEB packaging.
def buildBinary(String cephDir = null) {
    def targetDir = cephDir ?: env.CEPH_DIR
    if (!targetDir) {
        error("CEPH_DIR is not set")
    }

    echo "Building Ceph binary artifacts in ${targetDir} ..."

    dir(targetDir) {
        env.SHA1 = sh(
            script: "git rev-parse HEAD 2>/dev/null || echo \"unknown\"",
            returnStdout: true
        ).trim()

        def version = sh(
            script: "git describe --abbrev=8 --match \"v*\" --always",
            returnStdout: true
        ).trim()
        if (version.startsWith("v")) {
            version = version.substring(1)
        }
        // Replace the second '-' with '.' (e.g. 19.2.0-123-gabcdef -> 19.2.0-123.gabcdef)
        def secondDash = version.indexOf("-", version.indexOf("-") + 1)
        if (secondDash > 0) {
            version = version.substring(0, secondDash) + "." + version.substring(secondDash + 1)
        }
        env.VERSION = version

        if (!fileExists("ceph.spec.in")) {
            error("ceph.spec.in not found; run from the Ceph source tree root")
        }

        def tarball = "ceph-${env.VERSION}"
        def lastDash = env.VERSION.lastIndexOf("-")
        def projectVersion = lastDash >= 0 ? env.VERSION.substring(0, lastDash) : env.VERSION
        def rpmRelease = lastDash >= 0 ? env.VERSION.substring(lastDash + 1) : env.VERSION

        def spec = readFile("ceph.spec.in")
            .replace("@TARBALL_BASENAME@", tarball)
            .replace("@PROJECT_VERSION@", projectVersion)
            .replace("@RPM_RELEASE@", rpmRelease)
        spec = spec
            .replaceAll(/(?m)^%setup.*/, "%setup -q -n %{name}-${env.VERSION}")
            .replaceAll(/(?m)^%autosetup.*/, "%autosetup -p1 -n %{name}-${env.VERSION}")
            .replace("%{name}-%{version}", tarball)

        if (!fileExists("src")) {
            error("src/ not found; run from the Ceph source tree root")
        }
        sh "mkdir -p dist"
        writeFile file: "dist/ceph.spec", text: spec
        writeFile file: "src/.git_version", text: "${env.SHA1}\n${tarball}\n"

        echo "Staging source for tarball..."
        sh """
            set -ex
            STAGING_DIR=\$(mktemp -d)
            rsync -a --exclude=".git" --exclude="rpm" . "\${STAGING_DIR}/${tarball}"
            tar -cjf "dist/${tarball}.tar.bz2" -C "\${STAGING_DIR}" "${tarball}"
        """
    }
}
