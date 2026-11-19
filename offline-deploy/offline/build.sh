#!/usr/bin/env bash
# Run in a disposable ubuntu:24.04 container with this workspace mounted at /workspace.
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive LC_ALL=C
[[ -f /.dockerenv && "$(dpkg --print-architecture)" == amd64 ]] || exit 2
OUT=/workspace/offline-deps-ubuntu24.04-amd64
[[ ! -e "$OUT/SHA256SUMS" ]] || { echo 'A completed bundle already exists; choose a new output directory before rebuilding.'; exit 2; }
mkdir -p "$OUT/debs/partial"
# The official Ubuntu container otherwise clears downloaded archives after apt operations.
rm -f /etc/apt/apt.conf.d/docker-clean
apt-get -o APT::Update::Error-Mode=any update
apt-get install -y --no-install-recommends ca-certificates curl dpkg-dev
install -d -m 0755 /etc/apt/keyrings
curl --fail --show-error --location --retry 3 https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
cat >/etc/apt/sources.list.d/docker.sources <<'EOF'
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: noble
Components: stable
Architectures: amd64
Signed-By: /etc/apt/keyrings/docker.asc
EOF
apt-get -o APT::Update::Error-Mode=any update
PACKAGES=(ca-certificates curl jq iproute2 rsync e2fsprogs util-linux fdisk mount
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin apparmor procps xz-utils
    systemd systemd-sysv systemd-dev systemd-oomd systemd-resolved systemd-timesyncd
    udev libsystemd0 libudev1 libsystemd-shared libnss-systemd libpam-systemd libcurl3t64-gnutls)
# An empty status database ensures dependencies already present in the builder are included.
: >/tmp/offline-empty-status
apt-get -y --download-only --no-install-recommends \
    -o Dir::State::status=/tmp/offline-empty-status \
    -o Dir::Cache::archives="$OUT/debs/" install "${PACKAGES[@]}"
bash /workspace/offline/package.sh
