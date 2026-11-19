#!/usr/bin/env bash
set -Eeuo pipefail
[[ -f /.dockerenv && ! -S /var/run/docker.sock ]] || exit 2
export DEBIAN_FRONTEND=noninteractive
BASE=/workspace/offline-deps-ubuntu24.04-amd64
EXTRA=/workspace/offline-deps-repair-ubuntu24.04-amd64
mkdir -p /tmp/smoke-lists/partial
printf 'deb [trusted=yes] file:%s ./\ndeb [trusted=yes] file:%s ./\n' "$BASE" "$EXTRA" >/tmp/smoke.list
APT=(apt-get -o Dir::Etc::sourcelist=/tmp/smoke.list -o Dir::Etc::sourceparts=-
    -o Dir::State::lists=/tmp/smoke-lists -o APT::Sandbox::User=root -o APT::Update::Error-Mode=any)
"${APT[@]}" update
"${APT[@]}" -y --no-remove --no-install-recommends install systemd systemd-sysv systemd-dev \
    systemd-oomd systemd-resolved systemd-timesyncd udev libnss-systemd libpam-systemd libcurl3t64-gnutls
bash "$EXTRA/repair-offline.sh" --packages-only
"${APT[@]}" check
[[ -z "$(dpkg --audit)" ]]
dpkg-query -W systemd udev libsystemd0 libudev1 libcurl4t64 curl docker-ce docker-compose-plugin
echo 'Actual offline package installation passed; daemon startup and real old-version payload upgrades are not covered.'
