#!/bin/bash
# Install Nix (flakes) into an agent image. Intended to run as root during image build.
set -euo pipefail

curl --proto '=https' --tlsv1.2 -sSf -L \
  https://install.determinate.systems/nix | sh -s -- install linux \
  --extra-conf "experimental-features = nix-command flakes" \
  --extra-conf "sandbox = false" \
  --init none \
  --no-confirm

# OpenShift may run as a non-root random UID; keep the store writable by the image user.
if [ -n "${NIX_CHOWN_USER:-}" ]; then
  chown -R "${NIX_CHOWN_USER}:${NIX_CHOWN_USER}" /nix
fi

# Ensure login shells and Jenkins non-login steps see nix.
cat >/etc/profile.d/nix.sh <<'EOF'
export PATH="/nix/var/nix/profiles/default/bin:${PATH}"
EOF
chmod 644 /etc/profile.d/nix.sh
