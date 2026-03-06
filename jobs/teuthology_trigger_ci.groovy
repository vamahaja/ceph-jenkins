// Define the job configurations
def jobConfigurations = []

// Generate the job
def generateJob(data) {
    data.jobConfiguration.add([
        "name": "${data.branch.toLowerCase()}-teuthology-${data.type.toLowerCase()}-trigger",
        "displayName": "${data.branch}: Teuthology ${data.type} Trigger",
        "description": "A job to trigger teuthology tests for the ${data.branch} branch",
        "branch": data.branch.toLowerCase(),
        "type": data.type.toLowerCase(),
        "cronExpr": data.cronExpr
    ])
}

// Generate job for the daily smoke tests
generateJob(jobConfiguration: jobConfigurations, branch: "Main", type: "Daily", cronExpr: "")
generateJob(jobConfiguration: jobConfigurations, branch: "Tentacle", type: "Daily", cronExpr: "")

// Generate job for the weekly smoke tests
generateJob(jobConfiguration: jobConfigurations, branch: "Main", type: "Weekly", cronExpr: "")
generateJob(jobConfiguration: jobConfigurations, branch: "Tentacle", type: "Weekly", cronExpr: "")

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
                scriptPath("jobs/pipelines/teuthology_trigger_ci/Jenkinsfile")
            }

            // Add the cron expression for the job
            if (jobConfig.cronExpr) {
                triggers {
                    cron(expression: jobConfig.cronExpr)
                }
            }

            // Add the required parameters for the job
            parameters {
                choiceParam("TYPE", [jobConfig.type], "Type of build to schedule")
                choiceParam("BRANCH", [jobConfig.branch], "Ceph branch to build")
            }
        }
    }
}
