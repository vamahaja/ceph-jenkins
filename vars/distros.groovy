// Global var `distros` from the ceph-jenkins shared library.
// Shared distro identity used by artifacts, nix, containers, and pulp helpers.


def configs() {
    return [
        centos9: [
            label  : "ceph-build-centos9-agent",
            kind   : "rpm",
            name   : "centos",
            version: "9",
            display: "CentOS 9.Stream",
        ],
        rocky10: [
            label  : "ceph-build-rocky10-agent",
            kind   : "rpm",
            name   : "rocky",
            version: "10",
            display: "Rocky Linux 10",
        ],
        jammy: [
            label  : "ceph-build-ubuntu-jammy-agent",
            kind   : "deb",
            name   : "ubuntu",
            version: "jammy",
            arch   : "x86_64",
            display: "Ubuntu 22.04 (jammy)",
        ],
        noble: [
            label  : "ceph-build-ubuntu-noble-agent",
            kind   : "deb",
            name   : "ubuntu",
            version: "noble",
            arch   : "x86_64",
            display: "Ubuntu 24.04 (noble)",
        ],
    ]
}

def config(String distro) {
    def cfg = configs()[distro]
    if (!cfg) {
        error("No distro config for DISTRO='${distro}'")
    }
    return cfg
}

def byKind(String kind) {
    return configs().findAll { _, cfg -> cfg.kind == kind }
}

def supportedArches() {
    return ["x86_64"]
}

def skipUnsupportedArch(String distro, String archParam = null) {
    def requested = archParam ?: params.ARCH
    def arches = requested.tokenize()
    if (arches.any { supportedArches().contains(it) }) {
        return false
    }
    echo "Skipping ${distro}: ARCH=${requested} not supported yet"
    return true
}
