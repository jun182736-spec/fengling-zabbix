#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ZABBIX_OFFLINE_BASE="$(dirname -- "$HERE")/offline-deps-ubuntu24.04-amd64"
ZABBIX_OFFLINE_EXTRA="$HERE"
export ZABBIX_OFFLINE_BASE ZABBIX_OFFLINE_EXTRA
[[ -f "$ZABBIX_OFFLINE_BASE/SHA256SUMS" ]] || {
    echo 'Extract this repair bundle beside the original offline-deps-ubuntu24.04-amd64 directory.'; exit 1;
}
exec bash "$HERE/install-offline-v2.sh" "$@"
