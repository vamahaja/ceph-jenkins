# OpenShift Helm chart — Ceph Jenkins controller

Deploys the Jenkins controller on OpenShift with JCasC mounts, JVM settings, and resource profile aligned with [`deploy/podman/deploy-containers.sh`](../podman/deploy-containers.sh).

Uses shared Casc from [`casc/base.yaml`](../../casc/base.yaml) plus OpenShift agents from [`casc/clouds-openshift.yaml`](../../casc/clouds-openshift.yaml).

## Prerequisites

- OpenShift cluster with `oc` logged in
- Helm 3
- Controller **and** agent images built and pushed to a registry the cluster can pull
- Real `properties.yaml` (see repo `properties.yaml` template)
- A StorageClass that supports **ReadWriteMany** for the required shared-workspace PVC

## Casc layout

| File | Purpose |
| --- | --- |
| `casc/base.yaml` | Shared controller config (security, Job DSL, seed, UI) |
| `casc/clouds-openshift.yaml` | Kubernetes cloud + agent pod templates |
| `properties.yaml` | Env-specific secrets and URLs |

Podman uses `casc/clouds-podman.yaml` instead of `clouds-openshift.yaml`.

## Build and push images

Rebuild the controller after plugin changes (this chart needs the `kubernetes` plugin):

```sh
./deploy/images/create-images.sh

REGISTRY=image-registry.openshift-image-registry.svc:5000/<namespace>
for img in \
  ceph-jenkins-controller \
  ceph-jenkins-seed-agent \
  ceph-jenkins-fedora39-agent \
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

The shared-workspace PVC is **required** (RWX) and is mounted by build-agent templates at `/home/jenkins/workspace`. Set `persistence.sharedWorkspace.storageClass` to an RWX-capable class if the cluster default does not support `ReadWriteMany`.

The chart fills namespace, Jenkins Service name, ServiceAccount, shared-workspace PVC name, and agent image prefix/tag/pull-secrets in `clouds-openshift.yaml` from the Helm release. Keep the `__JENKINS_*__` / `__AGENT_*__` / `__SHARED_WORKSPACE_CLAIM__` tokens if you supply a custom clouds file.

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

Templates use a `jnlp` sidecar plus a `builder` container, with **`agentContainer: builder`**, so existing pipelines that only set `agent { label 'ceph-build-...' }` run steps in the Ceph agent image. `jnlp` uses `workingDir: /tmp` (OpenShift random UID cannot write `/home/jenkins/agent`); builders use the shared-workspace PVC at `/home/jenkins/workspace`.

Agent pods use the chart ServiceAccount (via `__JENKINS_SERVICE_ACCOUNT__` in Casc), not `default`. CentOS, Rocky, Ubuntu, and buildah builders are **privileged** (`sudo` package installs, or buildah). Grant an SCC that allows privileged pods to that ServiceAccount, or avoid those labels on restricted clusters:

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
| PVC shared workspace | `/home/jenkins/workspace` |

There is **no** `podman.sock` mount on OpenShift. Pod security uses an empty `podSecurityContext` so OpenShift can assign an allowed UID/GID range (avoid hardcoded `fsGroup: 1000`).
