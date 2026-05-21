#!/usr/bin/env bash
# =============================================================================
# Bootstrap server bootstrap
# Usage: sudo ./bootstrap.sh [--yes|--all] [--dry-run] [--verbose]
# =============================================================================

set -uo pipefail

SCRIPT_VERSION="2.0.0"
BACKUP_DIR="/var/backups/bootstrap"
AUTO_YES=0
DRY_RUN=0
VERBOSE=0
CONFIG_FILE=""
ONLY_STEPS=""
SKIP_STEPS=""

COLOR_INFO='\033[1;36m'
COLOR_SUCCESS='\033[1;32m'
COLOR_WARN='\033[1;33m'
COLOR_ERROR='\033[1;31m'
COLOR_BOLD='\033[1m'
COLOR_RESET='\033[0m'

info() { echo -e "${COLOR_INFO}    [INFO]${COLOR_RESET} $*" >&2; }
success() { echo -e "${COLOR_SUCCESS} [SUCCESS]${COLOR_RESET} $*" >&2; }
warn() { echo -e "${COLOR_WARN}    [WARN]${COLOR_RESET} $*" >&2; }
error() { echo -e "${COLOR_ERROR}   [ERROR]${COLOR_RESET} $*" >&2; }

usage() {
    cat <<'EOF'
用法: sudo ./bootstrap.sh [选项]

选项:
  --yes, --all        跳过确认，按默认值执行；缺少敏感输入时会安全跳过对应步骤
  --dry-run           预览模式，不要求 root，不改系统，只显示将要做什么
  --verbose           显示命令输出
  --only 05,06        只执行指定步骤
  --skip 12,14        跳过指定步骤
  --config FILE       从配置文件读取默认值
  -h, --help          显示此帮助信息
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes | --all)
                AUTO_YES=1
                ;;
            --dry-run)
                DRY_RUN=1
                ;;
            --verbose)
                VERBOSE=1
                ;;
            --only)
                shift
                if [[ $# -eq 0 || "${1:-}" == --* ]]; then
                    error "--only 需要指定步骤，例如: --only 05,06"
                    exit 1
                fi
                ONLY_STEPS="${1:-}"
                ;;
            --skip)
                shift
                if [[ $# -eq 0 || "${1:-}" == --* ]]; then
                    error "--skip 需要指定步骤，例如: --skip 12,14"
                    exit 1
                fi
                SKIP_STEPS="${1:-}"
                ;;
            --config)
                shift
                if [[ $# -eq 0 || "${1:-}" == --* ]]; then
                    error "--config 需要指定配置文件路径"
                    exit 1
                fi
                CONFIG_FILE="${1:-}"
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            *)
                error "未知参数: $1"
                usage
                exit 1
                ;;
        esac
        shift
    done
}

set_defaults() {
    : "${BOOTSTRAP_HOSTNAME:=server-01}"
    : "${BOOTSTRAP_SSH_PORT:=2222}"
    : "${BOOTSTRAP_OLD_SSH_PORT:=22}"
    : "${BOOTSTRAP_KEEP_OLD_SSH_PORT:=false}"
    : "${BOOTSTRAP_NEZHA_SERVER:=monitor.example.com:5555}"
    : "${BOOTSTRAP_NEZHA_TLS:=false}"
    : "${BOOTSTRAP_SWAP_SIZE:=1G}"
    : "${BOOTSTRAP_ZRAM_PERCENT:=25}"
    : "${BOOTSTRAP_ZRAM_ALGO:=lz4}"
    : "${BOOTSTRAP_NODEQUALITY_URL:=https://run.NodeQuality.com}"
    : "${BOOTSTRAP_NEZHA_INSTALLER_URL:=https://raw.githubusercontent.com/nezhahq/scripts/main/agent/install.sh}"
}

trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf "%s" "$value"
}

strip_optional_quotes() {
    local value="$1"
    if [[ ${#value} -ge 2 ]]; then
        if [[ "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then
            value="${value:1:${#value}-2}"
        elif [[ "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then
            value="${value:1:${#value}-2}"
        fi
    fi
    printf "%s" "$value"
}

is_allowed_config_key() {
    case "$1" in
        BOOTSTRAP_HOSTNAME | \
            BOOTSTRAP_SSH_PORT | \
            BOOTSTRAP_OLD_SSH_PORT | \
            BOOTSTRAP_KEEP_OLD_SSH_PORT | \
            BOOTSTRAP_NEZHA_SERVER | \
            BOOTSTRAP_NEZHA_TLS | \
            BOOTSTRAP_NEZHA_SECRET | \
            BOOTSTRAP_NEZHA_INSTALLER_URL | \
            BOOTSTRAP_NODEQUALITY_URL | \
            BOOTSTRAP_SSH_PUBLIC_KEY | \
            BOOTSTRAP_SSH_PUBLIC_KEY_FILE | \
            BOOTSTRAP_SWAP_SIZE | \
            BOOTSTRAP_ZRAM_PERCENT | \
            BOOTSTRAP_ZRAM_ALGO)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

load_config() {
    local raw line key value line_no=0
    if [[ -z "$CONFIG_FILE" ]]; then
        return 0
    fi
    if [[ ! -r "$CONFIG_FILE" ]]; then
        error "配置文件不可读: $CONFIG_FILE"
        exit 1
    fi
    while IFS= read -r raw || [[ -n "$raw" ]]; do
        line_no=$((line_no + 1))
        raw="${raw%$'\r'}"
        line="$(trim "$raw")"
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ "$line" =~ ^export[[:space:]]+(.+)$ ]]; then
            line="$(trim "${BASH_REMATCH[1]}")"
        fi
        if [[ ! "$line" =~ ^(BOOTSTRAP_[A-Za-z0-9_]+)=(.*)$ ]]; then
            error "配置文件第 $line_no 行格式不支持，只允许 BOOTSTRAP_KEY=value"
            exit 1
        fi
        key="${BASH_REMATCH[1]}"
        value="$(trim "${BASH_REMATCH[2]}")"
        value="$(strip_optional_quotes "$value")"
        if ! is_allowed_config_key "$key"; then
            error "配置文件第 $line_no 行包含未知配置项: $key"
            exit 1
        fi
        printf -v "$key" "%s" "$value"
    done <"$CONFIG_FILE"
}

check_root() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        return 0
    fi
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        error "此脚本必须以 root 权限运行，请使用 sudo"
        exit 1
    fi
}

check_supported_system() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        return 0
    fi
    if ! command -v apt-get >/dev/null 2>&1; then
        error "未找到 apt-get；此脚本仅支持 Debian/Ubuntu 系统"
        exit 1
    fi
    if ! command -v systemctl >/dev/null 2>&1; then
        error "未找到 systemctl；此脚本需要 systemd 环境"
        exit 1
    fi
    parse_os_release
    case "$OS_ID" in
        debian | ubuntu) ;;
        *)
            error "当前系统不是 Debian/Ubuntu: ${OS_ID:-unknown}"
            exit 1
            ;;
    esac
}

echo_banner() {
    cat <<'EOF'

██████╗  ██████╗  ██████╗ ████████╗███████╗████████╗██████╗  █████╗ ██████╗
██╔══██╗██╔═══██╗██╔═══██╗╚══██╔══╝██╔════╝╚══██╔══╝██╔══██╗██╔══██╗██╔══██╗
██████╔╝██║   ██║██║   ██║   ██║   ███████╗   ██║   ██████╔╝███████║██████╔╝
██╔══██╗██║   ██║██║   ██║   ██║   ╚════██║   ██║   ██╔══██╗██╔══██║██╔═══╝
██████╔╝╚██████╔╝╚██████╔╝   ██║   ███████║   ██║   ██║  ██║██║  ██║██║
╚═════╝  ╚═════╝  ╚═════╝    ╚═╝   ╚══════╝   ╚═╝   ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝

EOF
    echo "              Bootstrap 服务器初始化脚本 v${SCRIPT_VERSION}"
}

quote_cmd() {
    local quoted=""
    local part
    for part in "$@"; do
        printf -v part "%q" "$part"
        quoted+="${part} "
    done
    echo "${quoted% }"
}

run_cmd() {
    local description="$1"
    shift
    info "$description..."
    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "[dry-run] $(quote_cmd "$@")"
        return 0
    fi
    if [[ "$VERBOSE" -eq 1 ]]; then
        "$@"
    else
        "$@" >/dev/null 2>&1
    fi
}

run_interactive_cmd() {
    local description="$1"
    shift
    info "$description..."
    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "[dry-run] $(quote_cmd "$@")"
        return 0
    fi
    "$@"
}

confirm() {
    local msg="$1"
    local answer
    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "[dry-run] 自动确认: $msg"
        return 0
    fi
    if [[ "$AUTO_YES" -eq 1 ]]; then
        return 0
    fi
    while true; do
        echo -ne "\n${COLOR_BOLD}${msg}${COLOR_RESET} [y/n]: " >&2
        read -r answer </dev/tty
        case "$answer" in
            y | Y) return 0 ;;
            n | N) return 1 ;;
        esac
    done
}

