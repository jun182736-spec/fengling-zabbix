#!/usr/bin/env bash
# 风铃云监控管理系统（Zabbix 7.0）平台侧 Ubuntu 一键部署脚本。
# 使用离线三镜像包（含风铃品牌版 Web 镜像）、Docker Compose 与初始化 SQL。
# 不操作 Zabbix API；数据库密码当前按需求固定为 zabbix123，仅适合临时/内网环境。
set -Eeuo pipefail
export LC_ALL=C
umask 027

SCRIPT_DIR=''
LOG_FILE=''
WORK_DIR=''
CURRENT_STEP='初始化'
COMPOSE_FILE=''
ENV_FILE=''
PROJECT_NAME='zabbix-platform'
MYSQL_CONTAINER_NAME='zabbix-mysql'
SERVER_CONTAINER_NAME='zabbix-server'
WEB_CONTAINER_NAME='zabbix-web-custom'
MYSQL_VOLUME_NAME='zabbix-platform_mysql-data'
WEB_PORT='8080'
SERVER_PORT='10051'
WEB_IMAGE='my-zabbix-web:7.0.30'
WAIT_TIMEOUT=900
OFFLINE=0
SKIP_DOCKER_INSTALL=0
DATA_DISK=''
DATA_MOUNT='/data'
DOCKER_ROOT=''
FORCE_FORMAT=0
LOCAL_IP=''
OS_ID=''
OS_VERSION=''
OS_NAME=''
MYSQL_PASSWORD=''
MYSQL_ROOT_PASSWORD=''
DB_BACKUP=''
FRESH_DATABASE=1
HTTP_TEST_HOST='127.0.0.1'
STACK_IDENTIFIED=0
APT_ETC='/etc/apt'
DAEMON_CONFIG='/etc/docker/daemon.json'
FSTAB_FILE='/etc/fstab'
MIGRATION_ACTIVE=0
MIGRATION_CONFIG_CHANGED=0
MIGRATION_FSTAB_CHANGED=0
MIGRATION_MOUNTED=0
MIGRATION_HAD_CONFIG=0
ORIGINAL_DOCKER_ROOT=''
DATA_PART_UUID=''
DATA_FSTAB_ENTRY=''

# 同时显示关键进度并写入日志；敏感凭据不传给此函数。
log() {
    if [[ -n "$LOG_FILE" ]]; then
        printf '[%s] %s\n' "$(date '+%F %T%z')" "$*" | tee -a "$LOG_FILE"
    else
        printf '%s\n' "$*"
    fi
}

# 固定 Compose 文件、项目名及 .env，避免调用目录变化造成新建另一套数据库。
compose() {
    env -u COMPOSE_PROJECT_NAME -u MYSQL_CONTAINER_NAME -u SERVER_CONTAINER_NAME -u WEB_CONTAINER_NAME \
        -u MYSQL_VOLUME_NAME -u WEB_PORT -u SERVER_PORT -u MYSQL_PASSWORD -u MYSQL_ROOT_PASSWORD \
        docker compose --project-directory "$SCRIPT_DIR" --env-file "$ENV_FILE" \
        -p "$PROJECT_NAME" -f "$COMPOSE_FILE" "$@"
}

# 错误时只收集本项目容器的状态和日志，不删除容器或数据卷。
diagnostics() {
    local NAME
    [[ "$STACK_IDENTIFIED" == 1 ]] || return 0
    for NAME in "$MYSQL_CONTAINER_NAME" "$SERVER_CONTAINER_NAME" "$WEB_CONTAINER_NAME"; do
        docker inspect --format '{{.Name}} status={{.State.Status}} error={{.State.Error}}' "$NAME" 2>/dev/null || true
        docker logs --tail 40 "$NAME" 2>&1 || true
    done
}

# 集中显示具体错误原因、日志路径并立即退出；失败时保留现场供排查。
fail() {
    local MESSAGE="$1" CODE="${2:-1}"
    trap - ERR INT TERM
    set +e
    log "错误：$CURRENT_STEP：$MESSAGE"
    rollback_data_disk
    if [[ -n "$LOG_FILE" ]]; then
        diagnostics >>"$LOG_FILE" 2>&1
        printf '\n最近日志（完整日志：%s）：\n' "$LOG_FILE"
        tail -n 60 "$LOG_FILE"
    fi
    exit "$CODE"
}

# 执行不含秘密的外部命令，保存完整输出并捕获退出码。
run_command() {
    local CODE
    log "执行：$*"
    if "$@" >>"$LOG_FILE" 2>&1; then return 0; else
        CODE=$?
        fail "命令 $1 失败，退出码 $CODE，详见日志。" "$CODE"
    fi
}

# 清理本次临时目录；持久数据、.env、备份、日志均保留。
cleanup() {
    rollback_data_disk
    [[ -z "$WORK_DIR" || ! -d "$WORK_DIR" ]] || rm -rf -- "$WORK_DIR"
    return 0
}

# 解析可选参数；自定义名称和端口通过 .env 设置，不自动重置已有配置。
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --offline) OFFLINE=1; SKIP_DOCKER_INSTALL=1 ;;
            --skip-docker-install) SKIP_DOCKER_INSTALL=1 ;;
            --wait-timeout)
                [[ $# -ge 2 && "$2" =~ ^[0-9]{2,4}$ ]] || fail '--wait-timeout 需要 60–3600 秒。'
                WAIT_TIMEOUT=$((10#$2))
                (( WAIT_TIMEOUT >= 60 && WAIT_TIMEOUT <= 3600 )) || fail '--wait-timeout 需要 60–3600 秒。'
                shift ;;
            --data-disk)
                [[ $# -ge 2 && -n "$2" ]] || fail '--data-disk 需要整块磁盘路径，例如 /dev/vdb。'
                DATA_DISK="$2"; shift ;;
            --data-mount)
                [[ $# -ge 2 && -n "$2" ]] || fail '--data-mount 需要挂载路径，例如 /data。'
                DATA_MOUNT="$2"; shift ;;
            --force-format)
                # 只有显式确认磁盘可清空时才允许覆盖已有分区/文件系统。
                FORCE_FORMAT=1 ;;
            --help|-h)
                printf '用法：sudo bash deploy.sh [--offline] [--skip-docker-install] [--wait-timeout 900]\n'
                printf '      sudo bash deploy.sh --data-disk /dev/vdb [--data-mount /data] [--force-format]\n'
                exit 0 ;;
            *) fail "未知参数：$1" ;;
        esac
        shift
    done
}

# 校验执行身份、Ubuntu 版本、创建私有日志并取得进程锁。
initialize() {
    local COMMAND
    [[ "$EUID" == 0 ]] || fail '请使用 sudo bash deploy.sh 运行。'
    for COMMAND in awk sed grep sort date tee hostname uname mktemp mkdir chmod cp mv rm dirname basename flock gzip sha256sum od tr tar install timeout tail sleep realpath find; do
        command -v "$COMMAND" >/dev/null 2>&1 || fail "缺少基础命令：$COMMAND"
    done
    [[ "$(uname -s)" == Linux ]] || fail '此脚本用于 Linux 服务器。'
    [[ "$(uname -m)" == x86_64 ]] || fail '离线镜像为 linux/amd64，请使用 x86_64 服务器。'
    [[ -r /etc/os-release ]] || fail '无法读取 /etc/os-release。'
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-}"; OS_VERSION="${VERSION_ID:-}"; OS_NAME="${PRETTY_NAME:-$OS_ID}"
    [[ "$OS_ID" == ubuntu ]] || fail "本脚本仅支持 Ubuntu，当前系统：$OS_NAME。"
    case "$OS_VERSION" in
        20.04|22.04|24.04|26.04) ;;
        *) fail "不支持的 Ubuntu 版本：$OS_VERSION（支持 20.04、22.04、24.04、26.04）。" ;;
    esac
    if [[ -n "$DATA_DISK" ]]; then
        normalize_data_mount
        log "数据盘模式：$DATA_DISK → $DATA_MOUNT（Docker data-root=$DOCKER_ROOT）"
    fi
    SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
    COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yaml"
    ENV_FILE="$SCRIPT_DIR/.env"
    mkdir -p "$SCRIPT_DIR/logs" "$SCRIPT_DIR/backups"
    chmod 700 "$SCRIPT_DIR/logs" "$SCRIPT_DIR/backups"
    LOG_FILE="$(mktemp "$SCRIPT_DIR/logs/deploy-$(date '+%Y%m%d-%H%M%S')-XXXXXX.log")"
    WORK_DIR="$(mktemp -d /tmp/zabbix-docker-deploy.XXXXXX)"
    exec 9>/run/lock/zabbix-platform-deploy.lock
    flock -n 9 || fail '另一份 Zabbix Docker 部署脚本正在执行。'
    log "系统：$OS_NAME；架构：x86_64"
    log "部署目录：$SCRIPT_DIR"
    log "日志：$LOG_FILE"
}

