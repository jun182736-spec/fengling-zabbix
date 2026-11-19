#!/usr/bin/env bash
set -Eeuo pipefail
OUT=/workspace/offline-deps-repair-ubuntu24.04-amd64
cd "$OUT"
dpkg-scanpackages --multiversion debs /dev/null >Packages
gzip -9c Packages >Packages.gz
{
    printf 'Origin: Zabbix Offline Repair\nLabel: Zabbix Offline Repair\nArchitectures: amd64 all\nDate: %s\nSHA256:\n' "$(date -Ru)"
    for FILE in Packages Packages.gz; do
        HASH="$(sha256sum "$FILE")"; HASH="${HASH%% *}"
        printf ' %s %s %s\n' "$HASH" "$(stat -c %s "$FILE")" "$FILE"
    done
} >Release
cp /workspace/offline/install.sh install-offline-v2.sh
cp /workspace/offline/repair-entry.sh repair-offline.sh
printf 'Package\tVersion\tArchitecture\n' >package-versions.tsv
for FILE in debs/*.deb; do
    # shellcheck disable=SC2016
    dpkg-deb --show --showformat='${Package}\t${Version}\t${Architecture}\n' "$FILE" >>package-versions.tsv
done
cp /workspace/offline/REPAIR.md README.md
sha256sum Packages Packages.gz Release install-offline-v2.sh repair-offline.sh package-versions.tsv README.md debs/*.deb >SHA256SUMS
cd /workspace
tar -czf offline-deps-repair-ubuntu24.04-amd64.tar.gz offline-deps-repair-ubuntu24.04-amd64
sha256sum offline-deps-repair-ubuntu24.04-amd64.tar.gz >offline-deps-repair-ubuntu24.04-amd64.tar.gz.sha256
