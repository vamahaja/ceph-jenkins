# OpenShift Helm chart — Ceph Jenkins controller

Deploys the Jenkins controller on OpenShift with JCasC mounts, JVM settings, and resource profile aligned with [`deploy/podman/deploy-containers.sh`](../podman/deploy-containers.sh).

Uses shared Casc from [`casc/base.yaml`](../../casc/base.yaml) plus one agent file. Pick one:

- **Pod.** [`casc/clouds-openshift.yaml`](../../casc/clouds-openshift.yaml). Seed and every build agent are pods.
- **Hybrid.** [`casc/cloud-openshift-virt.yaml`](../../casc/cloud-openshift-virt.yaml). The seed agent stays a pod. Fedora 39, CentOS 9, Rocky 10, Ubuntu Noble, and Ubuntu Jammy are static OpenShift Virtualization machines. Do not load both agent files.

## Prerequisites

- OpenShift cluster with `oc` logged in
- Helm 3
- Controller and agent images built and pushed to a registry the cluster can pull. The pod install uses every agent image. The hybrid install uses the controller and the seed image; build agents boot cloud images
- Real `properties.yaml` (see repo `properties.yaml` template)
- A StorageClass that supports **ReadWriteMany** for the required shared-workspace PVC
- Hybrid only: OpenShift Virtualization and CDI (`virtualmachines.kubevirt.io`, `datavolumes.cdi.kubevirt.io`)

## Casc layout

| File | Purpose |
| --- | --- |
| `casc/base.yaml` | Shared controller config (security, Job DSL, seed, UI) |
| `casc/clouds-openshift.yaml` | Pod option: Kubernetes cloud + agent pod templates |
| `casc/cloud-openshift-virt.yaml` | Hybrid option: seed pod plus permanent SSH nodes for build VMs |
| `properties.yaml` | Env-specific secrets and URLs |

Podman uses `casc/clouds-podman.yaml` instead of either OpenShift agent file.

## Build and push images

Rebuild the controller after plugin changes (this chart needs the `kubernetes` plugin):

```sh
./deploy/images/create-images.sh

REGISTRY=image-registry.openshift-image-registry.svc:5000/<namespace>
for img in \
  ceph-jenkins-controller \
  ceph-jenkins-seed-agent \
  ceph-jenkins-make-dist-agent \
  ceph-jenkins-centos9-agent \
  ceph-jenkins-rocky10-agent \
  ceph-jenkins-ubuntu-noble-agent \
  ceph-jenkins-ubuntu-jammy-agent \
  ceph-jenkins-buildah-agent
do
  podman tag "${img}:latest" "${REGISTRY}/${img}:latest"
  podman push "${REGISTRY}/${img}:latest"
done
```

Adjust `REGISTRY` for Quay or an external registry as needed.

## Install

Two installs. Use one.

### Pod agents

```sh
oc new-project ceph-jenkins   # or use an existing namespace

REGISTRY=image-registry.openshift-image-registry.svc:5000/ceph-jenkins

helm upgrade --install ceph-jenkins ./deploy/openshift \
  --namespace ceph-jenkins \
  --set image.repository=${REGISTRY}/ceph-jenkins-controller \
  --set image.tag=latest \
  --set agentImages.prefix=${REGISTRY}/ \
  --set agentImages.tag=latest \
  --set-file cascBaseContent=./casc/base.yaml \
  --set-file cascCloudsContent=./casc/clouds-openshift.yaml \
  --set-file seedContent=./jobs/seed.groovy \
  --set-file propertiesContent=$HOME/jenkins_config/properties.yaml
```

### Hybrid agents (seed pod, build VMs)

Build agents are not pods. Before install, add this credential to `$HOME/jenkins_config/properties.yaml` under `credentials.system.domainCredentials[].credentials`. Jenkins SSHes to each VM as `jenkins` with this password. The guest image sets the same password and turns `PasswordAuthentication` on.

```yaml
- usernamePassword:
    scope: SYSTEM
    id: "ceph-virt-agent-ssh"
    username: "jenkins"
    password: "jenkins"
    description: "Password login for static OpenShift Virt build agents"
```

From the repository root (the script resolves paths from its own location):

```sh
chmod +x ./deploy/openshift/deploy-virt.sh
REGISTRY=image-registry.openshift-image-registry.svc:5000/ceph-jenkins \
  ./deploy/openshift/deploy-virt.sh
```

