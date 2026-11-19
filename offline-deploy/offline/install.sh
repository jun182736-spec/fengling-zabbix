#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
MODE="${1:-install}"
case "$MODE" in install|--check-only|--packages-only) ;; *) echo 'Usage: sudo bash install-offline.sh [--check-only|--packages-only]'; exit 2 ;; esac
[[ $# -le 1 && "$EUID" == 0 ]] || { echo 'Run with sudo.'; exit 2; }
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == 24.04 && "$(dpkg --print-architecture)" == amd64 ]] || {
    echo 'This bundle supports Ubuntu 24.04 amd64 only.'; exit 2;
}
BUNDLE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
BUNDLE="${ZABBIX_OFFLINE_BASE:-$BUNDLE}"
[[ "$BUNDLE" =~ ^/[A-Za-z0-9._/-]+$ ]] || { echo 'Use a path without spaces or special characters.'; exit 2; }
cd "$BUNDLE"
echo 'Verifying offline package checksums...'
sha256sum --check --status SHA256SUMS || { echo 'Checksum verification failed. Re-upload the complete bundle.'; exit 1; }
EXTRA="${ZABBIX_OFFLINE_EXTRA:-}"
if [[ -n "$EXTRA" ]]; then
    [[ "$EXTRA" =~ ^/[A-Za-z0-9._/-]+$ && "$EXTRA" != "$BUNDLE" ]] || exit 2
    (cd "$EXTRA" && sha256sum --check --status SHA256SUMS) || { echo 'Repair bundle checksum verification failed.'; exit 1; }
fi
WORK="$(mktemp -d /tmp/zabbix-offline-apt.XXXXXX)"
trap 'rm -rf -- "$WORK"' EXIT
mkdir -p "$WORK/lists/partial" "$WORK/archives/partial"
# Add Release metadata in a temporary directory so apt does not probe absent compression formats.
add_local_repository() {
    local SOURCE="$1" TARGET="$2" FILE HASH
    mkdir -p "$TARGET"
    for FILE in Packages Packages.gz debs; do ln -s "$SOURCE/$FILE" "$TARGET/$FILE"; done
    {
        printf 'Origin: Zabbix Offline\nArchitectures: amd64 all\nDate: %s\nSHA256:\n' "$(date -Ru)"
        for FILE in Packages Packages.gz; do
            HASH="$(sha256sum "$SOURCE/$FILE")"; HASH="${HASH%% *}"
            printf ' %s %s %s\n' "$HASH" "$(stat -c %s "$SOURCE/$FILE")" "$FILE"
        done
    } >"$TARGET/Release"
    printf 'deb [trusted=yes arch=amd64] file:%s ./\n' "$TARGET" >>"$WORK/offline.list"
}
add_local_repository "$BUNDLE" "$WORK/base"
if [[ -n "$EXTRA" ]]; then add_local_repository "$EXTRA" "$WORK/extra"; fi
# Only this local file repository is visible to these apt commands. System sources are untouched.
APT=(apt-get -o "Dir::Etc::sourcelist=$WORK/offline.list" -o Dir::Etc::sourceparts=-
    -o "Dir::State::lists=$WORK/lists" -o "Dir::Cache::archives=$WORK/archives"
    -o APT::Sandbox::User=root -o APT::Update::Error-Mode=any -o Acquire::Languages=none)
PACKAGES=(ca-certificates curl libcurl4t64 jq iproute2 rsync e2fsprogs util-linux fdisk mount)
# Keep installed systemd components in step with their exact-version libraries.
# Do not introduce resolved/timesyncd/etc. on hosts using alternatives.
if [[ -n "$EXTRA" || -f "$BUNDLE/COMPLETE-BUNDLE" ]]; then
    for PACKAGE in systemd systemd-sysv systemd-dev systemd-oomd systemd-resolved systemd-timesyncd \
        udev libsystemd0 libudev1 libsystemd-shared libnss-systemd libpam-systemd libcurl3t64-gnutls; do
        STATUS="$(dpkg-query -W -f='${db:Status-Status}' "$PACKAGE" 2>/dev/null || true)"
        case "$STATUS" in
            installed|unpacked|half-configured|half-installed|triggers-awaited|triggers-pending) PACKAGES+=("$PACKAGE") ;;
        esac
    done
fi
if command -v docker >/dev/null 2>&1; then
    docker --version
    echo 'Existing Docker detected; preserving the installed engine.'
    if ! docker compose version >/dev/null 2>&1; then PACKAGES+=(docker-compose-plugin); fi
else
    for PACKAGE in docker.io docker-compose docker-compose-v2 podman-docker containerd runc; do
        STATUS="$(dpkg-query -W -f='${Status}' "$PACKAGE" 2>/dev/null || true)"
        [[ "$STATUS" != 'install ok installed' ]] || {
            echo "Conflicting installed package: $PACKAGE. Nothing has been removed; review the existing container runtime first."; exit 1;
        }
    done
    PACKAGES+=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin apparmor procps xz-utils)
fi
echo 'Checking the installation plan using local packages only...'
"${APT[@]}" update
"${APT[@]}" --simulate --fix-broken --no-remove --no-install-recommends install "${PACKAGES[@]}"
[[ "$MODE" != --check-only ]] || { echo 'Offline dependency resolution passed; no packages installed.'; exit 0; }
if [[ "$MODE" == install && ! -d /run/systemd/system ]]; then
    echo 'Normal installation requires a running systemd host. Use --packages-only only for package validation.'; exit 1
fi
DEBIAN_FRONTEND=noninteractive "${APT[@]}" -y --fix-broken --no-remove --no-install-recommends \
    -o Dpkg::Options::=--force-confold install "${PACKAGES[@]}"
"${APT[@]}" check
# Record actual installed versions separately from the versions available in this bundle.
REPORT="$WORK/installed-dependencies.tsv"
printf 'Package\tVersion\tArchitecture\tStatus\n' >"$REPORT"
while IFS=$'\t' read -r PACKAGE _; do
    [[ "$PACKAGE" != Package && -n "$PACKAGE" ]] || continue
    STATUS="$(dpkg-query -W -f='${db:Status-Status}' "$PACKAGE" 2>/dev/null || true)"
    if [[ "$STATUS" == installed ]]; then
        dpkg-query -W -f='${Package}\t${Version}\t${Architecture}\t${db:Status-Status}\n' "$PACKAGE" >>"$REPORT"
    fi
done < <(cat "$BUNDLE/package-versions.tsv" ${EXTRA:+"$EXTRA/package-versions.tsv"} | sort -u)
cp "$REPORT" "$BUNDLE/installed-dependencies.tsv"
echo "Installed dependency versions: $BUNDLE/installed-dependencies.tsv"
for COMMAND in curl jq ip ss rsync mkfs.ext4 lsblk blkid wipefs sfdisk blockdev findmnt mount umount docker; do
    command -v "$COMMAND" >/dev/null || { echo "Missing required command after installation: $COMMAND"; exit 1; }
done
docker --version
docker compose version
if [[ "$MODE" == install ]]; then
    systemctl enable --now docker
    docker info >/dev/null
    echo 'Offline dependencies and Docker are ready. Run: sudo bash deploy.sh --offline'
else
    echo 'Package installation validated; Docker daemon startup was not tested.'
fi