prompt_input() {
    local description="$1"
    local default="${2:-}"
    local input
    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "[dry-run] 将询问: $description${default:+，默认值: $default}"
        echo "$default"
        return 0
    fi
    if [[ "$AUTO_YES" -eq 1 ]]; then
        echo "$default"
        return 0
    fi
    echo -ne "${COLOR_BOLD}  $description${COLOR_RESET}" >&2
    if [[ -n "$default" ]]; then
        echo -ne "\n  (直接回车使用默认值: $default, 输入 n 跳过): " >&2
    else
        echo -ne "\n  (直接回车跳过): " >&2
    fi
    read -r input </dev/tty
    if [[ "$input" == "n" || "$input" == "N" ]]; then
        echo ""
    elif [[ -z "$input" && -n "$default" ]]; then
        echo "$default"
    else
        echo "$input"
    fi
}

prompt_secret() {
    local description="$1"
    local default="${2:-}"
    local input
    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "[dry-run] 将询问敏感值: $description"
        echo "DRY_RUN_SECRET"
        return 0
    fi
    if [[ -n "$default" ]]; then
        echo "$default"
        return 0
    fi
    if [[ "$AUTO_YES" -eq 1 ]]; then
        echo ""
        return 0
    fi
    echo -ne "${COLOR_BOLD}  $description${COLOR_RESET}\n  (输入内容不会显示，直接回车跳过): " >&2
    read -r -s input </dev/tty
    echo "" >&2
    echo "$input"
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535))
}

