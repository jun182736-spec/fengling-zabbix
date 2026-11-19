#!/usr/bin/env bash
# Complete Ubuntu 24.04 amd64 offline dependency installation and Zabbix deployment.
set -Eeuo pipefail
[[ "$EUID" == 0 ]] || { echo 'Run: sudo bash deploy-offline.sh'; exit 2; }
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
cd "$ROOT"
BUNDLE=offline-deps-complete-ubuntu24.04-amd64
if [[ ! -d "$BUNDLE" ]]; then
    sha256sum -c "$BUNDLE.tar.gz.sha256"
    tar -xzf "$BUNDLE.tar.gz"
fi
bash "$BUNDLE/install-offline.sh"
exec bash "$ROOT/deploy.sh" --offline "$@"
