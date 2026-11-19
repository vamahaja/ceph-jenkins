#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# --- Default Configuration ---
JENKINS_CONFIG_DIR="$HOME/jenkins_config"
JENKINS_PROPERTIES="$JENKINS_CONFIG_DIR/properties.yaml"
CASC_BASE="${REPO_ROOT}/casc/base.yaml"
CASC_CLOUDS="${REPO_ROOT}/casc/clouds-podman.yaml"
SEED_GROOVY="${REPO_ROOT}/jobs/seed.groovy"

# --- Volume Configuration ---
SHARED_WORKSPACE_VOLUME="jenkins_shared_workspace"
SHARED_WORKSPACE_PATH="$JENKINS_CONFIG_DIR/shared_workspace"
JENKINS_HOME_VOLUME="jenkins_home"
JENKINS_HOME_PATH="$JENKINS_CONFIG_DIR/jenkins_home"

# --- Create Jenkins Config Directory ---
if [ ! -d "$JENKINS_CONFIG_DIR" ]; then
    echo "Jenkins config directory does not exist."
    exit 1
fi

# --- Check if Jenkins Properties File Exists ---
if [ ! -f "$JENKINS_PROPERTIES" ]; then
    echo "Jenkins properties file does not exist."
    exit 1
fi

# --- Check Casc and seed files ---
for required in "$CASC_BASE" "$CASC_CLOUDS" "$SEED_GROOVY"; do
    if [ ! -f "$required" ]; then
        echo "Required file does not exist: $required"
        exit 1
    fi
done

# --- Podman Configuration ---
SOCKET_PATH="/run/user/$(id -u)/podman/podman.sock"
JENKINS_URL="http://localhost:8080"

if [ ! -S "$SOCKET_PATH" ]; then
    echo "Podman user socket not found: $SOCKET_PATH"
    echo "Enable it with: systemctl --user enable --now podman.socket"
    exit 1
fi
SOCKET_GID=$(stat -c '%g' "$SOCKET_PATH")

# Default podman.service exits after ~5s idle; Jenkins docker-plugin then hits
# Broken pipe on pooled unix-socket connections and fails to provision agents.
ensure_podman_api_linger() {
    local drop_in_dir="$HOME/.config/systemd/user/podman.service.d"
    local drop_in="$drop_in_dir/linger-api.conf"
    if [ ! -f "$drop_in" ] || ! grep -q -- '--time=0' "$drop_in"; then
        echo "Configuring podman.service to keep API alive (--time=0)..."
        mkdir -p "$drop_in_dir"
        cat > "$drop_in" <<'EOF'
[Service]
# Jenkins docker-plugin pools unix-socket connections; default 5s idle exit causes Broken pipe.
ExecStart=
ExecStart=/usr/bin/podman $LOGGING system service --time=0
EOF
        systemctl --user daemon-reload
    fi
    systemctl --user enable --now podman.socket >/dev/null
    systemctl --user start podman.service >/dev/null || true
}

ensure_podman_api_linger

echo "--- Initializing Deployment for Ceph-Jenkins ---"
echo "Detected Socket GID: $SOCKET_GID"

# --- Verify Required Images ---
echo "Verifying required images..."
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
    echo "One or more required images are missing."
    echo "Missing images: ${MISSING[*]}"
    echo "Run ./deploy/images/create-images.sh first."
    exit 1
fi

# --- Cleanup Existing Container (preserve jenkins_home volume/data) ---
if [ "$(podman ps -aq -f name=jenkins-controller)" ]; then
    echo "Stopping and removing existing jenkins-controller..."
    podman stop jenkins-controller
    podman rm jenkins-controller
fi

# --- Create Jenkins Home Volume ---
if podman volume exists jenkins_home 2>/dev/null; then
    echo "Jenkins home volume already exists."
else
    echo "Creating jenkins home directory..."
    mkdir -p "$JENKINS_HOME_PATH"

    echo "Creating jenkins home volume..."
    podman volume create jenkins_home \
        --opt type=dir \
        --opt device=$JENKINS_HOME_PATH \
        --opt o=bind
