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
                    branches("centos-stream9-build-pipeline")
                }
            }
            scriptPath("jobs/pipelines/sample_ceph_build_ci/Jenkinsfile")
        }

        // Add the required parameters for the job
        parameters {
            stringParam("CEPH_REPO", "https://github.com/ceph/ceph.git", "Ceph repository URL")
            stringParam("CEPH_BRANCH", "main", "Ceph branch to build")
        }
    }
}
