#!/usr/bin/env bash
# Run only in the disposable test container. No Docker socket or host devices needed.
# Function doubles and globals are consumed by the sourced deployment script.
# shellcheck disable=SC2034,SC2329
set -Eeuo pipefail
[[ -f /.dockerenv && ! -S /var/run/docker.sock ]] || { echo 'Use the isolated test container described in tests/README.md'; exit 2; }
REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ $# == 0 ]]; then
    TEST_ROOT="$(mktemp -d /srv/deploy-regression.XXXXXX)"
    PASSED=0
    run_case() {
        local NAME="$1" EXPECTED="$2" PATTERN="${3:-}" RC=0
        export CASE_DIR="$TEST_ROOT/$NAME"
        mkdir -p "$CASE_DIR"
        bash "$0" "$NAME" >"$CASE_DIR/output" 2>&1 || RC=$?
        if [[ "$RC" != "$EXPECTED" ]] || { [[ -n "$PATTERN" ]] && ! grep -qs -- "$PATTERN" "$CASE_DIR/output" "$CASE_DIR/deploy.log"; }; then
            cat "$CASE_DIR/output"; echo "FAIL: $NAME (exit $RC, expected $EXPECTED, pattern $PATTERN)"; exit 1
        fi
        if [[ -f "$CASE_DIR/expect-rollback" ]]; then
            cmp "$CASE_DIR/original-config" "$CASE_DIR/daemon.json"
            cmp "$CASE_DIR/original-fstab" "$CASE_DIR/fstab"
            [[ -f "$CASE_DIR/running" && -f "$CASE_DIR/source/marker" ]]
        fi
        if [[ -f "$CASE_DIR/expect-no-stop" ]]; then
            if grep -Eq '^(systemctl stop|wipefs|sfdisk|mkfs)' "$CASE_DIR/events"; then
                echo "FAIL: $NAME performed a mutation before rejecting input"; exit 1
            fi
        fi
        if [[ "$NAME" == no_original_config ]]; then [[ ! -e "$CASE_DIR/daemon.json" ]]; fi
        if [[ "$NAME" == stale_partition ]]; then [[ -f "$CASE_DIR/destination/docker/old-database" ]]; fi
        echo "PASS: $NAME"
        PASSED=$((PASSED + 1))
    }
    run_case fresh_success 0
    run_case mounted_success 0
    run_case start_failure 1 '原 Docker 已恢复'
    run_case copy_failure 23 '原 Docker 已恢复'
    run_case format_failure 1 '原 Docker 已恢复'
    run_case startup_timeout 1 '原 Docker 已恢复'
    run_case wrong_root 1 '原 Docker 已恢复'
    run_case interrupted 130 '原 Docker 已恢复'
    run_case no_original_config 1 '原 Docker 已恢复'
    run_case rollback_failure 1 '恢复失败：原 Docker 未就绪'
    run_case stale_partition 1 '原 Docker 已恢复'
    run_case nonempty_mount 1 '新挂载点必须为空'
    run_case nonempty_target 1 '目标 Docker 目录非空'
    run_case symlink_mount 1 '不能使用系统目录'
    run_case traversal_mount 1 '不能使用系统目录'
    run_case overlap_source 1 '互相包含'
    run_case overlap_script 1 '互相包含'
    run_case containerd 1 'containerd 镜像存储'
    run_case unsupported_driver 1 '仅支持 overlay2/vfs'
    run_case live_restore 1 'live-restore'
    run_case remote_context 1 '本机 rootful Docker socket'
    run_case bad_config 1 'JSON 对象'
    run_case low_space 1 '数据盘空间不足'
    run_case fstab_conflict 1 'fstab 中已有冲突'
    run_case fstab_duplicate 1 'fstab 中已有冲突'
    run_case fstab_fresh_conflict 1 '新数据盘挂载点已有 fstab'
    run_case fstab_existing_entry 0
    run_case unknown_system_disk 1 '无法识别系统盘'
    run_case apt_failure 100 '退出码 100'
    run_case apt_retry_failure 42 '退出码 42'
    run_case apt_retry_success 0 '重试成功'
    run_case unhealthy_recovers 0 'running / healthy'
    run_case unhealthy_timeout 1 '健康状态超时'
    run_case missing_healthcheck 1 '缺少健康检查'
    run_case partition_names 0
    echo "All $PASSED regression cases passed."
    exit 0
