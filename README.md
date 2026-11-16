# Ceph Jenkins

This repository provides the configuration and deployment logic for a containerized Jenkins controller used in Ceph Storage pipelines.

## Getting Started

### Prerequisites

Before deploying the containerized controller, ensure the following requirements are met:

* **Container Runtime**: Podman or Docker must be installed on the host machine.

* **Configuration Files and Directories:** The following are important files and directories -
    * `deploy/images`: Custom Jenkins controller & agent image definitions (Containerfiles).
    * `deploy/images/create-images.sh`: Builds controller and agent images.
    * `deploy/images/controller/plugins.txt`: Lists all required plugins.
    * `deploy/podman`: Podman deployment ([`deploy/podman/README.md`](deploy/podman/README.md)).
    * `casc/base.yaml`: Shared JCasC (security, Job DSL, seed, UI).
    * `casc/clouds-podman.yaml`: Podman/Docker agent cloud used by Podman deploy.
    * `properties.yaml`: Actual environment configurations.
    * `jobs/seed.groovy`: The initial script to bootstrap the job-processing logic.
    * `$HOME/jenkins_config`: Jenkins configs (properties.yaml, jenkins_home & shared_workspace)

### Deployment (Podman)

Full host setup, Casc mounts, image list, and verify steps: [`deploy/podman/README.md`](deploy/podman/README.md).

```sh
mkdir -p $HOME/jenkins_config
# Copy and edit properties.yaml into $HOME/jenkins_config/properties.yaml
systemctl --user enable --now podman.socket
sudo loginctl enable-linger $(id -u)
./deploy/images/create-images.sh
./deploy/podman/deploy-containers.sh
```

Login at http://localhost:8080. JCasC runs `seed.groovy` on startup; run the Seed job from the UI to generate project pipelines.

### Logging

* **Controller Logs:** `podman logs -f jenkins-controller`
* **Builder Logs:** Often via `journalctl` on the host during agent builds
