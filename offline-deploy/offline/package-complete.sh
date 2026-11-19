#!/usr/bin/env bash
set -Eeuo pipefail
cd /workspace/offline-deps-complete-ubuntu24.04-amd64
# Validate the merged index against every actual .deb file.
printf 'Package\tVersion\tArchitecture\n' >/tmp/actual-versions.tsv
for FILE in debs/*.deb; do
    # shellcheck disable=SC2016
    dpkg-deb --show --showformat='${Package}\t${Version}\t${Architecture}\n' "$FILE"
done | sort >>/tmp/actual-versions.tsv
diff -u <(sort package-versions.tsv) <(sort /tmp/actual-versions.tsv)
gzip -9c Packages >Packages.gz
sha256sum Packages Packages.gz package-versions.tsv install-offline.sh README.md COMPLETE-BUNDLE debs/*.deb >SHA256SUMS
sha256sum --check --status SHA256SUMS
cd /workspace
tar -czf offline-deps-complete-ubuntu24.04-amd64.tar.gz offline-deps-complete-ubuntu24.04-amd64
sha256sum offline-deps-complete-ubuntu24.04-amd64.tar.gz >offline-deps-complete-ubuntu24.04-amd64.tar.gz.sha256
