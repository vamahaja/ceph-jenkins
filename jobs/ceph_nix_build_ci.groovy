pipelineJob("ceph-nix-build-pipeline") {
    displayName("Ceph: Nix Build Pipeline")
    description("Ceph RPMs via flake.nix: make-dist + on-host mock/hermetic.")

    definition {
        cpsScm {
            scm {
                git {
                    remote {
                        url("https://github.com/vamahaja/ceph-jenkins.git")
                    }
                    branches("main")
                }
            }
            scriptPath("jobs/pipelines/ceph_nix_build_ci/Jenkinsfile")
        }

        parameters {
            stringParam(
                "CEPH_REPO",
                "https://github.com/vamahaja/ceph.git",
                "Ceph repository URL (needs flake.nix)"
            )
            stringParam(
                "CEPH_BRANCH",
                "nix-build",
                "Ceph branch with flake.nix (e.g. nix-build)"
            )
            stringParam(
                "DISTRO",
                "centos9 rocky10",
                "Space-separated flake distro apps (centos9 rocky10)"
            )
            stringParam("ARCH", "x86_64", "Architecture to build for")
            choiceParam(
                "BUILD_MODE",
                ["normal", "source-only", "hermetic-lock", "hermetic"],
                "Packaging mode (hermetic runs hermetic-lock then hermetic package rebuild in one cell)"
            )
            booleanParam("PUBLISH_ARTIFACTS", false, "Publish built packages to Pulp")
        }
    }
}