fi

# --- Create Shared Workspace Volume ---
# Rootless Podman maps container UID 1000 != host UID. A host-owned workspace
# appears as root inside agents (AccessDenied). Align ownership in the user
# namespace; agents also use securityOpts label=disable (casc/clouds-podman.yaml).
ensure_shared_workspace_perms() {
    mkdir -p "$SHARED_WORKSPACE_PATH"
    podman unshare chown 1000:1001 "$SHARED_WORKSPACE_PATH"
    podman unshare chmod 775 "$SHARED_WORKSPACE_PATH"
}

if podman volume exists jenkins_shared_workspace 2>/dev/null; then
    echo "Shared workspace volume already exists."
    echo "Ensuring shared workspace permissions for rootless agents..."
    ensure_shared_workspace_perms
else
    echo "Creating shared workspace directory..."
    ensure_shared_workspace_perms

    echo "Creating shared workspace volume..."
    podman volume create jenkins_shared_workspace \
        --opt type=dir \
        --opt device=$SHARED_WORKSPACE_PATH \
        --opt o=bind
fi

# --- Deploy Jenkins Server ---
echo "Launching Jenkins Controller..."
podman run -d \
    --name jenkins-controller \
    --cpus 4 \
    --memory 12g \
    --memory-reservation 4g \
    --oom-score-adj -500 \
    -p 8080:8080 -p 50000:50000 \
    -e JAVA_OPTS="-Xms4g -Xmx8g \
       -XX:+UseG1GC \
       -XX:+ExplicitGCInvokesConcurrent \
       -Djenkins.install.runSetupWizard=false \
       -Djava.awt.headless=true \
       -Dcasc.jenkins.config=/var/jenkins_home/casc_configs/" \
    -v $JENKINS_HOME_VOLUME:/var/jenkins_home:z \
    -v "$CASC_BASE":/var/jenkins_home/casc_configs/01-base.yaml:z \
    -v "$CASC_CLOUDS":/var/jenkins_home/casc_configs/02-clouds.yaml:z \
    -v $JENKINS_CONFIG_DIR/properties.yaml:/var/jenkins_home/casc_configs/03-properties.yaml:z \
    -v "$SEED_GROOVY":/var/jenkins_home/seed.groovy:z \
    -v $SOCKET_PATH:/var/run/podman.sock \
    --group-add $SOCKET_GID \
    --userns=keep-id \
    --security-opt label=disable \
    ceph-jenkins-controller:latest

# --- Health Check Step ---
echo "--- Post-Deployment Validation ---"

# A. Check if Container is actually Running
echo -n "Checking container status..."
if [ "$(podman inspect -f '{{.State.Running}}' jenkins-controller)" == "true" ]; then
    echo " [OK] Container is running."
else
    echo " [FAILED] Container failed to start."
    echo " Check 'podman logs jenkins-controller'."
    exit 1
fi

# Check if Jenkins Server is Up
echo "Waiting for Jenkins to be ready at $JENKINS_URL ..."
MAX_RETRIES=30
WAIT_INTERVAL=5
COUNT=0
SUCCESS=false

while [ $COUNT -lt $MAX_RETRIES ]; do
    # Check for a 200 (Success) or
    # 403 (Forbidden, indicating Jenkins is up but needs login)
    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" $JENKINS_URL/login || echo "000")

    if [ "$HTTP_STATUS" == "200" ] || [ "$HTTP_STATUS" == "403" ]; then
        echo " [OK] Jenkins is up and responding (Status: $HTTP_STATUS)."
        SUCCESS=true
        break
    fi

    echo -n "."
    sleep $WAIT_INTERVAL
    COUNT=$((COUNT + 1))
done

if [ "$SUCCESS" = false ]; then
    echo " [TIMEOUT] Jenkins did not start within 150 seconds."
    echo "Here is the last 60 lines of logs:"
    podman logs jenkins-controller --tail 60
    exit 1
fi

echo "--- Deployment Verified & Success! ---"
echo "Login at $JENKINS_URL"
