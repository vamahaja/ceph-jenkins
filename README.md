# Ceph Jenkins

This repository provides the configuration and deployment logic for a containerized Jenkins controller used in Ceph Storage pipelines.

## Getting Started

### Prerequisites

Before deploying the containerized controller, ensure the following requirements are met:

* **Container Runtime**: Podman or Docker must be installed on the host machine.

* **Configuration Files:** The following files important configuration files -
    * `Containerfile.controller`: To build the custom Jenkins image.
    * `Containerfile.agent`: To build the custom agent image.
    * `plugins.txt`: Listing required plugins.
    * `casc.yaml`: Defining system-level configurations.
    * `properties.yaml`: Actual environment settings.
    * `jobs/seed.groovy`: The initial script to bootstrap the job-processing logic.

### Deployment Steps

Deployment follows "Configuration as Code" workflow to maintain the repository as the single source of truth.

1. **Build Controller Image:** Create the custom controller image using the provided `Containerfile.controller`. This process pre-installs all plugins from `plugins.txt`:
    ```sh
    podman build -f Containerfile.controller -t ceph-jenkins-controller:latest
    ```

2. **Build Agent Image:** Create the custom agent image using the provided `Containerfile.agent`. This create container image with base packages required:
    ```sh
    podman build -f Containerfile.agent -t ceph-jenkins-agent:latest
    ```

3. **Update Properties:** Fill out `properties.yaml` with your real-world Jenkins configs. This "hydrates" the `casc.yaml` template with your actual cluster details and secrets.

4. **Apply Container-Shareable Label:** This will allow SELinux specific socket file to share with containers.
    ```sh
    chcon -t container_file_t /run/user/$(id -u)/podman/podman.sock
    ```

5. **Launch the Controller:** Start the container with port mappings for the UI and agent communication. Ensure the persistent volume is mounted:
    ```sh
    podman run -d \
        --name jenkins-controller \
        -p 8080:8080 -p 50000:50000 \
        -v jenkins_home:/var/jenkins_home \
        -v $(pwd)/properties.yaml:/var/jenkins_home/casc_configs/02-properties.yaml:z \
        -v /run/user/$(id -u)/podman/podman.sock:/var/run/podman.sock:z \
        --group-add $(stat -c '%g' /run/user/$(id -u)/podman/podman.sock) \
        --userns=keep-id \
        ceph-jenkins-controller:latest
    ```
6. **Bootstrap Jobs:** Upon startup, JCasC will automatically execute `seed.groovy` to create the `Seed` job.

7. **Process Project Jobs:** Run the `Seed` from the Jenkins UI, providing the relative path to your project's Groovy definitions to generate project-specific pipelines.

### Logging

The Ceph CI environment utilizes multiple logging layers to ensure visibility across the "controller/builder" architecture.

* **Controller Logs:** Monitor the startup and JCasC initialization via `podman logs -f jenkins-controller`.

* **Builder Logs:** Detailed system logs are often captured during build execution using `journalctl`.