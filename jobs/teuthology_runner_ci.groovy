// Define the job configurations
def jobConfigurations = []

// Generate the job
def generateJob(data) {
    data.jobConfiguration.add([
        "name": "${data.branch.toLowerCase()}-teuthology-runner-ci",
        "displayName": "${data.branch}: Teuthology Runner",
        "description": "A job to run teuthology tests for the ${data.branch} branch",
        "branch": data.branch.toLowerCase()
    ])
}

// Generate job for the main branch
generateJob(jobConfiguration: jobConfigurations, branch: "Main")

// Generate job for the Tentacle branch
generateJob(jobConfiguration: jobConfigurations, branch: "Tentacle")

// Generate the jobs
for (jobConfig in jobConfigurations) {
    def job = pipelineJob(jobConfig.name) {
        // Add the display name for the job
        displayName(jobConfig.displayName)

        // Add the description for the job
        description(jobConfig.description)

        // Add the definition for the job
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
                scriptPath("jobs/pipelines/teuthology_runner_ci/Jenkinsfile")
            }

            // Add the required parameters for the job
            parameters {
                choiceParam("BRANCH", [jobConfig.branch], "Ceph branch to build")
                booleanParam("SMOKE", false, "Run smoke tests")
                booleanParam("RGW", false, "Run rgw tests")
                booleanParam("CEPHFS", false, "Run cephfs tests")
                booleanParam("RBD", false, "Run rbd tests")
                booleanParam("ISCSI", false, "Run iscsi tests")
                booleanParam("NFS", false, "Run nfs tests")
            }
        }
    }
}
