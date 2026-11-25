#!/bin/bash

set -euo pipefail

# --- Podman Configuration ---
SOCKET_PATH="/run/user/$(id -u)/podman/podman.sock"
SOCKET_GID=$(stat -c '%g' "$SOCKET_PATH")
HOST_UID=$(id -u)

echo "--- Building Ceph-Jenkins Images ---"
echo "Detected Socket GID: $SOCKET_GID"
echo "Detected Host UID: $HOST_UID"

# --- Build Images ---
echo "Building Jenkins Controller..."
podman build --pull=always -t ceph-jenkins-controller ./deploy/images/controller

echo "Building Seed Agent..."
# Alpine inbound-agent keeps jenkins at uid 1000. Podman remoteFs is /home/jenkins.
podman build \
    -t ceph-jenkins-seed-agent ./deploy/images/agents/seed

# Shared context is deploy/ so Containerfiles can COPY scripts/install-nix.sh.
DEPLOY_CTX="./deploy"

echo "Building Make Dist Agent (with dynamic permissions)..."
podman build \
    --build-arg USER_ID=$HOST_UID \
    --build-arg GROUP_ID=$SOCKET_GID \
    -f "${DEPLOY_CTX}/images/agents/make-dist/Containerfile" \
    -t ceph-jenkins-make-dist-agent \
    "${DEPLOY_CTX}"

echo "Building CentOS 9 Build Agent (with dynamic permissions)..."
podman build \
    --build-arg USER_ID=$HOST_UID \
    --build-arg GROUP_ID=$SOCKET_GID \
    -f "${DEPLOY_CTX}/images/agents/centos/9.stream/Containerfile" \
    -t ceph-jenkins-centos9-agent \
    "${DEPLOY_CTX}"

echo "Building Rocky 10 Build Agent (with dynamic permissions)..."
podman build \
    --build-arg USER_ID=$HOST_UID \
    --build-arg GROUP_ID=$SOCKET_GID \
    -f "${DEPLOY_CTX}/images/agents/rocky/10/Containerfile" \
    -t ceph-jenkins-rocky10-agent \
    "${DEPLOY_CTX}"

echo "Building Ubuntu Noble Build Agent (with dynamic permissions)..."
podman build \
    --build-arg USER_ID=$HOST_UID \
    --build-arg GROUP_ID=$SOCKET_GID \
    -t ceph-jenkins-ubuntu-noble-agent ./deploy/images/agents/ubuntu/noble

echo "Building Ubuntu Jammy Build Agent (with dynamic permissions)..."
podman build \
    --build-arg USER_ID=$HOST_UID \
    --build-arg GROUP_ID=$SOCKET_GID \
    -t ceph-jenkins-ubuntu-jammy-agent ./deploy/images/agents/ubuntu/jammy

echo "Building Buildah Build Agent (with dynamic permissions)..."
podman build \
    --build-arg USER_ID=$HOST_UID \
    --build-arg GROUP_ID=$SOCKET_GID \
    -t ceph-jenkins-buildah-agent ./deploy/images/agents/buildah

# --- Verify Built Images ---
echo "Verifying built images..."
REQUIRED_IMAGES=(
    "ceph-jenkins-controller:latest"
    "ceph-jenkins-seed-agent:latest"
    "ceph-jenkins-make-dist-agent:latest"
    "ceph-jenkins-centos9-agent:latest"
    "ceph-jenkins-rocky10-agent:latest"
    "ceph-jenkins-ubuntu-noble-agent:latest"
    "ceph-jenkins-ubuntu-jammy-agent:latest"
    "ceph-jenkins-buildah-agent:latest"
)
MISSING=()

for img in "${REQUIRED_IMAGES[@]}"; do
    if ! podman image exists "$img"; then
        echo " [MISSING] $img"
        MISSING+=("$img")
    else
        echo " [OK] $img"
    fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
    echo "One or more required images are missing. Build may have failed."
    echo "Missing images: ${MISSING[*]}"
    echo "Inspect build output above for errors."
    exit 1
fi

echo "--- Image Build Verified & Success! ---"
