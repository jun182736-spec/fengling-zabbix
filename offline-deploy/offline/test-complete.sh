#!/usr/bin/env bash
set -Eeuo pipefail
[[ -f /.dockerenv && ! -S /var/run/docker.sock ]] || exit 2
BUNDLE=/workspace/offline-deps-complete-ubuntu24.04-amd64
case "${1:-}" in
    fixture)
        # Reuse the mixed-version simulation, targeting the consolidated installer.
        # shellcheck disable=SC2016
        sed 's|bash "$EXTRA/repair-offline.sh"|bash /workspace/offline-deps-complete-ubuntu24.04-amd64/install-offline.sh|' \
            /workspace/offline/test-repair.sh >/tmp/test-fixture.sh
        bash /tmp/test-fixture.sh
        ;;
    install)
        bash "$BUNDLE/install-offline.sh" --packages-only
        [[ -z "$(dpkg --audit)" ]]
        test -s "$BUNDLE/installed-dependencies.tsv"
        grep -F $'curl\t8.5.0-2ubuntu10.16\tamd64\tinstalled' "$BUNDLE/installed-dependencies.tsv"
        grep -F $'docker-ce\t5:29.9.2-1~ubuntu.24.04~noble\tamd64\tinstalled' "$BUNDLE/installed-dependencies.tsv"
        echo 'Complete bundle installation and actual-version report passed without network.'
        ;;
    *) exit 2 ;;
esac