The script:

- Requires `oc` login, Helm, OpenShift Virtualization, and CDI
- Requires `casc/base.yaml`, `casc/cloud-openshift-virt.yaml`, `jobs/seed.groovy`, and `$HOME/jenkins_config/properties.yaml`
- Creates the SSH keypair Secret when it is missing
- Installs the controller with `agentMode=virt` and `casc/cloud-openshift-virt.yaml`
- Waits until each build `VirtualMachine` is `Running` and its SSH Service has endpoints
- Waits until the Jenkins Route `/login` returns HTTP 200 or 403

Optional environment variables: `NAMESPACE` (default `ceph-jenkins`), `RELEASE` (default `ceph-jenkins`), `TAG` (default `latest`), `VIRT_STORAGE_CLASS` (root disks; empty uses the cluster default).

Each build VM imports a distro cloud image and cloud-init installs the same packages and `jenkins` user (uid 1000) as the matching Containerfile, plus `openssh-server`. Shared guest helpers live in [`deploy/scripts/`](../scripts/) (`guest-setup.sh`, `install-nix.sh`). Platform-neutral VM assets mirror the image tree under [`deploy/virtual-machines/agents/`](../virtual-machines/agents/) (`cloud-init.yaml` per distro) plus [`deploy/virtual-machines/packages/`](../virtual-machines/packages/). Disk URLs are `virtAgents.agents[].image` in [`values.yaml`](values.yaml). Jenkins connects with the `ssh-slaves` plugin, so the guests do not install `jenkins-agent`.

Permanent node names are `virt-<label>`. `labelString` stays the existing label and `remoteFS` is `/home/jenkins`. Build VMs are 16 vCPUs and 64 GB of RAM (`ALLOCATED_CPUS=16`) with a 300 GB home disk. Cloud-init formats that disk and mounts it at `/home/jenkins`. The seed pod is unchanged and does not use that disk.

The shared-workspace PVC is **required** (RWX) for pod build agents, which mount it at `/workspace`. Hybrid build VMs do not mount that claim. Set `persistence.sharedWorkspace.storageClass` to an RWX-capable class if the cluster default does not support `ReadWriteMany`. `virtAgents.storageClass` must support `volumeMode: Block` for the per-VM home disks.

The chart fills namespace, Jenkins Service name, ServiceAccount, shared-workspace PVC name, and agent image prefix/tag/pull-secrets in the Casc file you pass. Keep the `__JENKINS_*__` / `__AGENT_*__` / `__SHARED_WORKSPACE_CLAIM__` tokens if you supply a custom clouds file.

### Optional values

| Value | Purpose |
| --- | --- |
| `agentImages.prefix` | Registry prefix for agent images (trailing `/` optional) |
| `agentImages.tag` | Agent image tag (default `latest`) |
| `agentImages.imagePullSecrets` | Secret names for private agent image pulls |
| `imagePullSecrets` | Secrets for pulling the controller image |
| `route.host` | Fixed Route hostname (empty = OpenShift default) |
| `route.tls.enabled` | TLS on the Route (default `true`, edge termination) |
| `persistence.home.size` | Jenkins home PVC size (default `20Gi`) |
| `persistence.sharedWorkspace.size` | Shared workspace PVC (default `100Gi`, `ReadWriteMany`) |
| `persistence.sharedWorkspace.storageClass` | StorageClass for RWX |
| `propertiesExistingSecret` | Use a pre-created Secret instead of `--set-file propertiesContent` |
| `rbac.create` | Role/RoleBinding for Kubernetes agent pods (default `true`) |
| `validate` | Require Casc/seed/properties inputs (default `true`; set `false` to render RBAC-only) |
| `agentMode` | `pod` (default) or `virt`. `virt` renders VirtualMachines; use it with `casc/cloud-openshift-virt.yaml` |
| `virtAgents.storageClass` | StorageClass for VM root disks (empty = cluster default) |
| `virtAgents.guestSetupContent` | Guest setup script body (`deploy/scripts/guest-setup.sh`; `deploy-virt.sh` passes it with `--set-file`) |
| `virtAgents.installNixContent` | Nix install script body (`deploy/scripts/install-nix.sh`; same `--set-file` pattern) |
| `virtAgents.packagesRpmContent` / `packagesDebContent` / `packagesPipContent` | Shared package lists from `deploy/virtual-machines/packages/` |
| `virtAgents.cloudInitContent.<key>` | Per-distro user-data from `deploy/virtual-machines/agents/<path>/cloud-init.yaml` (`/` → `-` in the key) |
| `virtAgents.agents[].image` | HTTP cloud-image URL imported by CDI |

