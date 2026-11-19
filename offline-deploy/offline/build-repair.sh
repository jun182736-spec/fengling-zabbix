#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive LC_ALL=C
[[ -f /.dockerenv ]] || exit 2
BASE=/workspace/offline-deps-ubuntu24.04-amd64
OUT=/workspace/offline-deps-repair-ubuntu24.04-amd64
mkdir -p "$OUT/debs/partial"
rm -f /etc/apt/apt.conf.d/docker-clean
apt-get -o APT::Update::Error-Mode=any update
apt-get install -y --no-install-recommends dpkg-dev ca-certificates curl
SYSTEM_VERSION="$(dpkg-deb -f "$BASE"/debs/libsystemd0_*.deb Version)"
CURL_VERSION="$(dpkg-deb -f "$BASE"/debs/libcurl4t64_*.deb Version)"
PACKAGES=()
for PACKAGE in systemd systemd-sysv systemd-dev systemd-oomd systemd-resolved systemd-timesyncd \
    udev libsystemd0 libudev1 libsystemd-shared libnss-systemd libpam-systemd; do
    PACKAGES+=("$PACKAGE=$SYSTEM_VERSION")
done
PACKAGES+=("curl=$CURL_VERSION" "libcurl4t64=$CURL_VERSION" "libcurl3t64-gnutls=$CURL_VERSION")
: >/tmp/offline-repair-empty-status
apt-get -y --download-only --no-install-recommends \
    -o Dir::State::status=/tmp/offline-repair-empty-status \
    -o Dir::Cache::archives="$OUT/debs/" install "${PACKAGES[@]}"
# Only ship additions. The original checksum-verified bundle remains required.
for FILE in "$BASE"/debs/*.deb; do
    OTHER="$OUT/debs/$(basename -- "$FILE")"
    if [[ -f "$OTHER" ]] && cmp -s "$FILE" "$OTHER"; then rm -- "$OTHER"; fi
done
bash /workspace/offline/package-repair.sh
