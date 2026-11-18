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

echo "Building Seed Agent (with dynamic permissions)..."
podman build \
    --build-arg USER_ID=$HOST_UID \
    --build-arg GROUP_ID=$SOCKET_GID \
    -t ceph-jenkins-seed-agent ./deploy/images/agents/seed

# Agent build context is deploy/images/agents/build so Containerfiles can
# COPY shared helpers such as install-nix.sh.
AGENT_BUILD_CTX="./deploy/images/agents/build"

echo "Building Fedora 39 Build Agent (with dynamic permissions)..."
podman build \
    --build-arg USER_ID=$HOST_UID \
    --build-arg GROUP_ID=$SOCKET_GID \
    -f "${AGENT_BUILD_CTX}/fedora/39/Containerfile" \
    -t ceph-jenkins-fedora39-agent \
    "${AGENT_BUILD_CTX}"

echo "Building CentOS 9 Build Agent (with dynamic permissions)..."
podman build \
    --build-arg USER_ID=$HOST_UID \
    --build-arg GROUP_ID=$SOCKET_GID \
    -f "${AGENT_BUILD_CTX}/centos/9.stream/Containerfile" \
    -t ceph-jenkins-centos9-agent \
    "${AGENT_BUILD_CTX}"

echo "Building Rocky 10 Build Agent (with dynamic permissions)..."
podman build \
    --build-arg USER_ID=$HOST_UID \
    --build-arg GROUP_ID=$SOCKET_GID \
    -f "${AGENT_BUILD_CTX}/rocky/10/Containerfile" \
    -t ceph-jenkins-rocky10-agent \
    "${AGENT_BUILD_CTX}"

echo "Building Ubuntu Noble Build Agent (with dynamic permissions)..."
podman build \
    --build-arg USER_ID=$HOST_UID \
    --build-arg GROUP_ID=$SOCKET_GID \
    -t ceph-jenkins-ubuntu-noble-agent ./deploy/images/agents/build/ubuntu/noble

echo "Building Ubuntu Jammy Build Agent (with dynamic permissions)..."
podman build \
    --build-arg USER_ID=$HOST_UID \
    --build-arg GROUP_ID=$SOCKET_GID \
    -t ceph-jenkins-ubuntu-jammy-agent ./deploy/images/agents/build/ubuntu/jammy

echo "Building Buildah Build Agent (with dynamic permissions)..."
podman build \
    --build-arg USER_ID=$HOST_UID \
    --build-arg GROUP_ID=$SOCKET_GID \
    -t ceph-jenkins-buildah-agent ./deploy/images/agents/build/buildah

# --- Verify Built Images ---
echo "Verifying built images..."
REQUIRED_IMAGES=(
    "ceph-jenkins-controller:latest"
    "ceph-jenkins-seed-agent:latest"
    "ceph-jenkins-fedora39-agent:latest"
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
