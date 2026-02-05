pipelineJob("sample-ceph-pipeline") {
    displayName("Test: Sample Ceph Build Pipeline")
    description("A sample job to verify the Ceph build creation.")
    
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
            scriptPath("jobs/pipelines/sample_ceph_build_ci/Jenkinsfile")
        }

        // Add the required parameters for the job
        parameters {
            stringParam("CEPH_REPO", "https://github.com/ceph/ceph.git", "Ceph repository URL")
            stringParam("CEPH_BRANCH", "main", "Ceph branch to build")
            stringParam("BASE_VERSION", "20.0.0", "Base version of Ceph to build")
            choiceParam("DISTRO", ["centos"], "Distribution to build for")
            choiceParam("RELEASE", ["9"], "Release version")
            choiceParam("DIST", ["el9"], "Distribution version")
            choiceParam("FLAVOR", ["default"], "Build flavor")
            stringParam("RPM_BUILD_OPTS", "--with tcmalloc --without selinux --without lto", "Additional RPM build options")
        }
    }
}
