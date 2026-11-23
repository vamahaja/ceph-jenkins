#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# --- Default Configuration ---
JENKINS_CONFIG_DIR="${JENKINS_CONFIG_DIR:-$HOME/jenkins_config}"
JENKINS_PROPERTIES="${JENKINS_PROPERTIES:-$JENKINS_CONFIG_DIR/properties.yaml}"
NAMESPACE="${NAMESPACE:-ceph-jenkins}"
RELEASE="${RELEASE:-ceph-jenkins}"
TAG="${TAG:-latest}"
SSH_SECRET="${SSH_SECRET:-${RELEASE}-virt-ssh}"
CASC_BASE="${REPO_ROOT}/casc/base.yaml"
CASC_CLOUDS="${REPO_ROOT}/casc/cloud-openshift-virt.yaml"
SEED_GROOVY="${REPO_ROOT}/jobs/seed.groovy"
GUEST_SETUP="${REPO_ROOT}/deploy/scripts/guest-setup.sh"
INSTALL_NIX="${REPO_ROOT}/deploy/scripts/install-nix.sh"
VM_DIR="${REPO_ROOT}/deploy/virtual-machines"
VM_AGENTS_DIR="${VM_DIR}/agents"
PACKAGES_RPM="${VM_DIR}/packages/rpm.txt"
PACKAGES_DEB="${VM_DIR}/packages/deb.txt"
PACKAGES_PIP="${VM_DIR}/packages/pip.txt"

VIRT_AGENTS=(
    ceph-build-centos9-agent
    ceph-build-rocky10-agent
    ceph-build-ubuntu-noble-agent
    ceph-build-ubuntu-jammy-agent
)

# --- Check required files ---
for required in "$CASC_BASE" "$CASC_CLOUDS" "$SEED_GROOVY" "$JENKINS_PROPERTIES" "$GUEST_SETUP" "$INSTALL_NIX" "$PACKAGES_RPM" "$PACKAGES_DEB" "$PACKAGES_PIP"; do
    if [ ! -f "$required" ]; then
        echo "Required file does not exist: $required"
        exit 1
    fi
done
mapfile -d '' CLOUD_INIT_FILES < <(find "$VM_AGENTS_DIR" -type f -name cloud-init.yaml -print0 | sort -z)
if [ "${#CLOUD_INIT_FILES[@]}" -eq 0 ]; then
    echo "No cloud-init.yaml files found under ${VM_AGENTS_DIR}"
    exit 1
fi

if [ -z "${REGISTRY:-}" ]; then
    echo "REGISTRY is required (registry the cluster can pull, no trailing slash)."
    echo "Example: REGISTRY=image-registry.openshift-image-registry.svc:5000/${NAMESPACE} $0"
    exit 1
fi

for cmd in oc helm ssh-keygen; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Required command not found: $cmd"
        exit 1
    fi
done

echo "--- Hybrid OpenShift Virt deploy ---"
echo "Namespace: ${NAMESPACE}"
echo "Release:   ${RELEASE}"
echo "Registry:  ${REGISTRY}"

if ! oc whoami >/dev/null 2>&1; then
    echo "oc is not logged in. Run 'oc login' first."
    exit 1
fi

# api-resources works for namespace users who cannot get cluster CRDs.
if ! oc api-resources --api-group=kubevirt.io -o name 2>/dev/null | grep -qx 'virtualmachines.kubevirt.io'; then
    echo "OpenShift Virtualization is not installed (missing virtualmachines.kubevirt.io)."
    exit 1
fi

if ! oc api-resources --api-group=cdi.kubevirt.io -o name 2>/dev/null | grep -qx 'datavolumes.cdi.kubevirt.io'; then
    echo "CDI is not installed (missing datavolumes.cdi.kubevirt.io)."
    exit 1
fi

oc get ns "$NAMESPACE" >/dev/null 2>&1 || oc create namespace "$NAMESPACE"

# --- SSH keypair for the build VMs ---
if ! oc get secret "$SSH_SECRET" -n "$NAMESPACE" >/dev/null 2>&1; then
    echo "Creating SSH keypair Secret ${SSH_SECRET}..."
    keydir="$(mktemp -d)"
    trap 'rm -rf "$keydir"' EXIT
    ssh-keygen -t ed25519 -N "" -f "${keydir}/id_ed25519" -C "ceph-virt-agent" >/dev/null
    oc create secret generic "$SSH_SECRET" -n "$NAMESPACE" \
        --from-file=ssh-private-key="${keydir}/id_ed25519" \
        --from-file=ssh-public-key="${keydir}/id_ed25519.pub"
else
    keydir="$(mktemp -d)"
    trap 'rm -rf "$keydir"' EXIT
    echo "SSH keypair Secret ${SSH_SECRET} already exists."
fi

oc get secret "$SSH_SECRET" -n "$NAMESPACE" -o jsonpath='{.data.ssh-public-key}' | base64 -d > "${keydir}/id_ed25519.pub"
if [ ! -s "${keydir}/id_ed25519.pub" ]; then
    echo "Secret ${SSH_SECRET} has no ssh-public-key data."
    exit 1
fi

if ! grep -Eq '^[[:space:]]*id:[[:space:]]*"ceph-virt-agent-ssh"' "$JENKINS_PROPERTIES"; then
    echo "properties.yaml is missing credential id ceph-virt-agent-ssh."
    echo "Add this block under credentials.system.domainCredentials[].credentials:"
    echo
    cat <<'EOF'
          - usernamePassword:
              scope: SYSTEM
              id: "ceph-virt-agent-ssh"
              username: "jenkins"
              password: "jenkins"
              description: "Password login for static OpenShift Virt build agents"
