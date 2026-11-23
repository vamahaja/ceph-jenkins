# Ceph Jenkins

This repository provides the configuration and deployment logic for a containerized Jenkins controller used in Ceph Storage pipelines.

## Getting Started

### Prerequisites

Before deploying the containerized controller, ensure the following requirements are met:

* **Container Runtime (Podman path)**: Podman or Docker must be installed on the host machine.
* **OpenShift path**: `oc` and Helm 3; cluster must pull your pushed controller/agent images (see [`deploy/openshift/README.md`](deploy/openshift/README.md)).

* **Configuration Files and Directories:** The following are important files and directories -
    * `deploy/images`: Custom Jenkins controller & agent image definitions (Containerfiles).
    * `deploy/images/create-images.sh`: Builds controller and agent images.
    * `deploy/images/controller/plugins.txt`: Lists all required plugins.
    * `deploy/podman`: Podman deployment ([`deploy/podman/README.md`](deploy/podman/README.md)).
    * `deploy/openshift`: Helm chart to deploy the Jenkins controller on OpenShift ([`deploy/openshift/README.md`](deploy/openshift/README.md)).
    * `casc/base.yaml`: Shared JCasC (security, Job DSL, seed, UI).
    * `casc/clouds-podman.yaml`: Podman/Docker agent cloud (used by Podman deploy).
    * `casc/clouds-openshift.yaml`: Kubernetes agent cloud (used by OpenShift deploy).
    * `properties.yaml`: Actual environment configurations / secrets template.
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

### Deployment (OpenShift)

Deploy the Jenkins controller to an OpenShift cluster with the Helm chart under `deploy/openshift`. See [`deploy/openshift/README.md`](deploy/openshift/README.md) for full details.

1. **Create Properties:** Same as Podman — use `$HOME/jenkins_config/properties.yaml` (or another filled-in copy of `properties.yaml`).

2. **Build and push images:** Build with `./deploy/images/create-images.sh`, then tag/push the controller image to a registry the cluster can pull.

3. **Install the chart:** Push controller **and** agent images, then install with an agent image prefix (see [`deploy/openshift/README.md`](deploy/openshift/README.md)):
    ```sh
    helm upgrade --install ceph-jenkins ./deploy/openshift \
      --namespace ceph-jenkins \
      --set image.repository=<registry>/<namespace>/ceph-jenkins-controller \
      --set agentImages.prefix=<registry>/<namespace>/ \
      --set-file cascBaseContent=./casc/base.yaml \
      --set-file cascCloudsContent=./casc/clouds-openshift.yaml \
      --set-file seedContent=./jobs/seed.groovy \
      --set-file propertiesContent=$HOME/jenkins_config/properties.yaml
    ```

4. **Bootstrap Jobs:** Same as Podman — JCasC runs `seed.groovy` on startup.

> **Notes:** OpenShift agents use `casc/clouds-openshift.yaml` (one container named `jnlp`, the distro image, `command: jenkins-agent`). The shared-workspace PVC is that container's workspace volume at `/workspace`. CentOS, Rocky, Ubuntu, and buildah agents need a privileged SCC. See [`deploy/openshift/README.md`](deploy/openshift/README.md).

### Logging

* **Controller Logs (Podman):** `podman logs -f jenkins-controller`
* **Controller Logs (OpenShift):** `oc logs -f deploy/ceph-jenkins -n <namespace>`
* **Builder Logs (Podman):** Often via `journalctl` on the host during agent builds
* **Agent Logs (OpenShift):** `oc logs` on the agent pod (single `jnlp` container)
