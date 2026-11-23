# Podman deployment — Ceph Jenkins controller

Deploys the Jenkins controller as a local Podman container with JCasC mounts, agent cloud over the host `podman.sock`, and a post-start health check.

Uses shared Casc from [`casc/base.yaml`](../../casc/base.yaml) plus Podman agents from [`casc/clouds-podman.yaml`](../../casc/clouds-podman.yaml).

## Prerequisites

- Podman installed on the host
- User-session `podman.socket` enabled (see below)
- Controller and agent images built locally (see [`deploy/images`](../images))
- Real `$HOME/jenkins_config/properties.yaml` (see repo [`properties.yaml`](../../properties.yaml) template)

## Casc layout

| File | Purpose |
| --- | --- |
| `casc/base.yaml` | Shared controller config (security, Job DSL, seed, UI) |
| `casc/clouds-podman.yaml` | Docker/Podman cloud + agent templates |
| `properties.yaml` | Env-specific secrets and URLs |

## Host setup

1. **Config directory and properties**

   ```sh
   mkdir -p $HOME/jenkins_config
   cp properties.yaml $HOME/jenkins_config/properties.yaml
   # Edit $HOME/jenkins_config/properties.yaml with real passwords, URLs, and nodes
   ```

2. **User Podman socket**

   ```sh
   systemctl --user enable --now podman.socket
   ls -l /run/user/$(id -u)/podman/podman.sock
   ```

   Keep the API process alive (default ~5s idle exit causes Jenkins `Broken pipe` while provisioning agents). `deploy-containers.sh` installs this drop-in automatically:

   ```sh
   mkdir -p ~/.config/systemd/user/podman.service.d
   cat > ~/.config/systemd/user/podman.service.d/linger-api.conf <<'EOF'
   [Service]
   ExecStart=
   ExecStart=/usr/bin/podman $LOGGING system service --time=0
   EOF
   systemctl --user daemon-reload
   systemctl --user restart podman.socket
   systemctl --user start podman.service
   ```

3. **Linger** (keeps the socket and containers alive after logout)

   ```sh
   sudo loginctl enable-linger $(id -u)
   ```

## Build images

From the repository root:

```sh
chmod +x ./deploy/images/create-images.sh ./deploy/podman/deploy-containers.sh
./deploy/images/create-images.sh
```

`deploy-containers.sh` expects these local tags:

- `ceph-jenkins-controller:latest`
- `ceph-jenkins-seed-agent:latest`
- `ceph-jenkins-fedora39-agent:latest`
- `ceph-jenkins-centos9-agent:latest`
- `ceph-jenkins-rocky10-agent:latest`
- `ceph-jenkins-ubuntu-noble-agent:latest`
- `ceph-jenkins-ubuntu-jammy-agent:latest`
- `ceph-jenkins-buildah-agent:latest`

## Deploy

From the repository root (or any directory; the script resolves paths from its own location):

```sh
./deploy/podman/deploy-containers.sh
```

The script:

- Verifies the Podman user socket, required images, and Casc/seed/properties files
- Recreates `jenkins-controller` if it already exists (keeps the `jenkins_home` volume)
- Creates bind-backed volumes `jenkins_home` and `jenkins_shared_workspace` under `$HOME/jenkins_config/`
- Mounts Casc, properties, seed, and the host Podman socket
- Waits until `http://localhost:8080/login` returns HTTP 200 or 403

Login at [http://localhost:8080](http://localhost:8080).

## What is mounted

| Source | Mount path |
| --- | --- |
| `casc/base.yaml` | `/var/jenkins_home/casc_configs/01-base.yaml` |
| `casc/clouds-podman.yaml` | `/var/jenkins_home/casc_configs/02-clouds.yaml` |
| `$HOME/jenkins_config/properties.yaml` | `/var/jenkins_home/casc_configs/03-properties.yaml` |
| `jobs/seed.groovy` | `/var/jenkins_home/seed.groovy` |
| Volume `jenkins_home` | `/var/jenkins_home` |
| Host `podman.sock` | `/var/run/podman.sock` |

Agent templates also use volume `jenkins_shared_workspace` at `/workspace` inside build agents. `remoteFs` stays `/home/jenkins`. The images contain `jenkins-agent` for OpenShift; Podman does not run it. Keep `CMD ["/bin/bash"]` and `tty: true` so the attach connector can exec its own remoting jar. An image entrypoint of `jenkins-agent` exits immediately because this connector does not set `JENKINS_SECRET`.

SELinux note: the controller runs with `--security-opt label=disable` so it can talk to the host socket. Jenkins home Casc mounts use `:z`.

## Verify and logs

```sh
podman ps -f name=jenkins-controller
podman logs -f jenkins-controller
```

Builder/agent system logs on the host are often in `journalctl`.

## Bootstrap jobs

On first start, JCasC runs `seed.groovy` and creates the Seed job. From the Jenkins UI, run **Seed** with the relative path to your project Groovy definitions to generate pipelines.