EOF
    exit 1
fi

echo "Installing Jenkins controller with casc/cloud-openshift-virt.yaml..."
helm_args=(
    upgrade --install "$RELEASE" "${REPO_ROOT}/deploy/openshift"
    --namespace "$NAMESPACE"
)
# A values file carries pull secrets, RBAC, and storage. Do not follow it
# with --set agentImages.*, which replaces that map and drops the secrets.
if [ -n "${VALUES_FILE:-}" ]; then
    if [ ! -f "$VALUES_FILE" ]; then
        echo "VALUES_FILE does not exist: $VALUES_FILE"
        exit 1
    fi
    helm_args+=(-f "$VALUES_FILE")
else
    helm_args+=(
        --set "image.repository=${REGISTRY}/ceph-jenkins-controller"
        --set "image.tag=${TAG}"
        --set "agentImages.prefix=${REGISTRY}/"
        --set "agentImages.tag=${TAG}"
    )
fi
helm_args+=(
    --set agentMode=virt
    --set-file "cascBaseContent=${CASC_BASE}"
    --set-file "cascCloudsContent=${CASC_CLOUDS}"
    --set-file "seedContent=${SEED_GROOVY}"
    --set-file "propertiesContent=${JENKINS_PROPERTIES}"
    --set-file "virtAgents.sshPublicKey=${keydir}/id_ed25519.pub"
    --set-file "virtAgents.guestSetupContent=${GUEST_SETUP}"
    --set-file "virtAgents.installNixContent=${INSTALL_NIX}"
    --set-file "virtAgents.packagesRpmContent=${PACKAGES_RPM}"
    --set-file "virtAgents.packagesDebContent=${PACKAGES_DEB}"
    --set-file "virtAgents.packagesPipContent=${PACKAGES_PIP}"
)
for cloud_init in "${CLOUD_INIT_FILES[@]}"; do
    # agents/centos/9.stream/cloud-init.yaml -> centos-9.stream
    rel="${cloud_init#"${VM_AGENTS_DIR}"/}"
    key="${rel%/cloud-init.yaml}"
    key="${key//'/'/-}"
    # Escape "." so Helm does not treat it as a nested key path.
    key_escaped="${key//./\\.}"
    helm_args+=(--set-file "virtAgents.cloudInitContent.${key_escaped}=${cloud_init}")
done
if [ -n "${VIRT_STORAGE_CLASS:-}" ]; then
    helm_args+=(--set "virtAgents.storageClass=${VIRT_STORAGE_CLASS}")
fi
if [ -n "${VIRT_MEMORY:-}" ]; then
    helm_args+=(--set "virtAgents.memory=${VIRT_MEMORY}")
fi
helm "${helm_args[@]}"

echo "--- Waiting for build VirtualMachines ---"
MAX_RETRIES=120
WAIT_INTERVAL=15
for name in "${VIRT_AGENTS[@]}"; do
    echo -n "Waiting for ${name}..."
    count=0
    ready=false
    while [ "$count" -lt "$MAX_RETRIES" ]; do
        status="$(oc get vm "$name" -n "$NAMESPACE" -o jsonpath='{.status.printableStatus}' 2>/dev/null || true)"
        if [ "$status" = "Running" ]; then
            echo " [OK] Running"
            ready=true
            break
        fi
        echo -n "."
        sleep "$WAIT_INTERVAL"
        count=$((count + 1))
    done
    if [ "$ready" != true ]; then
        echo " [TIMEOUT] ${name} status=${status:-unknown}"
        oc describe vm "$name" -n "$NAMESPACE" | tail -n 40
        exit 1
    fi
done

echo "--- Waiting for SSH Services ---"
for name in "${VIRT_AGENTS[@]}"; do
    echo -n "Waiting for endpoints on ${name}..."
    count=0
    ready=false
    while [ "$count" -lt 20 ]; do
        ips="$(oc get endpoints "$name" -n "$NAMESPACE" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)"
        if [ -n "$ips" ]; then
            echo " [OK] ${ips}"
            ready=true
            break
        fi
        echo -n "."
        sleep 5
        count=$((count + 1))
    done
    if [ "$ready" != true ]; then
        echo " [TIMEOUT] no endpoints for ${name}"
        exit 1
    fi
done

echo "--- Waiting for Jenkins ---"
route_host="$(oc get route -n "$NAMESPACE" -l "app.kubernetes.io/instance=${RELEASE}" -o jsonpath='{.items[0].spec.host}')"
if [ -z "$route_host" ]; then
    echo "Jenkins Route not found in namespace ${NAMESPACE}."
    exit 1
fi
JENKINS_URL="https://${route_host}"
count=0
success=false
while [ "$count" -lt 40 ]; do
    http_status="$(curl -sk -o /dev/null -w "%{http_code}" "${JENKINS_URL}/login" || echo "000")"
    if [ "$http_status" = "200" ] || [ "$http_status" = "403" ]; then
        echo " [OK] Jenkins is up (Status: ${http_status})."
        success=true
        break
    fi
    echo -n "."
    sleep 5
    count=$((count + 1))
done

if [ "$success" != true ]; then
    echo " [TIMEOUT] Jenkins did not respond at ${JENKINS_URL}/login"
    oc logs -l "app.kubernetes.io/instance=${RELEASE}" -n "$NAMESPACE" --tail 60 || true
    exit 1
fi

echo "--- Deployment Verified & Success! ---"
echo "Login at ${JENKINS_URL}"
echo "Build agents are SSH nodes virt-ceph-build-*-agent. The seed agent remains a pod."