# 用 apt 安装下载、JSON 解析、端口检测与数据盘工具；离线模式只校验现有工具。
ensure_tools() {
    local COMMAND NEED_TOOLS=0
    local -a PACKAGES
    for COMMAND in curl jq ss ip; do
        command -v "$COMMAND" >/dev/null 2>&1 || NEED_TOOLS=1
    done
    if [[ -n "$DATA_DISK" ]]; then
        for COMMAND in rsync mkfs.ext4 sfdisk lsblk blkid wipefs blockdev findmnt mount umount; do
            command -v "$COMMAND" >/dev/null 2>&1 || NEED_TOOLS=1
        done
    fi
    if [[ "$NEED_TOOLS" == 1 ]]; then
        [[ "$OFFLINE" == 0 ]] || fail '离线模式需要预装 curl、jq、iproute2；数据盘模式还需 rsync、e2fsprogs、util-linux、fdisk、mount。'
        apt_get_update
        PACKAGES=(ca-certificates jq iproute2)
        command -v curl >/dev/null 2>&1 || PACKAGES+=(curl)
        if [[ -n "$DATA_DISK" ]]; then PACKAGES+=(rsync e2fsprogs util-linux fdisk mount); fi
        run_command env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${PACKAGES[@]}"
    fi
    if [[ -n "$DATA_DISK" ]]; then
        for COMMAND in lsblk blkid wipefs sfdisk mkfs.ext4 blockdev findmnt mount umount rsync df du systemctl; do
            command -v "$COMMAND" >/dev/null 2>&1 || fail "数据盘模式缺少命令：$COMMAND（需要 util-linux、fdisk、mount、e2fsprogs、rsync、systemd）"
        done
    fi
}

# 下载单个 HTTPS 文件并验证 TLS，限制超时和重试。
download() {
    run_command curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
        --connect-timeout 10 --max-time 120 --retry 2 -o "$2" "$1"
}