validate_hostname() {
    local hostname="$1"
    [[ "$hostname" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]
}

validate_bool() {
    local value="$1"
    [[ "$value" == "true" || "$value" == "false" ]]
}

validate_swap_size() {
    local value="$1"
    [[ "$value" =~ ^[1-9][0-9]*[mMgG]$ ]]
}

validate_percent() {
    local value="$1"
    [[ "$value" =~ ^[0-9]+$ ]] && ((value >= 0 && value <= 100))
}

validate_zram_algo() {
    local value="$1"
    [[ "$value" == "lz4" || "$value" == "lzo" || "$value" == "zstd" ]]
}

validate_host_port() {
    local value="$1"
    [[ "$value" =~ ^[^[:space:]:]+:[0-9]+$ ]] && validate_port "${value##*:}"
}

ensure_dir() {
    local dir="$1"
    local mode="${2:-0755}"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "[dry-run] install -d -m $mode $dir"
        return 0
    fi
    install -d -m "$mode" "$dir"
}

backup_file() {
    local file="$1"
    local backup=""
    if [[ ! -e "$file" ]]; then
        echo ""
        return 0
    fi
    backup="$BACKUP_DIR/$(basename "$file").$(date +%Y%m%d-%H%M%S).$$"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "[dry-run] 备份 $file 到 $backup"
        echo "$backup"
        return 0
    fi
    install -d -m 0755 "$BACKUP_DIR" || return 1
    cp -a "$file" "$backup" || return 1
    echo "$backup"
}

restore_file_from_backup() {
    local target="$1"
    local backup="$2"
    if [[ -n "$backup" && -f "$backup" ]]; then
        cp -a "$backup" "$target" && return 0
        warn "无法从备份恢复 $target，请手动检查: $backup"
        return 1
    else
        rm -f "$target" && return 0
        warn "无法移除 $target，请手动检查"
        return 1
    fi
}

download_file() {
    local url="$1"
    local output="$2"
    if [[ ! "$url" =~ ^https:// ]]; then
        error "仅允许通过 HTTPS 下载: $url"
        return 1
    fi
    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "[dry-run] 下载 $url 到 $output"
        return 0
    fi
    curl --fail --location --silent --show-error --retry 3 --proto '=https' --tlsv1.2 \
        --output "$output" "$url"
}

contains_step() {
    local list="$1"
    local step="$2"
    local item
    local -a items
    IFS=',' read -r -a items <<<"$list"
    for item in "${items[@]}"; do
        item="${item//[[:space:]]/}"
        [[ "$item" == "$step" || "$item" == "${step#0}" ]] && return 0
    done
    return 1
}

validate_step_list() {
    local option_name="$1"
    local list="$2"
    local item number
    local -a items
    [[ -z "$list" ]] && return 0
    IFS=',' read -r -a items <<<"$list"
    for item in "${items[@]}"; do
        item="${item//[[:space:]]/}"
        if [[ -z "$item" ]]; then
            error "$option_name 包含空步骤"
            exit 1
        fi
        if [[ ! "$item" =~ ^[0-9]+$ ]]; then
            error "$option_name 包含非法步骤: $item"
            exit 1
        fi
        number=$((10#$item))
        if ((number < 1 || number > 16)); then
            error "$option_name 只能指定 01-16 之间的步骤: $item"
            exit 1
        fi
    done
}

validate_step_selection() {
    validate_step_list "--only" "$ONLY_STEPS"
    validate_step_list "--skip" "$SKIP_STEPS"
}

should_run_step() {
    local step="$1"
    if [[ -n "$ONLY_STEPS" ]] && ! contains_step "$ONLY_STEPS" "$step"; then
        return 1
    fi
    if [[ -n "$SKIP_STEPS" ]] && contains_step "$SKIP_STEPS" "$step"; then
        return 1
    fi
    return 0
}

run_step() {
    local step_num="$1"
    local step_name="$2"
    local step_func="$3"
    local ret

    if ! should_run_step "$step_num"; then
        warn "跳过步骤 ${step_num}: ${step_name}"
        return 0
    fi

    echo "" >&2
    echo -e "${COLOR_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${COLOR_RESET}" >&2
    echo -e "${COLOR_BOLD}  步骤 ${step_num}: ${step_name}${COLOR_RESET}" >&2
    echo -e "${COLOR_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${COLOR_RESET}" >&2

    "$step_func"
    ret=$?
    if [[ $ret -eq 0 ]]; then
        success "步骤 ${step_num} 完成"
    else
        error "步骤 ${step_num} 执行失败"
        exit "$ret"
    fi
}

apt_install() {
    run_cmd "安装软件包: $*" apt-get install -y "$@"
}

write_file() {
    local path="$1"
    local mode="${2:-0644}"
    local content="$3"
    local tmp
    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "[dry-run] 写入 $path"
        return 0
    fi
    ensure_dir "$(dirname "$path")" 0755 || return 1
    tmp="$(mktemp)" || return 1
    printf "%s\n" "$content" >"$tmp" || {
        rm -f "$tmp"
        return 1
    }
    install -m "$mode" "$tmp" "$path" || {
        rm -f "$tmp"
        return 1
    }
    rm -f "$tmp"
}

replace_file_block() {
    local path="$1"
    local start_marker="$2"
    local end_marker="$3"
    local content="$4"
    local tmp

    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "[dry-run] 更新 $path 中的 bootstrap 配置块"
        return 0
    fi

    tmp="$(mktemp)" || return 1
    if [[ -f "$path" ]]; then
        awk -v start="$start_marker" -v end="$end_marker" '
            index($0, start) { skip=1; next }
            index($0, end) { skip=0; next }
            skip != 1 { print }
        ' "$path" >"$tmp" || {
            rm -f "$tmp"
            return 1
        }
    fi
    {
        printf "\n%s\n" "$content"
    } >>"$tmp" || {
        rm -f "$tmp"
        return 1
    }
    install -m 0644 "$tmp" "$path" || {
        rm -f "$tmp"
        return 1
    }
    rm -f "$tmp"
}

detect_ssh_service() {
    if systemctl list-unit-files ssh.service >/dev/null 2>&1; then
        echo "ssh.service"
    elif systemctl list-unit-files sshd.service >/dev/null 2>&1; then
        echo "sshd.service"
    else
        echo "ssh"
    fi
}

ensure_sshd_config_include() {
    local include_line="Include /etc/ssh/sshd_config.d/*.conf"
    local tmp
    if grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config 2>/dev/null; then
        return 0
    fi
    tmp="$(mktemp)" || return 1
    {
        printf "%s\n" "$include_line"
        [[ -f /etc/ssh/sshd_config ]] && cat /etc/ssh/sshd_config
    } >"$tmp" || {
        rm -f "$tmp"
        return 1
    }
    install -m 0644 "$tmp" /etc/ssh/sshd_config || {
        rm -f "$tmp"
        return 1
    }
    rm -f "$tmp"
}

allow_ufw_port_if_active() {
    local port="$1"
    if ! command -v ufw >/dev/null 2>&1; then
        return 0
    fi
    if ufw status 2>/dev/null | grep -q '^Status: active'; then
        run_cmd "UFW 已启用，先开放 SSH 新端口 $port/tcp" ufw allow "$port/tcp" || return 1
    fi
}

parse_os_release() {
    local ID=""
    local VERSION_CODENAME=""
    local UBUNTU_CODENAME=""
    if [[ -r /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
    fi
    OS_ID="${ID:-}"
    OS_VERSION_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
    OS_UBUNTU_CODENAME="${UBUNTU_CODENAME:-}"
}

step_01_update() {
    if ! confirm "更新 apt 索引并升级所有已安装软件包"; then
        warn "跳过步骤 01"
        return 0
    fi
    run_cmd "更新 apt 索引" apt-get update || return 1
    run_cmd "升级软件包" apt-get upgrade -y || return 1
}

step_02_software() {
    if ! confirm "安装必要软件: vim htop net-tools unzip curl wget"; then
        warn "跳过步骤 02"
        return 0
    fi
    apt_install vim htop net-tools unzip curl wget || return 1
}

step_03_password() {
    if ! confirm "修改 root 密码"; then
        warn "跳过步骤 03"
        return 0
    fi
    if [[ "$AUTO_YES" -eq 1 && "$DRY_RUN" -ne 1 ]]; then
        warn "--yes 模式不会自动修改 root 密码，请交互执行此步骤"
        return 0
    fi
    run_interactive_cmd "修改 root 密码" passwd || return 1
}

step_04_hostname() {
    local new_hostname
    new_hostname="$(prompt_input "新主机名（留空跳过）" "$BOOTSTRAP_HOSTNAME")"
    if [[ -z "$new_hostname" ]]; then
        warn "未输入主机名，跳过步骤 04"
        return 0
    fi
    if ! validate_hostname "$new_hostname"; then
        error "主机名不合法: $new_hostname"
        return 1
    fi
    if ! confirm "将主机名设置为 '$new_hostname'"; then
        warn "跳过步骤 04"
        return 0
    fi
    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "[dry-run] hostnamectl set-hostname $new_hostname"
        return 0
    fi
    if [[ "$(hostname 2>/dev/null)" == "$new_hostname" ]]; then
        warn "主机名已经是 ${new_hostname}，跳过"
        return 0
    fi
    backup_file /etc/hostname >/dev/null || return 1
    run_cmd "设置主机名" hostnamectl set-hostname "$new_hostname" || return 1
}

step_05_ssh_port() {
    local ssh_port backup port_dropin port_backup service sshd_bin
    ssh_port="$(prompt_input "SSH 端口（留空跳过）" "$BOOTSTRAP_SSH_PORT")"
    if [[ -z "$ssh_port" ]]; then
        warn "未输入 SSH 端口，跳过步骤 05"
        return 0
    fi
    if ! validate_port "$ssh_port"; then
        error "SSH 端口不合法: $ssh_port"
        return 1
    fi
    if ! confirm "修改 SSH 端口为 ${ssh_port}，并在重启前验证配置"; then
        warn "跳过步骤 05"
        return 0
    fi

    backup="$(backup_file /etc/ssh/sshd_config)" || return 1
    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "[dry-run] 注释 /etc/ssh/sshd_config 中已有 Port 行"
        info "[dry-run] 确保 /etc/ssh/sshd_config 引入 sshd_config.d"
        info "[dry-run] 写入 /etc/ssh/sshd_config.d/00-bootstrap-port.conf"
        info "[dry-run] 清理旧的 /etc/ssh/sshd_config.d/99-bootstrap-port.conf"
        info "[dry-run] sshd -t -f /etc/ssh/sshd_config"
        info "[dry-run] 如果 UFW 已启用，先放行 $ssh_port/tcp"
        info "[dry-run] systemctl restart $(detect_ssh_service)"
        return 0
    fi

    port_dropin="/etc/ssh/sshd_config.d/00-bootstrap-port.conf"
    port_backup="$(backup_file "$port_dropin")" || return 1
    install -d -m 0755 /etc/ssh/sshd_config.d || return 1
    if [[ -f /etc/ssh/sshd_config ]]; then
        sed -i -E 's/^([[:space:]]*)Port[[:space:]]+/# disabled by bootstrap: &/' /etc/ssh/sshd_config || {
            restore_file_from_backup /etc/ssh/sshd_config "$backup"
            restore_file_from_backup "$port_dropin" "$port_backup"
            return 1
        }
    fi
    ensure_sshd_config_include || {
        restore_file_from_backup /etc/ssh/sshd_config "$backup"
        restore_file_from_backup "$port_dropin" "$port_backup"
        return 1
    }
    printf "Port %s\n" "$ssh_port" >"$port_dropin" || {
        restore_file_from_backup /etc/ssh/sshd_config "$backup"
        restore_file_from_backup "$port_dropin" "$port_backup"
        return 1
    }
    rm -f /etc/ssh/sshd_config.d/99-bootstrap-port.conf || {
        restore_file_from_backup /etc/ssh/sshd_config "$backup"
        restore_file_from_backup "$port_dropin" "$port_backup"
        return 1
    }

    sshd_bin="$(command -v sshd || true)"
    [[ -z "$sshd_bin" && -x /usr/sbin/sshd ]] && sshd_bin="/usr/sbin/sshd"
    if [[ -z "$sshd_bin" ]]; then
        error "未找到 sshd，无法验证 SSH 配置"
        restore_file_from_backup /etc/ssh/sshd_config "$backup"
        restore_file_from_backup "$port_dropin" "$port_backup"
        return 1
    fi
    if ! "$sshd_bin" -t -f /etc/ssh/sshd_config; then
        error "SSH 配置验证失败，正在恢复备份"
        restore_file_from_backup /etc/ssh/sshd_config "$backup"
        restore_file_from_backup "$port_dropin" "$port_backup"
        return 1
    fi

    if ! allow_ufw_port_if_active "$ssh_port"; then
        restore_file_from_backup /etc/ssh/sshd_config "$backup"
        restore_file_from_backup "$port_dropin" "$port_backup"
        return 1
    fi
    service="$(detect_ssh_service)"
    if ! run_cmd "重启 SSH 服务" systemctl restart "$service"; then
        error "SSH 服务重启失败，正在恢复原配置"
        restore_file_from_backup /etc/ssh/sshd_config "$backup"
        restore_file_from_backup "$port_dropin" "$port_backup"
        "$sshd_bin" -t -f /etc/ssh/sshd_config >/dev/null 2>&1 && systemctl restart "$service" >/dev/null 2>&1 || true
        return 1
    fi
    success "SSH 端口已设置为 ${ssh_port}。启用防火墙前请确认该端口已放行。"
}

step_06_ufw() {
    local ufw_ssh_port
    ufw_ssh_port="$(prompt_input "防火墙允许的 SSH 端口（留空跳过）" "$BOOTSTRAP_SSH_PORT")"
    if [[ -z "$ufw_ssh_port" ]]; then
        warn "未输入 SSH 端口，跳过步骤 06"
        return 0
    fi
    if ! validate_port "$ufw_ssh_port"; then
        error "防火墙 SSH 端口不合法: $ufw_ssh_port"
        return 1
    fi
    if ! validate_bool "$BOOTSTRAP_KEEP_OLD_SSH_PORT"; then
        error "BOOTSTRAP_KEEP_OLD_SSH_PORT 只能是 true 或 false"
        return 1
    fi
    if [[ "$BOOTSTRAP_KEEP_OLD_SSH_PORT" == "true" ]] && ! validate_port "$BOOTSTRAP_OLD_SSH_PORT"; then
        error "BOOTSTRAP_OLD_SSH_PORT 不合法: $BOOTSTRAP_OLD_SSH_PORT"
        return 1
    fi
    if ! confirm "安装并启用 UFW，开放 $ufw_ssh_port/tcp、80/tcp、443/tcp"; then
        warn "跳过步骤 06"
        return 0
    fi
    apt_install ufw || return 1
    run_cmd "开放 SSH 端口 $ufw_ssh_port/tcp" ufw allow "$ufw_ssh_port/tcp" || return 1
    if [[ "$BOOTSTRAP_KEEP_OLD_SSH_PORT" == "true" && -n "$BOOTSTRAP_OLD_SSH_PORT" && "$BOOTSTRAP_OLD_SSH_PORT" != "$ufw_ssh_port" ]]; then
        run_cmd "临时保留旧 SSH 端口 $BOOTSTRAP_OLD_SSH_PORT/tcp" ufw allow "$BOOTSTRAP_OLD_SSH_PORT/tcp" || return 1
    fi
    run_cmd "开放 HTTP 端口 80/tcp" ufw allow 80/tcp || return 1
    run_cmd "开放 HTTPS 端口 443/tcp" ufw allow 443/tcp || return 1
    run_cmd "启用 UFW" ufw --force enable || return 1
    run_cmd "显示 UFW 状态" ufw status verbose || return 1
    if [[ "$BOOTSTRAP_KEEP_OLD_SSH_PORT" == "true" && -n "$BOOTSTRAP_OLD_SSH_PORT" && "$BOOTSTRAP_OLD_SSH_PORT" != "$ufw_ssh_port" ]]; then
        warn "旧 SSH 端口已按配置保留。确认新端口能登录后，可手动执行: ufw delete allow ${BOOTSTRAP_OLD_SSH_PORT}/tcp"
    fi
}

step_07_ssh_keys() {
    local key_file="$HOME/.ssh/authorized_keys"
    local tmp line added=0
    if ! confirm "添加 SSH 公钥到 $key_file"; then
        warn "跳过步骤 07"
        return 0
    fi
    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "[dry-run] 将创建 $HOME/.ssh 并追加 authorized_keys"
        return 0
    fi

    install -d -m 700 "$HOME/.ssh" || return 1
    touch "$key_file" || return 1
    chmod 600 "$key_file" || return 1
    tmp="$(mktemp)" || return 1

    if [[ -n "${BOOTSTRAP_SSH_PUBLIC_KEY:-}" ]]; then
        printf "%s\n" "$BOOTSTRAP_SSH_PUBLIC_KEY" >"$tmp"
    elif [[ -n "${BOOTSTRAP_SSH_PUBLIC_KEY_FILE:-}" ]]; then
        cp "$BOOTSTRAP_SSH_PUBLIC_KEY_FILE" "$tmp" || {
            rm -f "$tmp"
            return 1
        }
    else
        if [[ "$AUTO_YES" -eq 1 ]]; then
            warn "--yes 模式未提供 SSH 公钥，跳过步骤 07"
            rm -f "$tmp"
            return 0
        fi
        echo -e "${COLOR_WARN}请粘贴 SSH 公钥（粘贴后按 Ctrl+D 结束）:${COLOR_RESET}" >&2
        cat >"$tmp" </dev/tty
    fi

    if [[ ! -s "$tmp" ]]; then
        warn "没有读取到 SSH 公钥，跳过"
        rm -f "$tmp"
        return 0
    fi

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if ! grep -qxF "$line" "$key_file"; then
            printf "%s\n" "$line" >>"$key_file" || {
                rm -f "$tmp"
                return 1
            }
            added=$((added + 1))
        fi
    done <"$tmp"
    rm -f "$tmp"
    success "SSH 公钥处理完成，新增 $added 行"
}

step_08_profile() {
    local content
    if ! confirm "配置 /etc/profile.d/99-bootstrap.sh（git 提示、PS1、HISTFORMAT、别名）"; then
        warn "跳过步骤 08"
        return 0
    fi
    content=$(cat <<'PROFILE_EOF'
# -- bootstrap 配置 --
export GIT_PS1_SHOWDIRTYSTATE=1

if ! command -v __git_ps1 >/dev/null 2>&1 && [ -r /usr/share/git/completion/git-prompt.sh ]; then
    . /usr/share/git/completion/git-prompt.sh
fi

__bootstrap_git_ps1() {
    command -v __git_ps1 >/dev/null 2>&1 && __git_ps1 " (%s)"
}

PS1='\[\e[1;32m\][\u@\h \W]\[\e[1;33m\]$(__bootstrap_git_ps1)\[\e[1;32m\]\$ \[\e[0m\]'
HISTFILESIZE=4000
HISTSIZE=4000
USER_IP=$(who -u am i 2>/dev/null | awk '{print $NF}' | sed -e 's/[()]//g')
if [ -z "$USER_IP" ]; then USER_IP=$(hostname); fi
HISTTIMEFORMAT="%F %T $USER_IP:$(whoami) "
export HISTTIMEFORMAT
alias ll='ls -al'
# -- bootstrap 配置 end --
PROFILE_EOF
)
    backup_file /etc/profile.d/99-bootstrap.sh >/dev/null || return 1
    write_file /etc/profile.d/99-bootstrap.sh 0644 "$content" || return 1
    run_cmd "验证 Profile 配置语法" bash -n /etc/profile.d/99-bootstrap.sh || return 1
}

step_09_nezha() {
    local nezha_server nezha_secret nezha_tls tmp
    nezha_server="$(prompt_input "哪吒探针服务器地址（格式 host:port，留空跳过）" "$BOOTSTRAP_NEZHA_SERVER")"
    if [[ -z "$nezha_server" ]]; then
        warn "未配置哪吒探针，跳过步骤 09"
        return 0
    fi
    if ! validate_host_port "$nezha_server"; then
        error "哪吒探针服务器地址不合法: $nezha_server"
        return 1
    fi
    nezha_secret="$(prompt_secret "哪吒探针客户端密钥" "${BOOTSTRAP_NEZHA_SECRET:-}")"
    if [[ -z "$nezha_secret" ]]; then
        warn "未输入密钥，跳过步骤 09"
        return 0
    fi
    nezha_tls="$(prompt_input "是否使用 TLS（true/false）" "$BOOTSTRAP_NEZHA_TLS")"
    if ! validate_bool "$nezha_tls"; then
        error "TLS 选项只能是 true 或 false"
        return 1
    fi
    if ! confirm "下载并安装哪吒探针 (server: $nezha_server)"; then
        warn "跳过步骤 09"
        return 0
    fi
    apt_install curl || return 1
    if [[ "$DRY_RUN" -eq 1 ]]; then
        tmp="/tmp/bootstrap-nezha-agent.XXXXXX"
        download_file "$BOOTSTRAP_NEZHA_INSTALLER_URL" "$tmp" || return 1
        info "[dry-run] NZ_SERVER=$nezha_server NZ_TLS=$nezha_tls NZ_CLIENT_SECRET=****** bash $tmp"
        return 0
    fi
    tmp="$(mktemp)" || return 1
    download_file "$BOOTSTRAP_NEZHA_INSTALLER_URL" "$tmp" || {
        rm -f "$tmp"
        return 1
    }
    chmod +x "$tmp" || {
        rm -f "$tmp"
        return 1
    }
    NZ_SERVER="$nezha_server" NZ_TLS="$nezha_tls" NZ_CLIENT_SECRET="$nezha_secret" "$tmp"
    local ret=$?
    rm -f "$tmp"
    [[ $ret -eq 0 ]] || return "$ret"
}

step_10_bbr() {
    local content
    if ! confirm "开启 BBR 和 FQ 拥塞控制算法"; then
        warn "跳过步骤 10"
        return 0
    fi
    content=$(cat <<'BBR_EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
BBR_EOF
)
    backup_file /etc/sysctl.d/99-bootstrap-bbr.conf >/dev/null || return 1
    write_file /etc/sysctl.d/99-bootstrap-bbr.conf 0644 "$content" || return 1
    run_cmd "应用 sysctl 配置" sysctl --system || return 1
    if [[ "$DRY_RUN" -ne 1 ]]; then
        if sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null | grep -qx "bbr"; then
            success "BBR 已启用"
        else
            warn "BBR 可能未启用，当前内核可能不支持"
        fi
    fi
}

step_11_ipv6() {
    local content
    if ! confirm "禁用 IPv6（可选）"; then
        warn "跳过步骤 11"
        return 0
    fi
    content=$(cat <<'IPV6_EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
IPV6_EOF
)
    backup_file /etc/sysctl.d/99-bootstrap-disable-ipv6.conf >/dev/null || return 1
    write_file /etc/sysctl.d/99-bootstrap-disable-ipv6.conf 0644 "$content" || return 1
    run_cmd "应用 IPv6 sysctl 配置" sysctl --system || return 1
}

step_12_nodequality() {
    local tmp ret
    if ! confirm "运行 NodeQuality 延迟测试（会下载官方测试脚本）"; then
        warn "跳过步骤 12"
        return 0
    fi
    apt_install curl || return 1
    if [[ "$DRY_RUN" -eq 1 ]]; then
        tmp="/tmp/bootstrap-nodequality.XXXXXX"
        download_file "$BOOTSTRAP_NODEQUALITY_URL" "$tmp" || return 1
        info "[dry-run] bash $tmp"
        return 0
    fi
    tmp="$(mktemp)" || return 1
    download_file "$BOOTSTRAP_NODEQUALITY_URL" "$tmp" || {
        rm -f "$tmp"
        return 1
    }
    run_interactive_cmd "运行 NodeQuality 测试" bash "$tmp"
    ret=$?
    rm -f "$tmp"
    return "$ret"
}

swap_size_to_mb() {
    local value="$1"
    if [[ "$value" =~ ^([0-9]+)[gG]$ ]]; then
        echo $((BASH_REMATCH[1] * 1024))
    elif [[ "$value" =~ ^([0-9]+)[mM]$ ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        return 1
    fi
}

configure_swapfile() {
    local swap_size="$1"
    local tmp_swap="/swapfile.bootstrap.$$"
    local old_swap_backup=""
    local count_mb fstab_backup

    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "[dry-run] 创建 $swap_size /swapfile，写入 /etc/fstab"
        return 0
    fi

    rm -f "$tmp_swap"
    if ! fallocate -l "$swap_size" "$tmp_swap" 2>/dev/null; then
        count_mb="$(swap_size_to_mb "$swap_size")" || return 1
        dd if=/dev/zero of="$tmp_swap" bs=1M count="$count_mb" status=none || {
            rm -f "$tmp_swap"
            return 1
        }
    fi
    chmod 600 "$tmp_swap" || {
        rm -f "$tmp_swap"
        return 1
    }
    mkswap "$tmp_swap" >/dev/null || {
        rm -f "$tmp_swap"
        return 1
    }

    if grep -q '^/swapfile[[:space:]]' /proc/swaps 2>/dev/null; then
        swapoff /swapfile || {
            rm -f "$tmp_swap"
            return 1
        }
    fi
    if [[ -e /swapfile ]]; then
        old_swap_backup="/swapfile.bak.$(date +%Y%m%d-%H%M%S)"
        mv /swapfile "$old_swap_backup" || {
            rm -f "$tmp_swap"
            return 1
        }
    fi
    if ! mv "$tmp_swap" /swapfile; then
        if [[ -n "$old_swap_backup" && -e "$old_swap_backup" ]]; then
            mv "$old_swap_backup" /swapfile
            swapon /swapfile 2>/dev/null || true
        fi
        return 1
    fi
    if ! swapon /swapfile; then
        warn "新 swapfile 启用失败，尝试恢复旧文件"
        swapoff /swapfile 2>/dev/null || true
        rm -f /swapfile
        if [[ -n "$old_swap_backup" && -e "$old_swap_backup" ]]; then
            mv "$old_swap_backup" /swapfile
            swapon /swapfile 2>/dev/null || true
        fi
        return 1
    fi

    fstab_backup="$(backup_file /etc/fstab)" || return 1
    if ! sed -i '\|^/swapfile |d' /etc/fstab || ! printf "%s\n" "/swapfile none swap sw,pri=10 0 0" >>/etc/fstab; then
        restore_file_from_backup /etc/fstab "$fstab_backup"
        return 1
    fi
}

step_13_swap_zram() {
    local choice swap_size zram_percent zram_algo desc content
    choice="$(prompt_input "配置模式（1=仅Swap, 2=Swap+ZRam）" "2")"
    if [[ -z "$choice" ]]; then
        warn "跳过步骤 13"
        return 0
    fi
    if [[ "$choice" != "1" && "$choice" != "2" ]]; then
        error "配置模式只能是 1 或 2"
        return 1
    fi

    swap_size="$(prompt_input "Swap 文件大小（如 1G，留空跳过）" "$BOOTSTRAP_SWAP_SIZE")"
    if [[ -n "$swap_size" ]] && ! validate_swap_size "$swap_size"; then
        error "Swap 大小不合法: $swap_size"
        return 1
    fi

    if [[ "$choice" == "2" ]]; then
        zram_percent="$(prompt_input "ZRam 占物理内存百分比（留空跳过）" "$BOOTSTRAP_ZRAM_PERCENT")"
        if [[ -n "$zram_percent" ]] && ! validate_percent "$zram_percent"; then
            error "ZRam 百分比不合法: $zram_percent"
            return 1
        fi
        if [[ -n "$zram_percent" && "$zram_percent" != "0" ]]; then
            zram_algo="$(prompt_input "ZRam 压缩算法（lz4/lzo/zstd）" "$BOOTSTRAP_ZRAM_ALGO")"
            if ! validate_zram_algo "$zram_algo"; then
                error "ZRam 压缩算法不支持: $zram_algo"
                return 1
            fi
        fi
    else
        zram_percent=""
    fi

    if [[ -z "$swap_size" && -z "${zram_percent:-}" ]]; then
        warn "未配置 Swap 和 ZRam，跳过步骤 13"
        return 0
    fi
    if [[ -z "$swap_size" && "${zram_percent:-}" == "0" ]]; then
        warn "未配置 Swap 和 ZRam，跳过步骤 13"
        return 0
    fi

    desc=""
    [[ -n "$swap_size" ]] && desc="Swap ($swap_size)"
    [[ -n "${zram_percent:-}" && "$zram_percent" != "0" ]] && desc="${desc:+$desc + }ZRam (${zram_percent}%/$zram_algo)"
    if ! confirm "配置 $desc"; then
        warn "跳过步骤 13"
        return 0
    fi

    if [[ -n "$swap_size" ]]; then
        configure_swapfile "$swap_size" || return 1
        success "Swapfile 配置完成"
    fi

    if [[ -n "${zram_percent:-}" && "$zram_percent" != "0" ]]; then
        apt_install zram-tools || return 1
        content=$(cat <<ZRAM_EOF
ALGO=$zram_algo
PERCENT=$zram_percent
PRIORITY=100
ZRAM_EOF
)
        backup_file /etc/default/zramswap >/dev/null || return 1
        write_file /etc/default/zramswap 0644 "$content" || return 1
        content=$(cat <<'SYSCTL_ZRAM_EOF'
vm.swappiness=40
vm.vfs_cache_pressure=100
SYSCTL_ZRAM_EOF
)
        backup_file /etc/sysctl.d/99-zram-swap.conf >/dev/null || return 1
        write_file /etc/sysctl.d/99-zram-swap.conf 0644 "$content" || return 1
        run_cmd "启用 zramswap 服务" systemctl enable --now zramswap || return 1
        run_cmd "应用 sysctl 配置" sysctl --system || return 1
        run_cmd "重启 zramswap 服务" systemctl restart zramswap || return 1
        success "ZRam 配置完成"
    fi

    run_cmd "显示 swap 状态" swapon --show || return 1
    run_cmd "显示 zram 状态" zramctl || true
    run_cmd "显示内存状态" free -h || true
}

install_crowdsec_repo() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "[dry-run] 添加 CrowdSec packagecloud 仓库和 keyring"
        return 0
    fi
    install -d -m 0755 /etc/apt/keyrings /etc/apt/sources.list.d /etc/apt/preferences.d || return 1
    local key_tmp
    key_tmp="$(mktemp)" || return 1
    download_file "https://packagecloud.io/crowdsec/crowdsec/gpgkey" "$key_tmp" || {
        rm -f "$key_tmp"
        return 1
    }
    gpg --dearmor --yes -o /etc/apt/keyrings/crowdsec_crowdsec-archive-keyring.gpg "$key_tmp" || {
        rm -f "$key_tmp"
        return 1
    }
    rm -f "$key_tmp"
    chmod 0644 /etc/apt/keyrings/crowdsec_crowdsec-archive-keyring.gpg || return 1
    cat >/etc/apt/sources.list.d/crowdsec_crowdsec.list <<'CROWDSEC_REPO_EOF' || return 1
deb [signed-by=/etc/apt/keyrings/crowdsec_crowdsec-archive-keyring.gpg] https://packagecloud.io/crowdsec/crowdsec/any any main
CROWDSEC_REPO_EOF
    cat >/etc/apt/preferences.d/crowdsec <<'CROWDSEC_PIN_EOF' || return 1
Package: *
Pin: release o=packagecloud.io/crowdsec/crowdsec,a=any,n=any,c=main
Pin-Priority: 1001
CROWDSEC_PIN_EOF
}

install_crowdsec_collection() {
    local collection="$1"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "[dry-run] cscli collections install $collection"
        return 0
    fi
    run_cmd "安装/确认 CrowdSec collection: $collection" cscli collections install "$collection"
}

step_14_crowdsec() {
    if ! confirm "安装 CrowdSec 防护（ufw 日志、rsyslog、nginx-proxy-manager、iptables、sshd 规则）"; then
        warn "跳过步骤 14"
        return 0
    fi
    apt_install ufw rsyslog curl gnupg apt-transport-https || return 1
    if [[ "$DRY_RUN" -ne 1 ]]; then
        parse_os_release
        if [[ "${OS_ID:-}" == "debian" ]]; then
            apt_install debian-archive-keyring || return 1
        fi
    fi
    run_cmd "开启 UFW 日志" ufw logging on || return 1
    run_cmd "启用 rsyslog" systemctl enable rsyslog --now || return 1
    install_crowdsec_repo || return 1
    run_cmd "更新 apt 索引" apt-get update || return 1
    apt_install crowdsec crowdsec-firewall-bouncer-iptables || return 1
    run_cmd "更新 CrowdSec hub" cscli hub update || return 1
    install_crowdsec_collection crowdsecurity/nginx-proxy-manager || return 1
    install_crowdsec_collection crowdsecurity/iptables || return 1
    install_crowdsec_collection crowdsecurity/sshd || return 1
    run_cmd "启用 CrowdSec" systemctl enable crowdsec --now || return 1
    run_cmd "验证 CrowdSec 配置" crowdsec -t || return 1
    run_cmd "重启 CrowdSec" systemctl restart crowdsec || return 1
    run_cmd "显示 CrowdSec collections" cscli collections list || return 1
}

remove_conflicting_docker_packages() {
    local pkg
    local -a packages=(
        docker.io
        docker-doc
        docker-compose
        docker-compose-v2
        podman-docker
        containerd
        runc
    )
    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "[dry-run] 检查并移除可能与 Docker 官方包冲突的旧包"
        return 0
    fi
    for pkg in "${packages[@]}"; do
        if dpkg -s "$pkg" >/dev/null 2>&1; then
            run_cmd "移除冲突软件包: $pkg" apt-get remove -y "$pkg" || return 1
        fi
    done
}

install_docker_repo() {
    local docker_os docker_codename arch key_tmp
    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "[dry-run] 添加 Docker 官方 apt 仓库（运行时按 Debian/Ubuntu 版本自动选择）"
        return 0
    fi
    parse_os_release
    arch="$(dpkg --print-architecture)" || return 1
    case "$OS_ID" in
        ubuntu)
            docker_os="ubuntu"
            docker_codename="${OS_UBUNTU_CODENAME:-$OS_VERSION_CODENAME}"
            ;;
        debian)
            docker_os="debian"
            docker_codename="$OS_VERSION_CODENAME"
            ;;
        *)
            error "暂不支持自动配置 Docker 仓库的系统: ${OS_ID:-unknown}"
            return 1
            ;;
    esac
    if [[ -z "$docker_codename" ]]; then
        error "无法识别系统版本代号，不能配置 Docker 仓库"
        return 1
    fi
    install -d -m 0755 /etc/apt/keyrings || return 1
    key_tmp="$(mktemp)" || return 1
    download_file "https://download.docker.com/linux/$docker_os/gpg" "$key_tmp" || {
        rm -f "$key_tmp"
        return 1
    }
    install -m 0644 "$key_tmp" /etc/apt/keyrings/docker.asc || {
        rm -f "$key_tmp"
        return 1
    }
    rm -f "$key_tmp"
    cat >/etc/apt/sources.list.d/docker.list <<DOCKER_REPO_EOF || return 1
deb [arch=$arch signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$docker_os $docker_codename stable
DOCKER_REPO_EOF
}

step_15_docker() {
    local content shim docker_daemon_backup
    if ! confirm "安装 Docker Engine、Buildx、Docker Compose，并配置日志轮转"; then
        warn "跳过步骤 15"
        return 0
    fi
    remove_conflicting_docker_packages || return 1
    apt_install ca-certificates curl gnupg || return 1
    install_docker_repo || return 1
    run_cmd "更新 apt 索引" apt-get update || return 1
    apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || return 1

    content=$(cat <<'DOCKER_DAEMON_EOF'
{
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "20m",
        "max-file": "3"
    },
    "experimental": true,
    "storage-driver": "overlay2"
}
DOCKER_DAEMON_EOF
)
    docker_daemon_backup="$(backup_file /etc/docker/daemon.json)" || return 1
    write_file /etc/docker/daemon.json 0644 "$content" || return 1
    if ! run_cmd "重启 Docker" systemctl restart docker; then
        error "Docker 重启失败，正在恢复原 daemon.json"
        restore_file_from_backup /etc/docker/daemon.json "$docker_daemon_backup"
        systemctl restart docker >/dev/null 2>&1 || true
        return 1
    fi

    shim=$(cat <<'COMPOSE_SHIM_EOF'
#!/usr/bin/env sh
exec docker compose "$@"
COMPOSE_SHIM_EOF
)
    write_file /usr/local/bin/docker-compose 0755 "$shim" || return 1

    run_cmd "检查 Docker 版本" docker --version || return 1
    run_cmd "检查 Docker Compose 版本" docker compose version || return 1
    run_cmd "检查 docker-compose 兼容命令" docker-compose version || return 1
    warn "Docker 会直接操作 iptables。若依赖 UFW 做严格入站控制，请额外检查 DOCKER-USER 链。"
}

step_16_vim() {
    local content
    if ! confirm "配置 ~/.vimrc"; then
        warn "跳过步骤 16"
        return 0
    fi
    read -r -d '' content <<'VIM_EOF' || true
" -- bootstrap vimrc --
" ==========================================
" 1. 基础与显示设置 (UI & Display)
" ==========================================
syntax on             " 开启语法高亮
set number            " 显示绝对行号
" set relativenumber    " 显示相对行号（结合 set number 使用，光标所在行显示绝对行号，其他行显示相对行号，非常方便上下移动）
set cursorline        " 突出显示当前光标所在行
set showmatch         " 光标遇到括号时，自动高亮对应的另一半括号
set wildmenu          " 在底部命令模式下，开启命令自动补全的视觉提示
set nowrap            " 不自动折行（如果单行太长，超出屏幕也不折行显示）

" ==========================================
" 2. 缩进与 Tab 设置 (Indentation & Tabs)
" ==========================================
set tabstop=2         " 按下 Tab 键时，Vim 显示的空格数
set shiftwidth=2      " 自动缩进时，每一级缩进的空格数
set expandtab         " 将 Tab 键自动转换成空格（写 Python 或前端等极力推荐开启）
set autoindent        " 开启自动缩进（新行会自动对齐上一行的缩进）
set smartindent       " 智能缩进（针对 C/C++ 等类似语法，识别大括号等自动调整缩进）

" ==========================================
" 3. 搜索设置 (Search)
" ==========================================
set hlsearch          " 搜索时高亮显示所有匹配的结果
set incsearch         " 边输入边搜索（输入搜索词的过程中，光标会实时跳到匹配的位置）
set ignorecase        " 搜索时忽略大小写
set smartcase         " 智能大小写（如果搜索词全小写，则忽略大小写；如果包含大写字母，则精确匹配大小写）

" ==========================================
" 4. 其他实用设置 (Misc)
" ==========================================
set encoding=utf-8    " 设置内部编码为 UTF-8，防止中文乱码
set mouse=a           " 开启鼠标支持（可以用鼠标点击定位光标、滚动滚轮）
set clipboard=unnamed " 共享系统剪贴板（可以直接使用 y 复制内容到系统剪贴板，用 p 粘贴系统剪贴板的内容）
set history=1000      " 增加历史记录（保留更多的冒号命令和搜索历史）
" -- bootstrap vimrc end --
VIM_EOF
    backup_file "$HOME/.vimrc" >/dev/null || return 1
    replace_file_block "$HOME/.vimrc" '" -- bootstrap vimrc --' '" -- bootstrap vimrc end --' "$content" || return 1
}

main() {
    parse_args "$@"
    validate_step_selection
    load_config
    set_defaults
    echo_banner
    check_root
    check_supported_system

    export DEBIAN_FRONTEND=noninteractive

    echo -e "\n${COLOR_BOLD}开始服务器初始化...${COLOR_RESET}\n" >&2
    run_step "01" "更新系统" step_01_update
    run_step "02" "安装必要软件" step_02_software
    run_step "03" "修改密码" step_03_password
    run_step "04" "修改主机名" step_04_hostname
    run_step "05" "修改 SSH 端口" step_05_ssh_port
    run_step "06" "启用 UFW 防火墙" step_06_ufw
    run_step "07" "添加 SSH 公钥" step_07_ssh_keys
    run_step "08" "配置 Profile" step_08_profile
    run_step "09" "安装哪吒探针" step_09_nezha
    run_step "10" "开启 BBR & FQ" step_10_bbr
    run_step "11" "禁用 IPv6" step_11_ipv6
    run_step "12" "运行 NodeQuality 测试" step_12_nodequality
    run_step "13" "配置 Swap & ZRam" step_13_swap_zram
    run_step "14" "安装 CrowdSec" step_14_crowdsec
    run_step "15" "安装 Docker" step_15_docker
    run_step "16" "配置 Vim" step_16_vim

    echo -e "\n${COLOR_SUCCESS}${COLOR_BOLD}========================================${COLOR_RESET}" >&2
    echo -e "${COLOR_SUCCESS}${COLOR_BOLD}  所有步骤执行完毕！${COLOR_RESET}" >&2
    echo -e "${COLOR_SUCCESS}${COLOR_BOLD}========================================${COLOR_RESET}\n" >&2
}

main "$@"