fi

CASE="$1"
# shellcheck disable=SC1091
source "$REPO/deploy.sh"
trap 'fail "test command failed at $LINENO"' ERR
trap cleanup EXIT
trap 'fail "test interrupted" 130' INT
LOG_FILE="$CASE_DIR/deploy.log"
WORK_DIR="$CASE_DIR/work"
SCRIPT_DIR="$REPO"
DAEMON_CONFIG="$CASE_DIR/daemon.json"
FSTAB_FILE="$CASE_DIR/fstab"
DATA_MOUNT="$CASE_DIR/destination"
DATA_DISK=/dev/zabbix-audit-disk
mkdir -p "$WORK_DIR" "$CASE_DIR/source" /run/systemd/system
[[ -b "$DATA_DISK" ]] || mknod "$DATA_DISK" b 240 10
[[ -b "${DATA_DISK}1" ]] || mknod "${DATA_DISK}1" b 240 11
printf 'source-data\n' >"$CASE_DIR/source/marker"
jq -n --arg p "$CASE_DIR/source" '{"data-root":$p,"log-driver":"json-file"}' >"$DAEMON_CONFIG"
printf '# original fstab\n' >"$FSTAB_FILE"
cp "$DAEMON_CONFIG" "$CASE_DIR/original-config"
cp "$FSTAB_FILE" "$CASE_DIR/original-fstab"
touch "$CASE_DIR/running" "$CASE_DIR/events"
unset DOCKER_HOST DOCKER_CONTEXT
DRIVER=overlay2
LIVE_RESTORE=false
SNAPSHOTTER=false
REUSED=0

