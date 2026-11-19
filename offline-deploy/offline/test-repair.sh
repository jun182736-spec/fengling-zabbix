#!/usr/bin/env bash
# Run only in a disposable, network-disabled container; fixture changes never reach a host dpkg database.
set -Eeuo pipefail
[[ -f /.dockerenv && ! -S /var/run/docker.sock ]] || exit 2
mkdir -p /tmp/fixture-dpkg/updates /tmp/fixture-bin
cp /workspace/.audit/repair-fixture.status /tmp/fixture-dpkg/status
cat >/tmp/fixture-bin/apt-get <<'EOF'
#!/usr/bin/env bash
exec /usr/bin/apt-get -o Dir::State::status=/tmp/fixture-dpkg/status "$@"
EOF
cat >/tmp/fixture-bin/dpkg-query <<'EOF'
#!/usr/bin/env bash
exec /usr/bin/dpkg-query --admindir=/tmp/fixture-dpkg "$@"
EOF
chmod +x /tmp/fixture-bin/*
export PATH="/tmp/fixture-bin:$PATH"
BASE=/workspace/offline-deps-ubuntu24.04-amd64
EXTRA=/workspace/offline-deps-repair-ubuntu24.04-amd64
RC=0
bash "$BASE/install-offline.sh" --check-only >/tmp/original-result 2>&1 || RC=$?
[[ "$RC" == 100 ]] || { cat /tmp/original-result; echo 'Original installer did not reproduce the failure'; exit 1; }
grep -q 'libsystemd0 (= 255.4-1ubuntu8.17)' /tmp/original-result
echo 'Original installer fails with the observed exact-version conflict (expected).'
bash "$EXTRA/repair-offline.sh" --check-only >/tmp/repaired-result 2>&1
grep -q '0 to remove' /tmp/repaired-result
for PACKAGE in systemd udev libsystemd-shared libnss-systemd libpam-systemd systemd-dev systemd-oomd systemd-resolved systemd-sysv systemd-timesyncd; do
    grep -F "Inst $PACKAGE [255.4-1ubuntu8.17] (255.4-1ubuntu8.18" /tmp/repaired-result
done
grep -F 'Inst libcurl4t64 [8.5.0-2ubuntu10.13] (8.5.0-2ubuntu10.16' /tmp/repaired-result
grep -F 'Inst libcurl3t64-gnutls [8.5.0-2ubuntu10.13] (8.5.0-2ubuntu10.16' /tmp/repaired-result
echo 'Mixed-version fixture repair passed, with no removals and no network.'
