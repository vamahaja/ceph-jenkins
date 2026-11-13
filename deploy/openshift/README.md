# OpenShift Helm chart — Ceph Jenkins controller

Deploys the Jenkins controller on OpenShift with JCasC mounts, JVM settings, and resource profile aligned with [`deploy/podman/deploy-containers.sh`](../podman/deploy-containers.sh).

Uses shared Casc from [`casc/base.yaml`](../../casc/base.yaml) plus OpenShift agents from [`casc/clouds-openshift.yaml`](../../casc/clouds-openshift.yaml).

## Prerequisites

- OpenShift cluster with `oc` logged in
- Helm 3
- Controller (and agent) images built and pushed to a registry the cluster can pull
- Real `properties.yaml` (see repo `properties.yaml` template)

## Casc layout

| File | Purpose |
| --- | --- |
| `casc/base.yaml` | Shared controller config (security, Job DSL, seed, UI) |
| `casc/clouds-openshift.yaml` | Kubernetes cloud + agent pod templates |
| `properties.yaml` | Env-specific secrets and URLs |

Podman uses `casc/clouds-podman.yaml` instead of `clouds-openshift.yaml`.

## Build and push images

From the repository root:

```sh
./deploy/images/create-images.sh

# Tag/push for your cluster registry, for example:
podman tag ceph-jenkins-controller:latest \
  image-registry.openshift-image-registry.svc:5000/<namespace>/ceph-jenkins-controller:latest
podman push \
  image-registry.openshift-image-registry.svc:5000/<namespace>/ceph-jenkins-controller:latest
```

Push agent images the same way if you will run Kubernetes agents. Adjust the registry path for Quay or an external registry as needed.

## Install

```sh
oc new-project ceph-jenkins   # or use an existing namespace

helm upgrade --install ceph-jenkins ./deploy/openshift \
  --namespace ceph-jenkins \
  --set image.repository=image-registry.openshift-image-registry.svc:5000/ceph-jenkins/ceph-jenkins-controller \
  --set image.tag=latest \
  --set-file cascBaseContent=./casc/base.yaml \
  --set-file cascCloudsContent=./casc/clouds-openshift.yaml \
  --set-file seedContent=./jobs/seed.groovy \
  --set-file propertiesContent=$HOME/jenkins_config/properties.yaml
```

`clouds-openshift.yaml` defaults assume release name `ceph-jenkins` in namespace `ceph-jenkins` (Service URL, tunnel, shared-workspace PVC name). Change that file if your release/namespace differs.

### Optional values

| Value | Purpose |
| --- | --- |
| `route.host` | Fixed Route hostname (empty = OpenShift default) |
| `route.tls.enabled` | TLS on the Route (default `true`, edge termination) |
| `persistence.home.size` | Jenkins home PVC size (default `20Gi`) |
| `persistence.sharedWorkspace.size` | Shared workspace PVC (default `100Gi`, `ReadWriteMany`) |
| `persistence.sharedWorkspace.storageClass` | StorageClass for RWX (required if default is RWO-only) |
| `propertiesExistingSecret` | Use a pre-created Secret instead of `--set-file propertiesContent` |
| `rbac.create` | Role/RoleBinding for Kubernetes agent pods (default `true`) |

Example with an existing properties Secret:

```sh
oc create secret generic jenkins-properties \
  --from-file=properties.yaml=$HOME/jenkins_config/properties.yaml \
  -n ceph-jenkins

helm upgrade --install ceph-jenkins ./deploy/openshift \
  --namespace ceph-jenkins \
  --set image.repository=... \
  --set propertiesExistingSecret=jenkins-properties \
  --set-file cascBaseContent=./casc/base.yaml \
  --set-file cascCloudsContent=./casc/clouds-openshift.yaml \
  --set-file seedContent=./jobs/seed.groovy
```

## Agent pods

OpenShift templates use a `jnlp` sidecar plus a `builder` container (Ceph agent image). Pipeline steps that need build tools should run in `container('builder') { ... }`.

The `ceph-build-buildah-agent` template requests a privileged builder container; the namespace may need an SCC that allows that.

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

There is **no** `podman.sock` mount on OpenShift.
