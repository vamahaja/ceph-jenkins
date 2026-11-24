#!/bin/bash
# Install Nix (flakes) into an agent image. Intended to run as root during image build.
set -euo pipefail

curl --proto '=https' --tlsv1.2 -sSf -L \
  https://install.determinate.systems/nix | sh -s -- install linux \
  --extra-conf "experimental-features = nix-command flakes" \
  --extra-conf "sandbox = false" \
  --init none \
  --no-confirm

# OpenShift runs agents as a random UID (often with gid 0). That UID cannot
# chmod image-owned /nix/var/nix/profiles/per-user (EPERM), which breaks
# `nix develop`. Point `default` at the resolved store profile, then replace
# per-user with a symlink to a runtime-writable directory under /tmp.
profiles=/nix/var/nix/profiles
if [ -L "${profiles}/default" ] || [ -e "${profiles}/default" ]; then
  default_target=$(readlink -f "${profiles}/default")
  ln -sfn "${default_target}" "${profiles}/default"
fi
rm -rf "${profiles}/per-user"
ln -s /tmp/nix-profiles-per-user "${profiles}/per-user"

# Optional chown for local Podman UID match. Keep group root + group-writable
# so OpenShift's random UID (gid 0) can write the store.
if [ -n "${NIX_CHOWN_USER:-}" ]; then
  chown -R "${NIX_CHOWN_USER}:${NIX_CHOWN_USER}" /nix
fi
chgrp -R 0 /nix
chmod -R g+rwX /nix
# World-writable store helps Podman jenkins user (not in gid 0) and random UIDs.
chmod -R a+rwX /nix/store /nix/var/nix/db 2>/dev/null || true

# Ensure login shells and Jenkins non-login steps see nix.
cat >/etc/profile.d/nix.sh <<'EOF'
export PATH="/nix/var/nix/profiles/default/bin:${PATH}"
EOF
chmod 644 /etc/profile.d/nix.sh