# 判断 deb822 源文件中指向本地媒体（ISO/挂载点）的段并整段注释。
# 返回 0=已修改，1=无需修改，2=同一段内混有其他源需人工处理。
apt_sources_drop_local_stanzas() {
    local SRC="$1" OUT="$2" RC=0
    awk '
    function flush(   i) {
        if (n == 0) { return }
        if (drop) {
            for (i = 1; i <= n; i++) { print "# disabled by deploy.sh: " buf[i] }
            changed = 1
        }
        else {
            for (i = 1; i <= n; i++) { print buf[i] }
        }
        n = 0; drop = 0
    }
    /^[[:space:]]*$/ { flush(); print ""; next }
    {
        if ($0 ~ /^[[:space:]]*URIs:/) {
            uris = $0
            sub(/^[^:]*:[[:space:]]*/, "", uris)
            cnt = split(uris, tok, /[[:space:]]+/)
            total = 0; dead = 0
            for (i = 1; i <= cnt; i++) {
                if (tok[i] == "") { continue }
                total++
                if (tok[i] ~ /^(file:|cdrom:|\[cdrom:)/) { dead++ }
            }
            if (dead > 0 && dead == total) { drop = 1 }
            else if (dead > 0 && dead < total) { mixed = 1 }
        }
        n++; buf[n] = $0
    }
    END {
        flush()
        if (mixed) { exit 2 }
        if (changed) { exit 0 }
        exit 1
    }
    ' "$SRC" >"$OUT" || RC=$?
    return "$RC"
}

# 禁用指向已卸载 ISO/光盘的 apt 源（安装介质移除后 apt-get update 必然 100）。
# 只改本地媒体行，原文件全部备份到日志同目录。
disable_local_media_sources() {
    local F TMP RC=0 CHANGED=0
    for F in "$APT_ETC/sources.list" "$APT_ETC"/sources.list.d/*.list; do
        [[ -f "$F" ]] || continue
        grep -Eq '^[[:space:]]*deb(-src)?([[:space:]]+\[[^]]*\])?[[:space:]]+(cdrom:|file:)' "$F" || continue
        run_command cp -a "$F" "${LOG_FILE%.log}.$(basename "$F").before"
        run_command sed -i -E 's~^([[:space:]]*deb(-src)?([[:space:]]+\[[^]]*\])?[[:space:]]+(cdrom:|file:).*)$~# disabled by deploy.sh: \1~' "$F"
        log "已禁用本地媒体源：$F（备份：${LOG_FILE%.log}.$(basename "$F").before）"
        CHANGED=1
    done
    for F in "$APT_ETC"/sources.list.d/*.sources; do
        [[ -f "$F" ]] || continue
        TMP="$WORK_DIR/$(basename "$F").filtered"
        RC=0
        apt_sources_drop_local_stanzas "$F" "$TMP" || RC=$?
        case "$RC" in
            0)
                run_command cp -a "$F" "${LOG_FILE%.log}.$(basename "$F").before"
                run_command install -m 0644 "$TMP" "$F"
                log "已注释本地媒体源段：$F（备份已保留）"
                CHANGED=1 ;;
            2)
                fail "$F 同时包含本地媒体源和其他源，无法安全自动修改；请手工删除其中的 file:/cdrom: URI 后重试。" ;;
            *) : ;;
        esac
    done
    [[ "$CHANGED" == 1 ]]
}

# apt-get update 包装：遇到失效的 cdrom/file 源时禁用后重试一次。
apt_get_update() {
    local RC=0
    log '执行：apt-get update'
    if apt-get update >>"$LOG_FILE" 2>&1; then return 0; else RC=$?; fi
    log "apt-get update 失败（退出码 $RC），检查失效的 cdrom/file 源..."
    if disable_local_media_sources; then
        log '已禁用失效的本地媒体源，重试 apt-get update...'
        if apt-get update >>"$LOG_FILE" 2>&1; then
            log 'apt-get update 重试成功。'
            return 0
        else
            RC=$?
        fi
    fi
    fail "apt-get update 失败（退出码 $RC）；请修复 /etc/apt/sources.list* 后重试，详见日志。" "$RC"
}

# Docker 缺失时使用 Docker 官方 APT 仓库安装；不删除冲突包，不覆盖已有仓库配置。
install_docker() {
    local CODENAME PACKAGE STATUS
    [[ "$SKIP_DOCKER_INSTALL" == 0 ]] || fail 'Docker 尚未安装；当前参数禁止自动安装。'
    [[ -d /run/systemd/system ]] || fail '自动安装 Docker 需要运行中的 systemd。'
    case "$OS_VERSION" in
        22.04|24.04|26.04) ;;
        *) fail "Ubuntu $OS_VERSION 不在 Docker 官方仓库自动安装范围；请先自行安装 Docker Engine 与 Compose 插件。" ;;
    esac
    for PACKAGE in docker.io docker-compose docker-compose-v2 podman-docker containerd runc; do
        STATUS="$(dpkg-query -W -f='${Status}' "$PACKAGE" 2>/dev/null || true)"
        [[ "$STATUS" != 'install ok installed' ]] || fail "存在冲突包 $PACKAGE，请先规划 Docker 安装；脚本不自动卸载。"
    done
    CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
    [[ "$CODENAME" =~ ^[a-z]+$ ]] || fail '无法检测发行版代号。'
    if [[ -e /etc/apt/sources.list.d/docker.sources || -e /etc/apt/sources.list.d/docker.list ]]; then
        log '复用现有 Docker APT 仓库文件。'
    else
        run_command install -m 0755 -d /etc/apt/keyrings
        [[ ! -e /etc/apt/keyrings/docker.asc ]] || fail '已有 Docker key 文件但无标准仓库文件，请检查后重试。'
        download 'https://download.docker.com/linux/ubuntu/gpg' "$WORK_DIR/docker.asc"
        run_command install -m 0644 "$WORK_DIR/docker.asc" /etc/apt/keyrings/docker.asc
        cat >"$WORK_DIR/docker.sources" <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $CODENAME
Components: stable
Architectures: amd64
Signed-By: /etc/apt/keyrings/docker.asc
EOF
        run_command install -m 0644 "$WORK_DIR/docker.sources" /etc/apt/sources.list.d/docker.sources
    fi
    apt_get_update
    run_command env DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

# 复用已有 Docker；只在需要时启动守护进程，在 systemd 主机上启用自启。
ensure_docker() {
    local VERSION MAJOR DAEMON_ARCH
    command -v docker >/dev/null 2>&1 || install_docker
    if ! docker info >/dev/null 2>&1; then
        [[ -d /run/systemd/system ]] || fail '无法连接 Docker daemon；检查 Docker 是否启动以及当前 context。'
        run_command systemctl start docker
        docker info >/dev/null 2>&1 || fail 'Docker daemon 启动后仍无法连接。'
    fi
    if [[ -d /run/systemd/system ]]; then run_command systemctl enable docker; fi
    if ! docker compose version >/dev/null 2>&1; then
        [[ "$OFFLINE" == 0 && "$SKIP_DOCKER_INSTALL" == 0 ]] || fail '需要 Docker Compose 插件，请先安装 docker-compose-plugin。'
        apt_get_update
        run_command env DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-plugin
    fi
    VERSION="$(docker compose version --short)"; VERSION="${VERSION#v}"; MAJOR="${VERSION%%.*}"
    [[ "$MAJOR" =~ ^[0-9]+$ ]] || fail "无法识别 Compose 版本：$VERSION"
    (( MAJOR >= 2 )) || fail "需要 Compose v2 或更新版本：$VERSION"
    DAEMON_ARCH="$(docker info --format '{{.Architecture}}')"
    [[ "$DAEMON_ARCH" == x86_64 || "$DAEMON_ARCH" == amd64 ]] || fail "Docker daemon 架构不匹配：$DAEMON_ARCH"
    [[ "$(docker info --format '{{.OSType}}')" == linux ]] || fail '需要 Linux containers 模式。'
    log "Docker：$(docker version --format '{{.Server.Version}}')；Compose：$VERSION"
}

# 计算整盘分区设备名（兼容 /dev/vdb 与 /dev/nvme0n1）。
data_part_dev() {
    local DISK="$1" NAME
    NAME="$(basename -- "$DISK")"
    case "$NAME" in
        *[0-9]) printf '%s' "${DISK}p1" ;;
        *) printf '%s' "${DISK}1" ;;
    esac
}

# 破坏性操作前的硬性检查：必须是空整盘、非系统盘、未挂载、未做 swap、容量足够。
data_disk_preflight() {
    local DISK="$1" NAME TYPE SIZE ANCESTORS MOUNTED CHILDREN SIGNATURE
    [[ "$DISK" =~ ^/dev/[A-Za-z0-9._/-]+$ ]] || fail "--data-disk 必须是 /dev/ 下的设备路径：$DISK"
    [[ -b "$DISK" ]] || fail "不是块设备：$DISK"
    NAME="$(basename -- "$DISK")"
    [[ ! -e "/sys/class/block/$NAME/partition" ]] || fail "请指定整块磁盘而不是分区：$DISK（例如 /dev/vdb，而不是 /dev/vdb1）。"
    TYPE="$(lsblk -dno TYPE "$DISK" 2>/dev/null || true)"
    [[ "$TYPE" == disk ]] || fail "不是整块磁盘（类型：${TYPE:-未知}）：$DISK"
    ANCESTORS="$(lsblk -snro NAME,TYPE "$(findmnt -no SOURCE /)" | awk '$2 == "disk" {print $1}')" || fail '无法识别系统盘，拒绝格式化。'
    [[ -n "$ANCESTORS" ]] || fail '无法识别系统盘，拒绝格式化。'
    if printf '%s\n' "$ANCESTORS" | grep -qx -- "$NAME"; then
        fail "拒绝操作系统盘：$DISK 承载根文件系统（/）。"
    fi
    MOUNTED="$(lsblk -nlo MOUNTPOINT "$DISK" | tr -d '[:space:]')" || fail '无法检查磁盘挂载状态，拒绝格式化。'
    [[ -z "$MOUNTED" ]] || fail "磁盘或其分区已挂载：$(printf '%s' "$MOUNTED" | tr '\n' ' ')；请先卸载。"
    if awk 'NR > 1 {print $1}' /proc/swaps 2>/dev/null | grep -q "^$DISK"; then
        fail "磁盘正被用作 swap：$DISK"
    fi
    CHILDREN="$(lsblk -nlo NAME,TYPE "$DISK" 2>/dev/null | tail -n +2 | grep -v '^$' || true)"
    SIGNATURE="$(blkid -p -o value -s TYPE "$DISK" 2>/dev/null || true)"
    if [[ -n "$CHILDREN" || -n "$SIGNATURE" ]]; then
        if [[ "$FORCE_FORMAT" != 1 ]]; then
            fail "磁盘上已有分区或文件系统（${SIGNATURE:-无文件系统}）；确认数据可清空后加 --force-format 再执行。"
        fi
        log "警告：将清空已有分区/文件系统的磁盘 $DISK"
    fi
    SIZE="$(blockdev --getsize64 "$DISK")"
    (( SIZE >= 10 * 1024 * 1024 * 1024 )) || fail "磁盘容量不足 10 GiB（$((SIZE / 1024 / 1024)) MiB），不建议作为 Docker 数据盘。"
    log "数据盘检查通过：$DISK（$((SIZE / 1024 / 1024 / 1024)) GiB，无挂载、未使用）"
}

# 路径必须先解析符号链接与 ..，再判断系统目录和包含关系。
paths_overlap() {
    [[ "$1" == "$2" || "$1" == "$2/"* || "$2" == "$1/"* || "$1" == / || "$2" == / ]]
}

normalize_data_mount() {
    [[ "$DATA_MOUNT" =~ ^/[A-Za-z0-9._/-]+$ ]] || fail '--data-mount 必须是无空白字符的绝对路径。'
    DATA_MOUNT="$(realpath -m -- "$DATA_MOUNT")" || fail '无法规范化挂载路径。'
    [[ "$DATA_MOUNT" =~ ^/[A-Za-z0-9._/-]+$ ]] || fail '规范化后的挂载路径包含不支持的字符。'
    case "$DATA_MOUNT" in
        /|/etc|/etc/*|/usr|/usr/*|/var|/var/*|/bin|/bin/*|/sbin|/sbin/*|/lib*|/boot|/boot/*|/dev|/dev/*|/proc|/proc/*|/sys|/sys/*|/run|/run/*|/tmp|/tmp/*|/root|/root/*|/home|/home/*)
            fail "不能使用系统目录作为数据盘挂载点：$DATA_MOUNT；建议 /data 或 /srv/docker-data。" ;;
    esac
    [[ ! -e "$DATA_MOUNT" || -d "$DATA_MOUNT" ]] || fail '挂载点不是目录。'
    DOCKER_ROOT="$DATA_MOUNT/docker"
}

# 仅迁移本机 systemd 管理的传统 Docker 存储；不猜测 containerd 的独立目录。
check_migration_backend() {
    local INFO="$1" ENDPOINT
    [[ -d /run/systemd/system ]] || fail '数据盘迁移需要本机运行中的 systemd。'
    [[ -z "${DOCKER_HOST:-}" && -z "${DOCKER_CONTEXT:-}" ]] || fail '数据盘迁移不接受 DOCKER_HOST/DOCKER_CONTEXT 环境覆盖，请使用本机默认 Docker context。'
    ENDPOINT="$(docker context inspect --format '{{.Endpoints.docker.Host}}' "$(docker context show)")"
    [[ "$ENDPOINT" == unix:///var/run/docker.sock || "$ENDPOINT" == unix:///run/docker.sock ]] || fail '数据盘迁移只支持本机 rootful Docker socket。'
    systemctl is-active --quiet docker || fail '本机 docker.service 未运行，拒绝操作磁盘。'
    jq -e '.LiveRestoreEnabled == false' <<<"$INFO" >/dev/null || fail '请先关闭 Docker live-restore 并重启 Docker，再执行数据盘迁移。'
    if jq -e 'any(.DriverStatus[]?; .[0] == "driver-type" and (.[1] | contains("snapshotter")))' <<<"$INFO" >/dev/null; then
        fail '检测到 containerd 镜像存储：本脚本不自动迁移其数据目录，请按 README 手工规划 Docker 与 containerd 存储。尚未停机或格式化。'
    fi
    jq -e '.Driver == "overlay2" or .Driver == "vfs"' <<<"$INFO" >/dev/null || fail '自动迁移仅支持 overlay2/vfs 存储驱动；当前后端需手工规划迁移。'
}

directory_empty() {
    local ENTRY
    [[ ! -e "$1" && ! -L "$1" ]] && return 0
    [[ -d "$1" && ! -L "$1" ]] || return 1
    ENTRY="$(find "$1" -mindepth 1 -maxdepth 1 -print -quit)" || return 1
    [[ -z "$ENTRY" ]]
}

# 先保存原始配置。回滚只恢复本次改动；不会删除原数据或新盘副本。
prepare_migration() {
    [[ ! -L "$DAEMON_CONFIG" && ( ! -e "$DAEMON_CONFIG" || -f "$DAEMON_CONFIG" ) ]] || fail 'daemon.json 必须是普通文件。'
    [[ -f "$FSTAB_FILE" && ! -L "$FSTAB_FILE" ]] || fail 'fstab 必须是普通文件。'
    if [[ -f "$DAEMON_CONFIG" ]]; then
        jq -e 'type == "object"' "$DAEMON_CONFIG" >/dev/null || fail 'daemon.json 必须是 JSON 对象。'
        run_command cp -p "$DAEMON_CONFIG" "${LOG_FILE%.log}.daemon.json.before"
        MIGRATION_HAD_CONFIG=1
    fi
    run_command cp -p "$FSTAB_FILE" "${LOG_FILE%.log}.fstab.before"
}

wait_docker_root() {
    local EXPECTED="$1" END_TIME=$((SECONDS + 90)) ACTUAL
    while (( SECONDS < END_TIME )); do
        ACTUAL="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
        if [[ -n "$ACTUAL" ]]; then
            [[ "$(realpath -m -- "$ACTUAL")" == "$EXPECTED" ]]
            return "$?"
        fi
        sleep 2
    done
    return 1
}

rollback_data_disk() {
    [[ "$MIGRATION_ACTIVE" == 1 ]] || return 0
    MIGRATION_ACTIVE=0
    log "迁移未完成，尝试恢复原 Docker 数据目录：$ORIGINAL_DOCKER_ROOT"
    # 不使用 run_command/fail，避免恢复失败再次进入错误处理。
    if ! systemctl stop docker.socket docker.service >>"$LOG_FILE" 2>&1; then
        log '恢复失败：无法停止 Docker。保留配置备份与全部数据，请人工恢复。'
        return 0
    fi
    if [[ "$MIGRATION_CONFIG_CHANGED" == 1 ]]; then
        if [[ "$MIGRATION_HAD_CONFIG" == 1 ]]; then
            if ! cp -p "${LOG_FILE%.log}.daemon.json.before" "$DAEMON_CONFIG"; then
                log '恢复失败：无法还原 daemon.json；Docker 保持停止，请使用日志目录中的备份恢复。'; return 0
            fi
        elif ! rm -f -- "$DAEMON_CONFIG"; then
            log '恢复失败：无法移除本次新建的 daemon.json；请人工恢复。'; return 0
        fi
    fi
    if [[ "$MIGRATION_FSTAB_CHANGED" == 1 ]]; then
        if ! cp -p "${LOG_FILE%.log}.fstab.before" "$FSTAB_FILE"; then
            log '警告：fstab 恢复失败，请从日志目录的备份手工恢复。'
        fi
        systemctl daemon-reload >>"$LOG_FILE" 2>&1 || log '警告：systemd daemon-reload 失败。'
    fi
    if [[ "$MIGRATION_MOUNTED" == 1 ]]; then
        umount "$DATA_MOUNT" >>"$LOG_FILE" 2>&1 || log "警告：无法卸载本次挂载的 $DATA_MOUNT，请人工检查。"
    fi
    if systemctl start docker >>"$LOG_FILE" 2>&1 && wait_docker_root "$ORIGINAL_DOCKER_ROOT"; then
        log "原 Docker 已恢复：$ORIGINAL_DOCKER_ROOT。新盘分区/副本保留；格式化前的磁盘内容无法回滚。"
    else
        log "恢复失败：原 Docker 未就绪，请检查 journalctl -u docker；配置备份：${LOG_FILE%.log}.*.before。"
    fi
    return 0
}

configure_docker_root() {
    local ROOT="$1" TMP="$WORK_DIR/daemon.json.new"
    if [[ "$MIGRATION_HAD_CONFIG" == 1 ]]; then
        jq --arg p "$ROOT" '. + {"data-root": $p}' "${LOG_FILE%.log}.daemon.json.before" >"$TMP"
    else
        jq -n --arg p "$ROOT" '{"data-root": $p}' >"$TMP"
    fi
    run_command mkdir -p "$(dirname -- "$DAEMON_CONFIG")"
    MIGRATION_CONFIG_CHANGED=1
    run_command install -m 0644 "$TMP" "$DAEMON_CONFIG"
}

# UUID 与挂载点必须共同匹配；不能因注释或其他挂载点含同一 UUID 就跳过。
data_fstab_entry() {
    local PART="$1" MOUNT="$2" UUID ENTRY
    UUID="$(blkid -o value -s UUID "$PART")"
    [[ "$UUID" =~ ^[A-Fa-f0-9-]+$ ]] || fail "分区 UUID 无效：$PART"
    [[ "$(blkid -o value -s TYPE "$PART")" == ext4 ]] || fail '数据分区必须是 ext4。'
    ENTRY="$(awk -v u="UUID=$UUID" -v m="$MOUNT" '$0 !~ /^[[:space:]]*#/ && NF >= 2 && ($1==u || $2==m) {print $1, $2, $3}' "$FSTAB_FILE")"
    [[ -z "$ENTRY" || "$ENTRY" == "UUID=$UUID $MOUNT ext4" ]] || fail 'fstab 中已有冲突或重复的 UUID/挂载点，请先核实。'
    DATA_PART_UUID="$UUID"
    DATA_FSTAB_ENTRY="$ENTRY"
}

mount_data_part() {
    local PART="$1" MOUNT="$2" UUID ENTRY
    data_fstab_entry "$PART" "$MOUNT"
    ENTRY="$DATA_FSTAB_ENTRY"
    UUID="$DATA_PART_UUID"
    if ! findmnt -rn -M "$MOUNT" >/dev/null; then
        run_command mkdir -p "$MOUNT"
        MIGRATION_MOUNTED=1
        run_command mount "$PART" "$MOUNT"
    fi
    if [[ -z "$ENTRY" ]]; then
        MIGRATION_FSTAB_CHANGED=1
        printf 'UUID=%s %s ext4 defaults,noatime 0 2\n' "$UUID" "$MOUNT" >>"$FSTAB_FILE"
        run_command systemctl daemon-reload
    fi
}

check_migration_space() {
    local SOURCE="$1" TARGET="$2" NEED_KB AVAIL_KB
    NEED_KB="$(du -sk -- "$SOURCE" | awk '{print $1}')"
    AVAIL_KB="$(df -Pk -- "$TARGET" | awk 'NR == 2 {print $4}')"
    [[ "$NEED_KB" =~ ^[0-9]+$ && "$AVAIL_KB" =~ ^[0-9]+$ ]] || fail '无法读取迁移所需空间。'
    (( AVAIL_KB >= NEED_KB + 5 * 1024 * 1024 )) || fail "数据盘空间不足：源目录 $SOURCE 约 $((NEED_KB / 1024)) MiB；需额外预留 5 GiB。"
}

# 安全检查在停机/格式化前完成；停机后的任意失败统一由 fail/EXIT 恢复。
setup_data_disk() {
    local DISK PART CURRENT_SRC INFO END_TIME SIZE NEED_KB AVAIL_KB REUSE=0
    if [[ -z "$DATA_DISK" ]]; then
        log '未指定 --data-disk，保留 Docker 当前数据目录。'
        return 0
    fi
    normalize_data_mount
    DISK="$(realpath -e -- "$DATA_DISK")" || fail '数据盘路径不存在。'
    [[ "$DISK" == /dev/* && -b "$DISK" ]] || fail "不是 /dev/ 下的块设备：$DISK"
    [[ "$(lsblk -dno TYPE "$DISK")" == disk ]] || fail '必须指定整块磁盘。'
    DATA_DISK="$DISK"
    PART="$(data_part_dev "$DISK")"
    INFO="$(docker info --format '{{json .}}')"
    check_migration_backend "$INFO"
    ORIGINAL_DOCKER_ROOT="$(jq -er '.DockerRootDir | select(type == "string" and startswith("/"))' <<<"$INFO")"
    ORIGINAL_DOCKER_ROOT="$(realpath -e -- "$ORIGINAL_DOCKER_ROOT")"
    [[ -d "$ORIGINAL_DOCKER_ROOT" && "$ORIGINAL_DOCKER_ROOT" != / ]] || fail '原 Docker 数据目录无效。'
    paths_overlap "$DATA_MOUNT" "$SCRIPT_DIR" && fail '挂载点不能与部署目录互相包含。'
    CURRENT_SRC="$(findmnt -rn -o SOURCE -M "$DATA_MOUNT" || true)"
    if [[ -n "$CURRENT_SRC" ]]; then
        [[ "$(realpath -e -- "$CURRENT_SRC")" == "$PART" ]] || fail '挂载点已被其他设备使用。'
        [[ "$(blkid -o value -s LABEL "$PART")" == zabbix-docker && "$(blkid -o value -s TYPE "$PART")" == ext4 ]] || fail '已挂载分区不属于可识别的 zabbix-docker ext4 数据盘。'
        if [[ "$ORIGINAL_DOCKER_ROOT" == "$DOCKER_ROOT" ]]; then
            log "数据盘与 Docker data-root 已就绪：$DOCKER_ROOT，跳过迁移。"
            return 0
        fi
    else
        directory_empty "$DATA_MOUNT" || fail '新挂载点必须为空目录，拒绝遮蔽已有文件。'
    fi
    paths_overlap "$DATA_MOUNT" "$ORIGINAL_DOCKER_ROOT" && fail '挂载点与原 Docker 数据目录互相包含，拒绝迁移。'
    [[ "$(realpath -m -- "$DOCKER_ROOT")" == "$DOCKER_ROOT" ]] || fail '目标 Docker 目录不能通过符号链接指向其他位置。'
    directory_empty "$DOCKER_ROOT" || fail '目标 Docker 目录非空；保留其内容，请先手工核实，禁止合并旧数据。'
    if [[ -n "$CURRENT_SRC" ]]; then
        REUSE=1
        check_migration_space "$ORIGINAL_DOCKER_ROOT" "$DATA_MOUNT"
    elif [[ -b "$PART" && "$(blkid -o value -s LABEL "$PART" 2>/dev/null || true)" == zabbix-docker ]]; then
        [[ -z "$(lsblk -nr -o MOUNTPOINT "$DISK" | tr -d '[:space:]')" ]] || fail '已有数据分区已在其他位置挂载。'
        REUSE=1
    else
        data_disk_preflight "$DISK"
        SIZE="$(blockdev --getsize64 "$DISK")"
        NEED_KB="$(du -sk -- "$ORIGINAL_DOCKER_ROOT" | awk '{print $1}')"
        # 格式化前先做保守容量检查，挂载后再检查实际剩余空间。
        (( SIZE * 95 / 102400 >= NEED_KB + 5 * 1024 * 1024 )) || fail '数据盘容量不足以容纳现有数据及 5 GiB 余量。'
    fi
    prepare_migration
    if [[ "$REUSE" == 1 ]]; then
        data_fstab_entry "$PART" "$DATA_MOUNT" >/dev/null
    elif awk -v m="$DATA_MOUNT" '$0 !~ /^[[:space:]]*#/ && $2==m {found=1} END {exit !found}' "$FSTAB_FILE"; then
        fail '新数据盘挂载点已有 fstab 条目，请先核实；尚未停机或格式化。'
    fi
    MIGRATION_ACTIVE=1
    run_command systemctl stop docker.socket docker.service
    # live-restore 已拒绝；若服务仍活跃，不允许复制正在写入的数据库文件。
    if systemctl is-active --quiet docker.service; then fail 'Docker 未停止，拒绝迁移。'; fi
    if [[ "$REUSE" == 0 ]]; then
        run_command wipefs -a --force "$DISK"
        printf 'label: gpt\n,,L\n' >"$WORK_DIR/sfdisk.script"
        run_command sfdisk --wipe always --wipe-partitions always "$DISK" <"$WORK_DIR/sfdisk.script"
        blockdev --rereadpt "$DISK" >/dev/null 2>&1 || true
        END_TIME=$((SECONDS + 15))
        while [[ ! -b "$PART" ]]; do
            (( SECONDS < END_TIME )) || fail "分区设备未就绪：$PART"
            sleep 1
        done
        run_command mkfs.ext4 -F -L zabbix-docker -m 1 "$PART"
    fi
    mount_data_part "$PART" "$DATA_MOUNT"
    # 已有分区的内容在挂载后才能判断，非空时回滚挂载并恢复原 Docker。
    directory_empty "$DOCKER_ROOT" || fail '分区上的 Docker 目录非空，拒绝覆盖或合并；请手工核实原数据。'
    check_migration_space "$ORIGINAL_DOCKER_ROOT" "$DATA_MOUNT"
    run_command mkdir -p "$DOCKER_ROOT"
    log "迁移 Docker 数据：$ORIGINAL_DOCKER_ROOT → $DOCKER_ROOT"
    run_command rsync -aHAX --numeric-ids --info=stats2 "$ORIGINAL_DOCKER_ROOT/" "$DOCKER_ROOT/"
    configure_docker_root "$DOCKER_ROOT"
    run_command systemctl start docker
    wait_docker_root "$DOCKER_ROOT" || fail 'Docker 启动超时或 data-root 未生效。'
    AVAIL_KB="$(df -Pk -- "$DOCKER_ROOT" | awk 'NR == 2 {print $4}')"
    (( AVAIL_KB >= 5 * 1024 * 1024 )) || fail '迁移后数据盘可用空间不足 5 GiB。'
    MIGRATION_ACTIVE=0
    log "Docker 数据迁移完成：$DOCKER_ROOT；原目录 $ORIGINAL_DOCKER_ROOT 保留。"
}

# 验证镜像包、镜像清单和初始化 SQL 的传输完整性。
check_bundle() {
    local FILE
    for FILE in docker-compose.yaml images.lock SHA256SUMS zabbix-platform-images.tar initdb/create.sql.gz; do
        [[ -f "$SCRIPT_DIR/$FILE" ]] || fail "部署文件缺失：$FILE"
    done
    log '验证离线镜像及数据库初始化文件 SHA256...'
    (cd "$SCRIPT_DIR" && sha256sum --check --status SHA256SUMS) || fail 'SHA256 校验失败，请重新完整上传部署包。'
    run_command gzip -t "$SCRIPT_DIR/initdb/create.sql.gz"
}

# 读取已存在 .env 中不含秘密的标识字段；不 source 文件，不执行其内容。
env_setting() {
    local KEY="$1" FALLBACK="$2" VALUE
    VALUE="$(awk -v KEY="$KEY" 'index($0,KEY "=")==1 {N++; V=substr($0,length(KEY)+2)} END {if(N>1) exit 2; print V}' "$ENV_FILE")" || fail ".env 重复定义字段：$KEY"
    if [[ "$VALUE" == \"*\" || "$VALUE" == \'*\' ]]; then VALUE="${VALUE:1:${#VALUE}-2}"; fi
    printf '%s' "${VALUE:-$FALLBACK}"
}

# 校验项目名、卷名、容器名与端口，防止名称和参数注入。
validate_settings() {
    local NAME PORT
    [[ "$PROJECT_NAME" =~ ^[a-z0-9][a-z0-9_-]{0,62}$ ]] || fail 'COMPOSE_PROJECT_NAME 格式错误。'
    for NAME in "$MYSQL_CONTAINER_NAME" "$SERVER_CONTAINER_NAME" "$WEB_CONTAINER_NAME" "$MYSQL_VOLUME_NAME"; do
        [[ "$NAME" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$ ]] || fail "容器/卷名称格式错误：$NAME"
    done
    [[ "$MYSQL_CONTAINER_NAME" != "$SERVER_CONTAINER_NAME" && "$MYSQL_CONTAINER_NAME" != "$WEB_CONTAINER_NAME" && "$SERVER_CONTAINER_NAME" != "$WEB_CONTAINER_NAME" ]] || fail '三个容器名称不能相同。'
    for PORT in "$WEB_PORT" "$SERVER_PORT"; do
        [[ "$PORT" =~ ^[1-9][0-9]{0,4}$ ]] || fail "端口格式错误：$PORT"
        (( PORT <= 65535 )) || fail "端口超出范围：$PORT"
    done
    [[ "$WEB_PORT" != "$SERVER_PORT" ]] || fail 'Web 端口不能与 Server 端口相同。'
}

# 将密码写入 Compose dotenv 单引号值，拒绝无法安全自动转换的少见字符。
write_secret() {
    local KEY="$1" VALUE="$2"
    [[ -n "$VALUE" && "$VALUE" != *$'\n'* && "$VALUE" != *$'\r'* && "$VALUE" != *\\* ]] || fail '数据库密码含换行/反斜杠或为空，请按 README 手工准备 .env 后重试。'
    VALUE="${VALUE//\'/\\\'}"
    printf "%s='%s'\n" "$KEY" "$VALUE"
}

# 读取已有 MySQL 容器的凭据，只在内存中处理，不打印到日志。
adopt_credentials() {
    local ENV_JSON
    ENV_JSON="$(docker inspect "$MYSQL_CONTAINER_NAME")"
    MYSQL_PASSWORD="$(jq -r '.[0].Config.Env[] | select(startswith("MYSQL_PASSWORD=")) | ltrimstr("MYSQL_PASSWORD=")' <<<"$ENV_JSON")"
    MYSQL_ROOT_PASSWORD="$(jq -r '.[0].Config.Env[] | select(startswith("MYSQL_ROOT_PASSWORD=")) | ltrimstr("MYSQL_ROOT_PASSWORD=")' <<<"$ENV_JSON")"
    [[ -n "$MYSQL_PASSWORD" && -n "$MYSQL_ROOT_PASSWORD" ]] || fail '无法从原 MySQL 容器获取密码，请准备与现有数据库一致的 .env。'
}

# 新部署使用固定密码 zabbix123；已有部署沿用项目、卷和凭据，重复执行不改 .env。
prepare_env() {
    local NAME FOUND_PROJECT='' EXISTING_PROJECT VOLUME_COUNT
    if [[ -e "$ENV_FILE" || -L "$ENV_FILE" ]]; then
        [[ -f "$ENV_FILE" && ! -L "$ENV_FILE" ]] || fail '.env 必须是普通文件。'
        run_command chmod 600 "$ENV_FILE"
        PROJECT_NAME="$(env_setting COMPOSE_PROJECT_NAME "$PROJECT_NAME")"
        MYSQL_CONTAINER_NAME="$(env_setting MYSQL_CONTAINER_NAME "$MYSQL_CONTAINER_NAME")"
        SERVER_CONTAINER_NAME="$(env_setting SERVER_CONTAINER_NAME "$SERVER_CONTAINER_NAME")"
        WEB_CONTAINER_NAME="$(env_setting WEB_CONTAINER_NAME "$WEB_CONTAINER_NAME")"
        MYSQL_VOLUME_NAME="$(env_setting MYSQL_VOLUME_NAME "$MYSQL_VOLUME_NAME")"
        WEB_PORT="$(env_setting WEB_PORT "$WEB_PORT")"
        SERVER_PORT="$(env_setting SERVER_PORT "$SERVER_PORT")"
        log '保留已有 .env 配置与数据库密码。'
    else
        validate_settings
        for NAME in "$MYSQL_CONTAINER_NAME" "$SERVER_CONTAINER_NAME" "$WEB_CONTAINER_NAME"; do
            if docker container inspect "$NAME" >/dev/null 2>&1; then
                EXISTING_PROJECT="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "$NAME")"
                [[ -n "$EXISTING_PROJECT" && "$EXISTING_PROJECT" != '<no value>' ]] || fail "已有同名容器 $NAME 不属于 Compose 项目，停止以免接管错误容器。"
                [[ -z "$FOUND_PROJECT" || "$FOUND_PROJECT" == "$EXISTING_PROJECT" ]] || fail '三个同名容器属于不同项目，停止部署。'
                FOUND_PROJECT="$EXISTING_PROJECT"
            fi
        done
        if [[ -n "$FOUND_PROJECT" ]]; then
            docker container inspect "$MYSQL_CONTAINER_NAME" >/dev/null 2>&1 || fail '检测到已有平台容器但 MySQL 容器缺失，请先核实数据卷。'
            PROJECT_NAME="$FOUND_PROJECT"
            VOLUME_COUNT="$(docker inspect "$MYSQL_CONTAINER_NAME" | jq '[.[0].Mounts[] | select(.Destination=="/var/lib/mysql" and .Type=="volume")] | length')"
            [[ "$VOLUME_COUNT" == 1 ]] || fail '原 MySQL 不是唯一命名卷挂载，脚本不自动迁移数据库。'
            MYSQL_VOLUME_NAME="$(docker inspect "$MYSQL_CONTAINER_NAME" | jq -r '.[0].Mounts[] | select(.Destination=="/var/lib/mysql") | .Name')"
            adopt_credentials
            FRESH_DATABASE=0
        else
            if docker volume inspect "$MYSQL_VOLUME_NAME" >/dev/null 2>&1; then
                fail "卷 $MYSQL_VOLUME_NAME 已存在，但无法推断其数据库密码；请先准备正确的 .env。"
            fi
            MYSQL_PASSWORD='zabbix123'
            MYSQL_ROOT_PASSWORD='zabbix123'
        fi
        validate_settings
        {
            printf 'COMPOSE_PROJECT_NAME=%s\nMYSQL_CONTAINER_NAME=%s\nSERVER_CONTAINER_NAME=%s\nWEB_CONTAINER_NAME=%s\nMYSQL_VOLUME_NAME=%s\nWEB_PORT=%s\nSERVER_PORT=%s\n' \
                "$PROJECT_NAME" "$MYSQL_CONTAINER_NAME" "$SERVER_CONTAINER_NAME" "$WEB_CONTAINER_NAME" "$MYSQL_VOLUME_NAME" "$WEB_PORT" "$SERVER_PORT"
            write_secret MYSQL_PASSWORD "$MYSQL_PASSWORD"
            write_secret MYSQL_ROOT_PASSWORD "$MYSQL_ROOT_PASSWORD"
        } >"$WORK_DIR/new.env"
        run_command install -m 0600 "$WORK_DIR/new.env" "$ENV_FILE"
        log '已生成 .env（新数据库固定密码 zabbix123；已有数据库沿用原密码）。'
    fi
    validate_settings
    run_command compose config --quiet
}

# 验证已有容器身份与数据库卷；在创建/替换任何容器前保护旧数据。
check_existing_stack() {
    local NAME SERVICE LABEL PROJECT VOLUME JSON EXPECTED_PASSWORD EXISTING_PASSWORD KEY
    local -a NAMES=("$MYSQL_CONTAINER_NAME" "$SERVER_CONTAINER_NAME" "$WEB_CONTAINER_NAME") SERVICES=(mysql zabbix-server zabbix-web)
    local INDEX
    for INDEX in 0 1 2; do
        NAME="${NAMES[$INDEX]}"; SERVICE="${SERVICES[$INDEX]}"
        if docker container inspect "$NAME" >/dev/null 2>&1; then
            PROJECT="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "$NAME")"
            LABEL="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "$NAME")"
            [[ "$PROJECT" == "$PROJECT_NAME" && "$LABEL" == "$SERVICE" ]] || fail "同名容器 $NAME 不属于预期项目/服务，停止部署。"
        fi
    done
    if docker container inspect "$MYSQL_CONTAINER_NAME" >/dev/null 2>&1; then
        VOLUME="$(docker inspect "$MYSQL_CONTAINER_NAME" | jq -r '.[0].Mounts[] | select(.Destination=="/var/lib/mysql" and .Type=="volume") | .Name')"
        [[ "$VOLUME" == "$MYSQL_VOLUME_NAME" ]] || fail "原数据库卷为 $VOLUME，与配置卷不同，停止以免连接空数据库。"
        JSON="$(compose config --format json)"
        for KEY in MYSQL_PASSWORD MYSQL_ROOT_PASSWORD MYSQL_DATABASE MYSQL_USER; do
            # Compose config 为再次解析而把字面 $ 序列化成 $$，比较前还原。
            EXPECTED_PASSWORD="$(jq -r --arg KEY "$KEY" '.services.mysql.environment[$KEY] | gsub("\\$\\$"; "$")' <<<"$JSON")"
            EXISTING_PASSWORD="$(docker inspect "$MYSQL_CONTAINER_NAME" | jq -r --arg PREFIX "$KEY=" '.[0].Config.Env[] | select(startswith($PREFIX)) | ltrimstr($PREFIX)')"
            [[ "$EXPECTED_PASSWORD" == "$EXISTING_PASSWORD" ]] || fail ".env/Compose 的 $KEY 与原容器不一致；脚本不自动修改数据库身份或密码。"
        done
        FRESH_DATABASE=0
    elif docker volume inspect "$MYSQL_VOLUME_NAME" >/dev/null 2>&1; then
        fail "数据库卷 $MYSQL_VOLUME_NAME 已存在但 MySQL 容器缺失；需要先手工核实恢复方式。"
    fi
    STACK_IDENTIFIED=1
    run_command cp -a "$ENV_FILE" "${LOG_FILE%.log}.env.before"
    run_command cp -a "$COMPOSE_FILE" "${LOG_FILE%.log}.compose.before.yaml"
    log "项目：$PROJECT_NAME；数据库卷：$MYSQL_VOLUME_NAME"
}

# 检查 Docker 发布端口及宿主机监听，允许本项目原容器继续占用其端口。
check_port() {
    local PORT="$1" OWNER="$2" IDS OWNERS BINDINGS LISTENERS
    IDS="$(docker ps -q)"
    OWNERS=''
    if [[ -n "$IDS" ]]; then
        # IDS 是 Docker 返回的十六进制 ID 列表，用于逐个 inspect。
        # shellcheck disable=SC2086
        OWNERS="$(docker inspect $IDS | jq -r --arg PORT "$PORT" '.[] | select(any((.NetworkSettings.Ports // {})[]?[]?; .HostPort==$PORT)) | .Name | ltrimstr("/")')"
    fi
    if [[ -n "$OWNERS" && "$OWNERS" != "$OWNER" ]]; then fail "宿主机端口 $PORT 已被其他容器占用：$OWNERS"; fi
    LISTENERS="$(ss -H -ltn "sport = :$PORT")"
    if [[ -n "$LISTENERS" ]]; then
        BINDINGS="$(docker inspect "$OWNER" 2>/dev/null | jq -r --arg PORT "$PORT" '.[0].NetworkSettings.Ports // {} | [.[]?[]? | select(.HostPort==$PORT)] | length' || true)"
        [[ "$BINDINGS" =~ ^[1-9][0-9]*$ ]] || fail "宿主机 TCP $PORT 已被其他进程监听。"
    fi
    log "端口 $PORT 检查通过。"
}

# 校验 Web 镜像确实是风铃品牌改版，避免误用原始 Zabbix 镜像。
verify_branding() {
    log '校验 Web 镜像为风铃品牌版...'
    run_command docker run --rm --entrypoint sh "$WEB_IMAGE" -c 'grep -q fengling-brand /usr/share/zabbix/include/page_header.php'
    run_command docker run --rm --entrypoint sh "$WEB_IMAGE" -c 'test -f /usr/share/zabbix/assets/styles/fengling-brand.css'
    log '品牌镜像校验通过。'
}

# 判断当前镜像 ID 是否命中 images.lock 中该行记录的一个或多个 ID。
# containerd 镜像存储与 classic 存储对同一离线包可能给出不同的镜像 ID，
# 因此允许每行记录多个等价 ID，避免在目标主机上误判。
image_id_matches() {
    local CURRENT_ID="$1" ID
    shift
    for ID in "$@"; do
        [[ "$ID" == "$CURRENT_ID" ]] && return 0
    done
    return 1
}

# 按 images.lock 校验/导入离线镜像；不拉取新版本或覆盖冲突的同名镜像。
load_images() {
    local IMAGE IDS ID CURRENT_ID NEED_LOAD=0 IMAGE_OS IMAGE_ARCH
    local -a LOCKED_IDS
    while read -r IMAGE IDS; do
        [[ -n "$IMAGE" && -n "$IDS" ]] || fail 'images.lock 格式错误。'
        read -r -a LOCKED_IDS <<<"$IDS"
        for ID in "${LOCKED_IDS[@]}"; do
            [[ "$ID" =~ ^sha256:[a-f0-9]{64}$ ]] || fail "images.lock 中镜像 ID 格式错误：$IMAGE"
        done
        CURRENT_ID="$(docker image inspect --format '{{.Id}}' "$IMAGE" 2>/dev/null || true)"
        if [[ -z "$CURRENT_ID" ]]; then
            NEED_LOAD=1
        else
            image_id_matches "$CURRENT_ID" "${LOCKED_IDS[@]}" || fail "已有镜像 $IMAGE 与离线包 ID 不同；停止以免覆盖其他部署使用的镜像。"
        fi
    done <"$SCRIPT_DIR/images.lock"
    if [[ "$NEED_LOAD" == 1 ]]; then
        run_command docker load -i "$SCRIPT_DIR/zabbix-platform-images.tar"
    else
        log '原始离线镜像均已存在，跳过重复导入。'
    fi
    while read -r IMAGE IDS; do
        read -r -a LOCKED_IDS <<<"$IDS"
        CURRENT_ID="$(docker image inspect --format '{{.Id}}' "$IMAGE")"
        IMAGE_ARCH="$(docker image inspect --format '{{.Architecture}}' "$IMAGE")"
        IMAGE_OS="$(docker image inspect --format '{{.Os}}' "$IMAGE")"
        image_id_matches "$CURRENT_ID" "${LOCKED_IDS[@]}" || fail "导入后镜像不匹配：$IMAGE"
        [[ "$IMAGE_ARCH" == amd64 && "$IMAGE_OS" == linux ]] || fail "导入后镜像平台不匹配：$IMAGE"
        log "镜像确认：$IMAGE $CURRENT_ID"
    done <"$SCRIPT_DIR/images.lock"
    verify_branding
}

# 备份已有数据库，使用容器自己的 root 密码，密码不出现在命令参数或日志中。
backup_database() {
    local END_TIME RUNNING
    [[ "$FRESH_DATABASE" == 0 ]] || { log '新数据库无需部署前备份。'; return 0; }
    RUNNING="$(docker inspect --format '{{.State.Running}}' "$MYSQL_CONTAINER_NAME")"
    if [[ "$RUNNING" != true ]]; then run_command docker start "$MYSQL_CONTAINER_NAME"; fi
    END_TIME=$((SECONDS + 120))
    until docker exec "$MYSQL_CONTAINER_NAME" sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql --protocol=tcp -h 127.0.0.1 -u root "$MYSQL_DATABASE" -Nse "SELECT mandatory FROM dbversion"' >"$WORK_DIR/db-version" 2>"$WORK_DIR/db-probe-error"; do
        if (( SECONDS >= END_TIME )); then
            cat "$WORK_DIR/db-probe-error" >>"$LOG_FILE"
            fail '原数据库无法正常查询，停止部署；先修复原 MySQL 或核实密码。'
        fi
        sleep 3
    done
    DB_BACKUP="$SCRIPT_DIR/backups/zabbix-$(date '+%Y%m%d-%H%M%S')-$(basename "$WORK_DIR").sql.gz"
    log '备份原数据库（single-transaction），可能需要一些时间...'
    if docker exec "$MYSQL_CONTAINER_NAME" sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysqldump --protocol=tcp -h 127.0.0.1 -u root --single-transaction --routines --events --triggers --no-tablespaces --set-gtid-purged=OFF "$MYSQL_DATABASE"' \
        2>>"$LOG_FILE" | gzip >"$DB_BACKUP.partial"; then
        run_command gzip -t "$DB_BACKUP.partial"
        run_command mv "$DB_BACKUP.partial" "$DB_BACKUP"
        log "数据库备份完成：$DB_BACKUP"
    else
        fail "数据库备份失败，停止部署；未完成的备份为 $DB_BACKUP.partial。"
    fi
}

# 等待容器健康状态，并识别退出或持续重启；定期输出进度。
wait_healthy() {
    local NAME="$1" END_TIME STATE HEALTH LAST_PROGRESS=0
    END_TIME=$((SECONDS + WAIT_TIMEOUT))
    while (( SECONDS < END_TIME )); do
        STATE="$(docker inspect --format '{{.State.Status}}' "$NAME")"
        HEALTH="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' "$NAME")"
        [[ "$STATE" != exited && "$STATE" != dead ]] || fail "容器 $NAME 已退出，请查看容器日志。"
        [[ "$HEALTH" != missing ]] || fail "容器 $NAME 缺少健康检查。"
        if [[ "$STATE" == running && "$HEALTH" == healthy ]]; then log "$NAME：running / healthy"; return 0; fi
        if (( SECONDS - LAST_PROGRESS >= 15 )); then
            log "等待 $NAME：$STATE / $HEALTH（首次数据库初始化需要时间）"
            LAST_PROGRESS=$SECONDS
        fi
        sleep 3
    done
    fail "等待 $NAME 健康状态超时（${WAIT_TIMEOUT} 秒），当前 $STATE / $HEALTH。"
}

# 按 MySQL、Server、Web 顺序部署，数据库实际准备好后才创建依赖服务。
start_stack() {
    run_command compose up -d --pull never --no-build mysql
    wait_healthy "$MYSQL_CONTAINER_NAME"
    run_command compose up -d --pull never --no-build zabbix-server
    wait_healthy "$SERVER_CONTAINER_NAME"
    run_command compose up -d --pull never --no-build zabbix-web
    wait_healthy "$WEB_CONTAINER_NAME"
}

# 自动获取服务器 IPv4；默认路由接口优先，其他地址记录为候选。
detect_ip() {
    local IP_LIST ROUTE_IP ADDRESS
    local -a ADDRESSES
    IP_LIST="$(hostname -I 2>/dev/null || ip -4 -o addr show scope global | awk '{split($4,A,"/"); print A[1]}')"
    IP_LIST="${IP_LIST//$'\n'/ }"
    read -r -a ADDRESSES <<<"$IP_LIST"
    ROUTE_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(I=1;I<=NF;I++) if($I=="src") {print $(I+1);exit}}' || true)"
    for ADDRESS in "${ADDRESSES[@]}"; do
        if [[ "$ADDRESS" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && "$ADDRESS" != 127.* ]]; then
            [[ -n "$LOCAL_IP" ]] || LOCAL_IP="$ADDRESS"
            if [[ "$ADDRESS" == "$ROUTE_IP" ]]; then LOCAL_IP="$ADDRESS"; break; fi
        fi
    done
    [[ -n "$LOCAL_IP" ]] || fail '无法自动获取本机 IPv4。'
    log "本机地址候选：$IP_LIST；接入IP：$LOCAL_IP"
}

# 检查发布端口映射、HTTP /ping 及首页，避免仅凭容器 Up 判断部署成功。
verify_stack() {
    local NAME ENDPOINT PORT_JSON
    for NAME in "$MYSQL_CONTAINER_NAME" "$SERVER_CONTAINER_NAME" "$WEB_CONTAINER_NAME"; do wait_healthy "$NAME"; done
    PORT_JSON="$(docker inspect "$WEB_CONTAINER_NAME")"
    jq -e --arg PORT "$WEB_PORT" 'any(.[0].NetworkSettings.Ports["8080/tcp"][]; .HostPort==$PORT)' <<<"$PORT_JSON" >/dev/null || fail 'Web 宿主机端口映射不匹配。'
    PORT_JSON="$(docker inspect "$SERVER_CONTAINER_NAME")"
    jq -e --arg PORT "$SERVER_PORT" 'any(.[0].NetworkSettings.Ports["10051/tcp"][]; .HostPort==$PORT)' <<<"$PORT_JSON" >/dev/null || fail 'Server 宿主机端口映射不匹配。'
    for ENDPOINT in /ping /; do
        run_command curl --fail --silent --show-error --noproxy '*' --connect-timeout 3 --max-time 15 \
            --output /dev/null "http://$HTTP_TEST_HOST:$WEB_PORT$ENDPOINT"
    done
    # 用 Bash 原生 TCP 检查 Server 发布端口，避免额外安装 nc。
    # shellcheck disable=SC2016
    run_command timeout 5 bash -c 'exec 3<>/dev/tcp/$1/$2' bash "$HTTP_TEST_HOST" "$SERVER_PORT"
    log '容器健康、Web HTTP 和 Server TCP 发布端口检查通过。'
}

# 生成不含数据库密码的部署报告，旧报告归档；默认登录提示区分新旧数据库。
generate_report() {
    local REPORT_TMP LOGIN_NOTE
    REPORT_TMP="$WORK_DIR/report.txt"
    if [[ "$FRESH_DATABASE" == 1 ]]; then LOGIN_NOTE='新建数据库默认 Web 登录：Admin / zabbix'; else LOGIN_NOTE='复用已有数据库：Web 账号和密码保持原样。'; fi
    if [[ -f "$SCRIPT_DIR/zabbix-docker-report.txt" ]]; then
        run_command cp -a "$SCRIPT_DIR/zabbix-docker-report.txt" "${LOG_FILE%.log}.previous-report.txt"
    fi
    cat >"$REPORT_TMP" <<EOF
================================
Zabbix 风铃云监控管理系统 部署报告
================================
Time: $(date '+%F %T %z')
OS: $OS_NAME
Hostname: $(hostname)
Server IP: $LOCAL_IP
Compose Project: $PROJECT_NAME
Web URL: http://$LOCAL_IP:$WEB_PORT
Zabbix Server Endpoint: $LOCAL_IP:$SERVER_PORT
MySQL Container: $MYSQL_CONTAINER_NAME (healthy)
Zabbix Server Container: $SERVER_CONTAINER_NAME (healthy)
Zabbix Web Container: $WEB_CONTAINER_NAME (healthy)
Web Image: $WEB_IMAGE（风铃品牌版）
Docker Root Dir: $(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo unknown)
Data Disk: ${DATA_DISK:-未指定（保留 Docker 当前数据目录）}
Data Mount: $([[ -n "$DATA_DISK" ]] && printf '%s' "$DATA_MOUNT" || printf '未使用')
Database Volume: $MYSQL_VOLUME_NAME
Database Backup: ${DB_BACKUP:-not required for a new database}
Credentials File: $ENV_FILE (mode 600)
Log: $LOG_FILE
$LOGIN_NOTE
MySQL is not published to a host port.
Host firewall/NAT reachability should be checked from the browser/client network.
================================
EOF
    run_command install -m 0600 "$REPORT_TMP" "$SCRIPT_DIR/zabbix-docker-report.txt"
    log "报告：$SCRIPT_DIR/zabbix-docker-report.txt"
    printf '\n================================\n部署完成\n================================\nWeb地址: http://%s:%s\nZabbix Server: %s:%s\n数据库卷: %s\n%s\n数据库凭据：见部署目录 .env（已有数据库沿用原密码）\n================================\n' \
        "$LOCAL_IP" "$WEB_PORT" "$LOCAL_IP" "$SERVER_PORT" "$MYSQL_VOLUME_NAME" "$LOGIN_NOTE"
}

# 执行完整部署；不进行 down -v、卷删除、全局 prune 或 Zabbix API 操作。
main() {
    trap 'fail "第 $LINENO 行命令失败，退出码 $?。"' ERR
    trap cleanup EXIT
    trap 'fail "操作被中断，保留容器和数据。" 130' INT
    trap 'fail "收到终止信号，保留容器和数据。" 143' TERM
    parse_args "$@"
    initialize
    printf '\n================================\n 风铃云监控管理系统 自动部署工具\n================================\n'
    CURRENT_STEP='[1/8] 检查部署文件与系统工具'; log "$CURRENT_STEP..."
    check_bundle; ensure_tools; log '完成'
    CURRENT_STEP='[2/8] 检查/安装 Docker 与 Compose'; log "$CURRENT_STEP..."
    ensure_docker; log '完成'
    CURRENT_STEP='[3/8] 数据盘准备（自动分区/挂载/迁移）'; log "$CURRENT_STEP..."
    setup_data_disk; log '完成'
    CURRENT_STEP='[4/8] 准备配置与保护已有部署'; log "$CURRENT_STEP..."
    prepare_env; check_existing_stack
    check_port "$WEB_PORT" "$WEB_CONTAINER_NAME"; check_port "$SERVER_PORT" "$SERVER_CONTAINER_NAME"
    detect_ip
    log '完成'
    CURRENT_STEP='[5/8] 导入离线镜像'; log "$CURRENT_STEP..."
    load_images; log '完成'
    if [[ -f "$SCRIPT_DIR/zabbix-docker-report.txt" ]]; then
        run_command mv "$SCRIPT_DIR/zabbix-docker-report.txt" "${LOG_FILE%.log}.previous-report.txt"
    fi
    CURRENT_STEP='[6/8] 备份数据库并启动容器'; log "$CURRENT_STEP..."
    backup_database; start_stack; log '完成'
    CURRENT_STEP='[7/8] 健康与访问检测'; log "$CURRENT_STEP..."
    verify_stack; log '完成'
    CURRENT_STEP='[8/8] 生成部署报告'; log "$CURRENT_STEP..."
    generate_report; log '完成'
}

# source 时只加载函数，直接执行时运行主流程。
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