If `rbac.create` is `false` (common when the deployer cannot create Roles), a project admin must apply the chart Role before agents work:

```sh
# Render templates/rbac.yaml from the chart (any namespace / values file)
helm template ceph-jenkins ./deploy/openshift \
  --namespace <namespace> \
  -f deploy/openshift/values-<env>.yaml \
  --set validate=false \
  --set rbac.create=true \
  -s templates/rbac.yaml | oc apply -f -

# Or broader edit on the SA
oc policy add-role-to-user edit -z ceph-jenkins -n <namespace>
```

Example with an existing properties Secret and private registry pull secret:

```sh
oc create secret generic jenkins-properties \
  --from-file=properties.yaml=$HOME/jenkins_config/properties.yaml \
  -n ceph-jenkins

helm upgrade --install ceph-jenkins ./deploy/openshift \
  --namespace ceph-jenkins \
  --set image.repository=${REGISTRY}/ceph-jenkins-controller \
  --set agentImages.prefix=${REGISTRY}/ \
  --set agentImages.imagePullSecrets[0]=registry-pull \
  --set imagePullSecrets[0].name=registry-pull \
  --set propertiesExistingSecret=jenkins-properties \
  --set-file cascBaseContent=./casc/base.yaml \
  --set-file cascCloudsContent=./casc/clouds-openshift.yaml \
  --set-file seedContent=./jobs/seed.groovy
```

## Agent pods

Each template is **one container** named `jnlp`. The image is the agent (`ceph-jenkins-make-dist-agent` and the distro agent images), which contains `jenkins-agent` and `agent.jar` copied from `jenkins/inbound-agent`. The pod `command` is `jenkins-agent`, so checkout, git, and Nix share that container's CPU and memory. `agentInjection` is not used: its `set-up-jenkins-agent` init container has no resource requests and fails this cluster's ResourceQuota.

Build agents set `workingDir` and `HOME` to `/home/jenkins/workspace`. Each build pod gets its own `dynamicPVC` workspace volume (`ReadWriteOnce`, `100Gi`), mounted at that working directory and deleted with the pod. The cluster default StorageClass is used. The seed agent uses the same path on the default emptyDir. The Nix pipeline keeps Make Dist on that pod disk and copies `ceph-<version>.tar.bz2` to the distro agents with `stash`. The chart still creates the shared-workspace PVC for the controller mount; build agents do not mount it.

Agent pods use the chart ServiceAccount (via `__JENKINS_SERVICE_ACCOUNT__` in Casc), not `default`. CentOS, Rocky, Ubuntu, and buildah agents are **privileged** (`sudo` package installs, or buildah). Grant an SCC that allows privileged pods to that ServiceAccount, or avoid those labels on restricted clusters:

```sh
oc adm policy add-scc-to-user privileged -z ceph-jenkins -n ceph-jenkins
```

(ServiceAccount name follows the Helm release; adjust if you override `fullnameOverride` / `serviceAccount.name`.)

## Verify

```sh
oc get pods,svc,route,pvc -n ceph-jenkins
oc logs -f deploy/ceph-jenkins -n ceph-jenkins

# Open the Route URL
oc get route ceph-jenkins -n ceph-jenkins -o jsonpath='{.spec.host}{"\n"}'
```

## What is mounted

| Source | Mount path |
| --- | --- |
| ConfigMap (`casc/base.yaml`) | `/var/jenkins_home/casc_configs/01-base.yaml` |
| ConfigMap (`casc/clouds-openshift.yaml`) | `/var/jenkins_home/casc_configs/02-clouds.yaml` |
| Secret (`properties.yaml`) | `/var/jenkins_home/casc_configs/03-properties.yaml` |
| ConfigMap (`seed.groovy`) | `/var/jenkins_home/seed.groovy` |
| PVC home | `/var/jenkins_home` |
| PVC shared workspace | `/workspace` |

There is **no** `podman.sock` mount on OpenShift. Pod security uses an empty `podSecurityContext` so OpenShift can assign an allowed UID/GID range (avoid hardcoded `fsGroup: 1000`).
