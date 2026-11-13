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
    * `deploy/podman`: Podman deployment scripts.
    * `deploy/podman/deploy-containers.sh`: Deploys the Jenkins controller container with Podman.
    * `deploy/openshift`: Helm chart to deploy the Jenkins controller on OpenShift.
    * `casc/base.yaml`: Shared JCasC (security, Job DSL, seed, UI).
    * `casc/clouds-podman.yaml`: Podman/Docker agent cloud (used by Podman deploy).
    * `casc/clouds-openshift.yaml`: Kubernetes agent cloud (used by OpenShift deploy).
    * `properties.yaml`: Actual environment configurations / secrets template.
    * `jobs/seed.groovy`: The initial script to bootstrap the job-processing logic.
    * `$HOME/jenkins_config`: Jenkins configs (properties.yaml, jenkins_home & shared_workspace)

### Deployment Steps (Podman)

Deployment follows "Configuration as Code" workflow to maintain the repository as the single source of truth.

1. **Create Config Directory**: Create Jenkins home directory for Jenkins config and shared workspace
    ```sh
    mkdir -p $HOME/jenkins_config
    ```

2. **Create Properties:** Create `$HOME/jenkins_config/properties.yaml` with your real-world Jenkins configs. This "hydrates" the shared Casc with your actual cluster details and secrets.

3. **Start socket service:** This will enable and start the socket for user.
    ```sh
    systemctl --user enable --now podman.socket
    ```

4. **Verify socket exists:** Verify the socket now exists for user id.
    ```sh
    ls -l /run/user/$(id -u)/podman/podman.sock
    ```

5. **Enable "Linger":** This will keep services running after user logout.
    ```sh
    sudo loginctl enable-linger $(id -u)
    ```

6. **Set Execute Permissions:** Set execute permissions on the deploy scripts.
    ```sh
    chmod +x ./deploy/images/create-images.sh ./deploy/podman/deploy-containers.sh
    ```

7. **Create Images:** Build controller and agent images.
    ```sh
    ./deploy/images/create-images.sh
    ```

8. **Deploy Containers:** Deploy the `jenkins-controller` container.
    ```sh
    ./deploy/podman/deploy-containers.sh
    ```

9. **Bootstrap Jobs:** Upon startup, JCasC will automatically execute `seed.groovy` to create the `Seed Job` job.

10. **Process Project Jobs:** Run the `Seed` from the Jenkins UI, providing the relative path to your project's Groovy definitions to generate project-specific pipelines.

### Deployment Steps (OpenShift)

Deploy the Jenkins controller to an OpenShift cluster with the Helm chart under `deploy/openshift`. See [`deploy/openshift/README.md`](deploy/openshift/README.md) for full details.

1. **Create Properties:** Same as Podman — use `$HOME/jenkins_config/properties.yaml` (or another filled-in copy of `properties.yaml`).

2. **Build and push images:** Build with `./deploy/images/create-images.sh`, then tag/push the controller image to a registry the cluster can pull.

3. **Install the chart:**
    ```sh
    helm upgrade --install ceph-jenkins ./deploy/openshift \
      --namespace ceph-jenkins \
      --set image.repository=<registry>/<namespace>/ceph-jenkins-controller \
      --set image.tag=latest \
      --set-file cascBaseContent=./casc/base.yaml \
      --set-file cascCloudsContent=./casc/clouds-openshift.yaml \
      --set-file seedContent=./jobs/seed.groovy \
      --set-file propertiesContent=$HOME/jenkins_config/properties.yaml
    ```

4. **Bootstrap Jobs:** Same as Podman — JCasC runs `seed.groovy` on startup.

> **Note:** OpenShift agents use the Kubernetes cloud (`casc/clouds-openshift.yaml`). Build steps should run in `container('builder') { ... }`. See [`deploy/openshift/README.md`](deploy/openshift/README.md).

### Logging

The Ceph Jenkins environment utilizes multiple logging layers to ensure visibility across the "controller/builder" architecture.

* **Controller Logs (Podman):** Monitor the startup and JCasC initialization via `podman logs -f jenkins-controller`.
* **Controller Logs (OpenShift):** `oc logs -f deploy/ceph-jenkins -n <namespace>`.
* **Builder Logs:** Detailed system logs are often captured during build execution using `journalctl`.