# Every system/disk mutation is a function double; config/fixture writes stay in the container.
systemctl() {
    echo "systemctl $*" >>"$CASE_DIR/events"
    case "$1" in
        is-active) [[ -f "$CASE_DIR/running" ]] ;;
        stop) rm -f "$CASE_DIR/running" ;;
        start)
            if [[ "$CASE" == rollback_failure ]]; then return 1; fi
            if [[ ( "$CASE" == start_failure || "$CASE" == no_original_config ) && -f "$DAEMON_CONFIG" ]] &&
                [[ "$(jq -r '."data-root"' "$DAEMON_CONFIG")" == "$DOCKER_ROOT" ]]; then return 1; fi
            touch "$CASE_DIR/running" ;;
        daemon-reload) return 0 ;;
        *) echo "unexpected systemctl $*" >&2; return 99 ;;
    esac
}
docker() {
    local ROOT="$CASE_DIR/source"
    [[ ! -f "$DAEMON_CONFIG" ]] || ROOT="$(jq -r '."data-root" // empty' "$DAEMON_CONFIG" 2>/dev/null || true)"
    [[ -n "$ROOT" ]] || ROOT="$CASE_DIR/source"
    case "$1" in
        context)
            if [[ "$2" == show ]]; then echo default
            elif [[ "$CASE" == remote_context ]]; then echo tcp://example.invalid:2376
            else echo unix:///var/run/docker.sock; fi ;;
        info)
            [[ -f "$CASE_DIR/running" ]] || return 1
            if [[ "$*" == *'{{json .}}'* ]]; then
                jq -n --arg p "$ROOT" --arg d "$DRIVER" --argjson live "$LIVE_RESTORE" --argjson snap "$SNAPSHOTTER" \
                    '{DockerRootDir:$p,Driver:$d,LiveRestoreEnabled:$live,DriverStatus:(if $snap then [["driver-type","io.containerd.snapshotter.v1"]] else [] end)}'
            else
                if [[ "$ROOT" == "$DOCKER_ROOT" && "$CASE" == startup_timeout ]]; then return 1; fi
                if [[ "$ROOT" == "$DOCKER_ROOT" && "$CASE" == wrong_root ]]; then echo /wrong/root; else echo "$ROOT"; fi
            fi ;;
        inspect)
            if [[ "$*" == *'.State.Status'* ]]; then echo running
            elif [[ "$CASE" == missing_healthcheck ]]; then echo missing
            elif [[ "$CASE" == unhealthy_timeout || ! -f "$CASE_DIR/health-probed" ]]; then
                touch "$CASE_DIR/health-probed"; echo unhealthy
            else echo healthy; fi ;;
        *) echo "unexpected docker $*" >&2; return 99 ;;
    esac
}
lsblk() {
    case "$*" in
        '-dno TYPE '*) echo disk ;;
        '-snro NAME,TYPE '*) [[ "$CASE" == unknown_system_disk ]] || echo 'systemdisk disk' ;;
        '-nlo NAME,TYPE '*) echo 'zabbix-audit-disk disk' ;;
        *MOUNTPOINT*) [[ ! -f "$CASE_DIR/mounted" ]] || echo "$DATA_MOUNT" ;;
        *) echo "unexpected lsblk $*" >&2; return 99 ;;
    esac
    return 0
}
findmnt() {
    if [[ "$*" == '-no SOURCE /' ]]; then echo /dev/systemdisk
    elif [[ -f "$CASE_DIR/mounted" ]]; then echo "${DATA_DISK}1"
    else return 1; fi
}
blkid() {
    case "$*" in
        *' -s LABEL '*) [[ "$REUSED" == 1 ]] && echo zabbix-docker ;;
        *' -s UUID '*) echo aaaa-bbbb ;;
        *'-p '*) return 2 ;;
        *' -s TYPE '*) echo ext4 ;;
        *) return 99 ;;
    esac
}
blockdev() { [[ "$1" != --getsize64 ]] || echo 107374182400; }
wipefs() { echo wipefs >>"$CASE_DIR/events"; }
sfdisk() { echo sfdisk >>"$CASE_DIR/events"; }
mkfs.ext4() { echo mkfs >>"$CASE_DIR/events"; [[ "$CASE" != format_failure ]]; }
mount() {
    echo mount >>"$CASE_DIR/events"
    touch "$CASE_DIR/mounted"
    if [[ "$CASE" == stale_partition ]]; then mkdir -p "$DOCKER_ROOT"; touch "$DOCKER_ROOT/old-database"; fi
    return 0
}
umount() { echo umount >>"$CASE_DIR/events"; rm -f "$CASE_DIR/mounted"; }
df() {
    echo 'Filesystem 1024-blocks Used Available Capacity Mounted on'
    if [[ "$CASE" == low_space ]]; then echo '/dev/test 1000 990 10 99% /data'
    else echo '/dev/test 100000000 1000 99999000 1% /data'; fi
}
rsync() {
    local SOURCE TARGET
    SOURCE="${*: -2:1}"; TARGET="${*: -1}"
    echo "rsync $*" >>"$CASE_DIR/events"
    [[ "$SOURCE" == "$CASE_DIR/source/" ]] || return 98
    if [[ "$CASE" == copy_failure ]]; then return 23; fi
    if [[ "$CASE" == interrupted ]]; then kill -INT "$$"; return 0; fi
    cp "$CASE_DIR/source/marker" "$TARGET/marker"
}
sleep() { SECONDS=$((SECONDS + 30)); }

