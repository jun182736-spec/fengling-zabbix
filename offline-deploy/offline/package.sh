#!/usr/bin/env bash
set -Eeuo pipefail
OUT=/workspace/offline-deps-ubuntu24.04-amd64
cd "$OUT"
dpkg-scanpackages --multiversion debs /dev/null >Packages
gzip -9c Packages >Packages.gz
printf 'Package\tVersion\tArchitecture\n' >package-versions.tsv
for FILE in debs/*.deb; do
    # dpkg-deb expands these fields, not the shell.
    # shellcheck disable=SC2016
    dpkg-deb --show --showformat='${Package}\t${Version}\t${Architecture}\n' "$FILE" >>package-versions.tsv
done
cp /workspace/offline/install.sh install-offline.sh
cp /workspace/offline/README.md README.md
{
    printf 'Built: '; date -u '+%Y-%m-%dT%H:%M:%SZ'
    printf 'Target: Ubuntu 24.04 (noble), amd64\n'
    printf 'Ubuntu packages: signed official Ubuntu repositories\nDocker packages: signed download.docker.com/linux/ubuntu noble stable\n'
    printf 'Includes: deployment utilities, Docker CE, CLI, containerd, Compose, Buildx, AppArmor, procps, xz-utils and dependencies.\n'
} >BUILD-INFO.txt
sha256sum Packages Packages.gz package-versions.tsv install-offline.sh README.md BUILD-INFO.txt debs/*.deb >SHA256SUMS
cd /workspace
tar -czf offline-deps-ubuntu24.04-amd64.tar.gz offline-deps-ubuntu24.04-amd64
sha256sum offline-deps-ubuntu24.04-amd64.tar.gz >offline-deps-ubuntu24.04-amd64.tar.gz.sha256
echo 'Offline bundle ready.'