case "$CASE" in
    apt_*)
        apt-get() {
            if [[ ! -f "$CASE_DIR/apt-called" ]]; then touch "$CASE_DIR/apt-called"; return 100; fi
            [[ "$CASE" != apt_retry_failure ]] || return 42
        }
        disable_local_media_sources() { [[ "$CASE" != apt_failure ]]; }
        apt_get_update
        exit 0 ;;
    unhealthy_*|missing_healthcheck) WAIT_TIMEOUT=60; wait_healthy test-container; exit 0 ;;
    partition_names)
        [[ "$(data_part_dev /dev/vdb)" == /dev/vdb1 ]]
        [[ "$(data_part_dev /dev/nvme0n12)" == /dev/nvme0n12p1 ]]
        [[ "$(data_part_dev /dev/mmcblk0)" == /dev/mmcblk0p1 ]]; exit 0 ;;
    fresh_success|mounted_success|fstab_existing_entry) ;;
    start_failure|copy_failure|format_failure|startup_timeout|wrong_root|interrupted|stale_partition)
        touch "$CASE_DIR/expect-rollback"
        [[ "$CASE" != stale_partition ]] || REUSED=1 ;;
    no_original_config) rm "$DAEMON_CONFIG" ;;
    rollback_failure) ;;
    *) touch "$CASE_DIR/expect-no-stop" ;;
esac
case "$CASE" in
    mounted_success|nonempty_target|low_space|fstab_conflict|fstab_duplicate|fstab_existing_entry)
        REUSED=1; touch "$CASE_DIR/mounted"; mkdir -p "$DATA_MOUNT" ;;
esac
case "$CASE" in
    nonempty_target) mkdir -p "$DATA_MOUNT/docker"; touch "$DATA_MOUNT/docker/old" ;;
    nonempty_mount) mkdir -p "$DATA_MOUNT"; touch "$DATA_MOUNT/important" ;;
    symlink_mount) ln -s /etc "$CASE_DIR/link"; DATA_MOUNT="$CASE_DIR/link" ;;
    traversal_mount) DATA_MOUNT=/srv/../var ;;
    overlap_source) DATA_MOUNT="$CASE_DIR/source/child" ;;
    overlap_script) DATA_MOUNT="$REPO/child" ;;
    containerd) SNAPSHOTTER=true; DRIVER=overlayfs ;;
    unsupported_driver) DRIVER=btrfs ;;
    live_restore) LIVE_RESTORE=true ;;
    bad_config) echo '[]' >"$DAEMON_CONFIG" ;;
    fstab_conflict) printf 'UUID=cccc-dddd %s ext4 defaults 0 2\n' "$DATA_MOUNT" >>"$FSTAB_FILE" ;;
    fstab_duplicate) printf 'UUID=aaaa-bbbb %s ext4 defaults 0 2\nUUID=aaaa-bbbb /other ext4 defaults 0 2\n' "$DATA_MOUNT" >>"$FSTAB_FILE" ;;
    fstab_existing_entry) printf 'UUID=aaaa-bbbb %s ext4 defaults 0 2\n' "$DATA_MOUNT" >>"$FSTAB_FILE" ;;
    fstab_fresh_conflict) printf 'UUID=cccc-dddd %s ext4 defaults 0 2\n' "$DATA_MOUNT" >>"$FSTAB_FILE" ;;
esac
setup_data_disk
[[ "$MIGRATION_ACTIVE" == 0 ]]
cmp "$CASE_DIR/source/marker" "$DOCKER_ROOT/marker"
[[ "$(jq -r '."data-root"' "$DAEMON_CONFIG")" == "$DOCKER_ROOT" ]]
[[ "$(jq -r '."log-driver"' "$DAEMON_CONFIG")" == json-file ]]
[[ "$(grep -c '^UUID=' "$FSTAB_FILE")" == 1 ]]
# Repeated execution must skip copying and formatting.
REUSED=1
setup_data_disk
[[ "$(grep -c '^rsync ' "$CASE_DIR/events")" == 1 ]]
