#!/usr/bin/env bash
# =============================================================================
# Server bootstrap
# Usage: sudo ./bootstrap.sh [--config FILE] [--yes] [--resume]
# =============================================================================

set -Euo pipefail

SCRIPT_VERSION="3.1.0"
BACKUP_DIR="/var/backups/bootstrap"
DEFAULT_STATE_FILE="/var/lib/bootstrap/state"
DEFAULT_LOG_FILE="/var/log/bootstrap/bootstrap.log"
MAX_STEP=17
AUTO_YES=0
DRY_RUN=0
VERBOSE=0
CONFIG_FILE=""
ONLY_STEPS=""
SKIP_STEPS=""
ONLY_STEPS_SET=0
SKIP_STEPS_SET=0
RESUME=0
RESET_STATE=0
SHOW_STATUS=0
LIST_STEPS=0
UI_LANG=en
STATE_FILE="$DEFAULT_STATE_FILE"
LOG_FILE="$DEFAULT_LOG_FILE"
STATE_ENABLED=0
LOG_READY=0
RUN_STATUS=""
RUN_FINGERPRINT=""
STATE_FINGERPRINT=""
STATE_SCRIPT_VERSION=""
STATE_ONLY_STEPS=""
STATE_SKIP_STEPS=""
STATE_LOG_FILE=""
STATE_LAYOUT_MIGRATED=0
RUN_STARTED_AT=""
COMPLETED_STEPS=""
CURRENT_STEP=""
FAILED_STEP=""

CLI_HOSTNAME=""
CLI_TIMEZONE=""
CLI_SSH_PORT=""
CLI_NETWORK_PROFILE=""
CLI_SWAP_SIZE=""
CLI_ZRAM_PERCENT=""

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

# Keep both languages inline so downloading this script is sufficient.
msg() {
    if [[ "$UI_LANG" == "zh" ]]; then
        printf '%s' "$2"
    else
        printf '%s' "$1"
    fi
}

# Resolve the language before help or argument errors, regardless of option order.
# Skip values of other options so they cannot be mistaken for language switches.
select_language() {
    local language="${BOOTSTRAP_LANG:-en}"
    [[ "$language" == "zh" ]] && UI_LANG=zh
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --lang)
                shift
                require_option_value "--lang" "${1:-}"
                language="$1"
                ;;
            --lang=*)
                language="${1#--lang=}"
                ;;
            --config | --state-file | --log-file | --only | --skip | \
                --hostname | --timezone | --ssh-port | --network-profile | \
                --swap-size | --zram-percent)
                [[ $# -gt 1 && "$2" != --* ]] && shift
                ;;
        esac
        case "$language" in
            en | zh) UI_LANG="$language" ;;
        esac
        shift
    done
    case "$language" in
        en | zh) UI_LANG="$language" ;;
        *)
            error "$(msg "Unsupported language: $language (use en or zh)" "不支持的语言: ${language}（请使用 en 或 zh）")"
            exit 1
            ;;
    esac
}

usage() {
    if [[ "$UI_LANG" == "en" ]]; then
        cat <<'EOF'
Usage: sudo ./bootstrap.sh [OPTIONS]

Options:
  --lang en|zh              Output language (default: en; overrides BOOTSTRAP_LANG)
  --config FILE             Read a configuration file
  --yes, --all              Run noninteractively; skip steps missing required input
  --dry-run                 Preview only; no root required and no state written
  --resume                  Resume after a failure or interruption
  --status                  Show checkpoint status
  --reset-state             Discard unfinished progress and start a new run
  --state-file FILE         Checkpoint path (default: /var/lib/bootstrap/state)
  --log-file FILE           Log path (default: /var/log/bootstrap/bootstrap.log)
  --only 05,06              Run only the selected steps
  --skip 11,17              Skip the selected steps
  --hostname NAME           Override the configured hostname
  --timezone ZONE           Override the configured time zone
  --ssh-port PORT           Override the configured SSH port
  --network-profile PROFILE minimal / standard / low-memory
  --swap-size SIZE          Override swap size, e.g. 2G; none skips configuration
  --zram-percent PERCENT    Override the ZRam percentage
  --verbose                 Also display full command output in the terminal
  --list-steps              List available steps
  -h, --help                Show this help
EOF
    else
        cat <<'EOF'
用法: sudo ./bootstrap.sh [选项]

选项:
  --lang en|zh              输出语言（默认 en；覆盖 BOOTSTRAP_LANG 环境变量）
  --config FILE             读取配置文件
  --yes, --all              非交互执行；缺少必要输入的步骤会安全跳过
  --dry-run                 只预览，不要求 root、不写状态
  --resume                  从上次失败或中断的位置继续
  --status                  查看检查点状态
  --reset-state             忽略未完成的旧检查点并开始新一轮
  --state-file FILE         检查点路径（默认 /var/lib/bootstrap/state）
  --log-file FILE           日志路径（默认 /var/log/bootstrap/bootstrap.log）
  --only 05,06              只执行指定步骤
  --skip 11,17              跳过指定步骤
  --hostname NAME           覆盖配置中的主机名
  --timezone ZONE           覆盖配置中的时区
  --ssh-port PORT           覆盖配置中的 SSH 端口
  --network-profile PROFILE minimal / standard / low-memory
  --swap-size SIZE          覆盖 Swap 大小，例如 2G；none 表示不配置
  --zram-percent PERCENT    覆盖 ZRam 百分比
  --verbose                 同时在终端显示完整命令输出
  --list-steps              列出步骤
  -h, --help                显示帮助
EOF
    fi
}

require_option_value() {
    local option="$1"
    local value="${2:-}"
    if [[ -z "$value" || "$value" == --* ]]; then
        error "$(msg "$option requires a value" "$option 需要一个值")"
        exit 1
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --lang)
                shift
                require_option_value "--lang" "${1:-}"
                ;;
            --lang=*)
                ;;
            --yes | --all)
                AUTO_YES=1
                ;;
            --dry-run)
                DRY_RUN=1
                ;;
            --resume)
                RESUME=1
                ;;
            --status)
                SHOW_STATUS=1
                ;;
            --reset-state)
                RESET_STATE=1
                ;;
            --verbose)
                VERBOSE=1
                ;;
            --list-steps)
                LIST_STEPS=1
                ;;
            --only)
                shift
                require_option_value "--only" "${1:-}"
                ONLY_STEPS="${1:-}"
                ONLY_STEPS_SET=1
                ;;
            --skip)
                shift
                require_option_value "--skip" "${1:-}"
                SKIP_STEPS="${1:-}"
                SKIP_STEPS_SET=1
                ;;
            --config)
                shift
                require_option_value "--config" "${1:-}"
                CONFIG_FILE="${1:-}"
                ;;
            --state-file)
                shift
                require_option_value "--state-file" "${1:-}"
                STATE_FILE="${1:-}"
                ;;
            --log-file)
                shift
                require_option_value "--log-file" "${1:-}"
                LOG_FILE="${1:-}"
                ;;
            --hostname)
                shift
                require_option_value "--hostname" "${1:-}"
                CLI_HOSTNAME="${1:-}"
                ;;
            --timezone)
                shift
                require_option_value "--timezone" "${1:-}"
                CLI_TIMEZONE="${1:-}"
                ;;
            --ssh-port)
                shift
                require_option_value "--ssh-port" "${1:-}"
                CLI_SSH_PORT="${1:-}"
                ;;
            --network-profile)
                shift
                require_option_value "--network-profile" "${1:-}"
                CLI_NETWORK_PROFILE="${1:-}"
                ;;
            --swap-size)
                shift
                require_option_value "--swap-size" "${1:-}"
                CLI_SWAP_SIZE="${1:-}"
                ;;
            --zram-percent)
                shift
                require_option_value "--zram-percent" "${1:-}"
                CLI_ZRAM_PERCENT="${1:-}"
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            *)
                error "$(msg "Unknown option: $1" "未知参数: $1")"
                usage
                exit 1
                ;;
        esac
        shift
    done
}

set_defaults() {
    : "${BOOTSTRAP_HOSTNAME:=}"
    : "${BOOTSTRAP_TIMEZONE:=UTC}"
    : "${BOOTSTRAP_SSH_PORT:=}"
    : "${BOOTSTRAP_OLD_SSH_PORT:=22}"
    : "${BOOTSTRAP_KEEP_OLD_SSH_PORT:=false}"
    : "${BOOTSTRAP_NEZHA_SERVER:=}"
    : "${BOOTSTRAP_NEZHA_TLS:=false}"
    : "${BOOTSTRAP_NEZHA_SECRET:=}"
    : "${BOOTSTRAP_SSH_PUBLIC_KEY:=}"
    : "${BOOTSTRAP_SSH_PUBLIC_KEY_FILE:=}"
    : "${BOOTSTRAP_SWAP_SIZE:=1G}"
    : "${BOOTSTRAP_ZRAM_PERCENT:=25}"
    : "${BOOTSTRAP_ZRAM_ALGO:=lz4}"
    : "${BOOTSTRAP_SWAP_PRIORITY:=10}"
    : "${BOOTSTRAP_ZRAM_PRIORITY:=100}"
    : "${BOOTSTRAP_SWAPPINESS:=40}"
    : "${BOOTSTRAP_VFS_CACHE_PRESSURE:=100}"
    : "${BOOTSTRAP_NETWORK_PROFILE:=minimal}"
    : "${BOOTSTRAP_ONLY_STEPS:=}"
    : "${BOOTSTRAP_SKIP_STEPS:=}"
    : "${BOOTSTRAP_NODEQUALITY_URL:=https://run.NodeQuality.com}"
    : "${BOOTSTRAP_NEZHA_INSTALLER_URL:=https://raw.githubusercontent.com/nezhahq/scripts/main/agent/install.sh}"
}

apply_cli_overrides() {
    [[ -n "$CLI_HOSTNAME" ]] && BOOTSTRAP_HOSTNAME="$CLI_HOSTNAME"
    [[ -n "$CLI_TIMEZONE" ]] && BOOTSTRAP_TIMEZONE="$CLI_TIMEZONE"
    [[ -n "$CLI_SSH_PORT" ]] && BOOTSTRAP_SSH_PORT="$CLI_SSH_PORT"
    [[ -n "$CLI_NETWORK_PROFILE" ]] && BOOTSTRAP_NETWORK_PROFILE="$CLI_NETWORK_PROFILE"
    [[ -n "$CLI_SWAP_SIZE" ]] && BOOTSTRAP_SWAP_SIZE="$CLI_SWAP_SIZE"
    [[ -n "$CLI_ZRAM_PERCENT" ]] && BOOTSTRAP_ZRAM_PERCENT="$CLI_ZRAM_PERCENT"

    if [[ "$ONLY_STEPS_SET" -eq 0 ]]; then
        ONLY_STEPS="$BOOTSTRAP_ONLY_STEPS"
    fi
    if [[ "$SKIP_STEPS_SET" -eq 0 ]]; then
        SKIP_STEPS="$BOOTSTRAP_SKIP_STEPS"
    fi
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
            BOOTSTRAP_TIMEZONE | \
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
            BOOTSTRAP_ZRAM_ALGO | \
            BOOTSTRAP_SWAP_PRIORITY | \
            BOOTSTRAP_ZRAM_PRIORITY | \
            BOOTSTRAP_SWAPPINESS | \
            BOOTSTRAP_VFS_CACHE_PRESSURE | \
            BOOTSTRAP_NETWORK_PROFILE | \
            BOOTSTRAP_ONLY_STEPS | \
            BOOTSTRAP_SKIP_STEPS)
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
        error "$(msg "Cannot read configuration file: $CONFIG_FILE" "配置文件不可读: $CONFIG_FILE")"
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
            error "$(msg "Unsupported format on configuration line $line_no; expected BOOTSTRAP_KEY=value" "配置文件第 $line_no 行格式不支持，只允许 BOOTSTRAP_KEY=value")"
            exit 1
        fi
        key="${BASH_REMATCH[1]}"
        value="$(trim "${BASH_REMATCH[2]}")"
        value="$(strip_optional_quotes "$value")"
        if ! is_allowed_config_key "$key"; then
            error "$(msg "Unknown configuration key on line $line_no: $key" "配置文件第 $line_no 行包含未知配置项: $key")"
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
        error "$(msg "This script requires root privileges; use sudo" "此脚本必须以 root 权限运行，请使用 sudo")"
        exit 1
    fi
}

check_supported_system() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        return 0
    fi
    if ! command -v apt-get >/dev/null 2>&1; then
        error "$(msg "apt-get was not found; this script supports Debian/Ubuntu only" "未找到 apt-get；此脚本仅支持 Debian/Ubuntu 系统")"
        exit 1
    fi
    if ! command -v systemctl >/dev/null 2>&1; then
        error "$(msg "systemctl was not found; this script requires systemd" "未找到 systemctl；此脚本需要 systemd 环境")"
        exit 1
    fi
    parse_os_release
    case "$OS_ID" in
        debian | ubuntu) ;;
        *)
            error "$(msg "This system is not Debian/Ubuntu: ${OS_ID:-unknown}" "当前系统不是 Debian/Ubuntu: ${OS_ID:-unknown}")"
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
    echo "$(msg "              Server bootstrap v${SCRIPT_VERSION}" "              通用服务器初始化脚本 v${SCRIPT_VERSION}")"
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

timestamp_utc() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

log_event() {
    [[ "$LOG_READY" -eq 1 ]] || return 0
    printf "[%s] %s\n" "$(timestamp_utc)" "$*" >>"$LOG_FILE"
}

setup_log() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        return 0
    fi
    ensure_dir "$(dirname "$LOG_FILE")" 0755 || return 1
    touch "$LOG_FILE" || return 1
    chmod 0600 "$LOG_FILE" || return 1
    LOG_READY=1
    {
        printf "\n[%s] ===== bootstrap v%s %s =====\n" "$(timestamp_utc)" "$SCRIPT_VERSION" "$(msg started 开始)"
        printf "state_file=%s\n" "$STATE_FILE"
    } >>"$LOG_FILE"
}

show_command_failure() {
    local description="$1"
    local status="$2"
    error "$(msg "${description} failed (exit code ${status})" "${description} 失败（退出码 ${status}）")"
    if [[ "$LOG_READY" -eq 1 ]]; then
        warn "$(msg "Full output: $LOG_FILE" "完整输出: $LOG_FILE")"
        if [[ "$VERBOSE" -eq 0 ]]; then
            echo "$(msg "----- Recent log output -----" "----- 最近日志 -----")" >&2
            tail -n 12 "$LOG_FILE" >&2 || true
            echo "--------------------" >&2
        fi
    fi
}

run_cmd() {
    local description="$1"
    local ret
    shift
    info "$description..."
    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "[dry-run] $(quote_cmd "$@")"
        return 0
    fi
    log_event "RUN $description: $(quote_cmd "$@")"
    if [[ "$VERBOSE" -eq 1 ]]; then
        "$@" 2>&1 | tee -a "$LOG_FILE"
        ret=${PIPESTATUS[0]}
    else
        "$@" >>"$LOG_FILE" 2>&1
        ret=$?
    fi
    if [[ "$ret" -ne 0 ]]; then
        log_event "FAIL ($ret) $description"
        show_command_failure "$description" "$ret"
        return "$ret"
    fi
    log_event "OK $description"
    return 0
}

run_interactive_cmd() {
    local description="$1"
    local ret
    shift
    info "$description..."
    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "[dry-run] $(quote_cmd "$@")"
        return 0
    fi
    log_event "RUN interactive $description"
    "$@"
    ret=$?
    if [[ "$ret" -ne 0 ]]; then
        log_event "FAIL ($ret) $description"
        error "$(msg "${description} failed (exit code ${ret})" "${description} 失败（退出码 ${ret}）")"
        return "$ret"
    fi
    log_event "OK $description"
}

confirm() {
    local msg="$1"
    local answer
    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "$(msg "[dry-run] Automatically confirming: $msg" "[dry-run] 自动确认: $msg")"
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
        info "$(msg "[dry-run] Would ask: $description${default:+, default: $default}" "[dry-run] 将询问: $description${default:+，默认值: $default}")"
        echo "$default"
        return 0
    fi
    if [[ "$AUTO_YES" -eq 1 ]]; then
        echo "$default"
        return 0
    fi
    echo -ne "${COLOR_BOLD}  $description${COLOR_RESET}" >&2
    if [[ -n "$default" ]]; then
        echo -ne "$(msg "\n  (Press Enter for the default: $default, or n to skip): " "\n  (直接回车使用默认值: $default, 输入 n 跳过): ")" >&2
    else
        echo -ne "$(msg "\n  (Press Enter to skip): " "\n  (直接回车跳过): ")" >&2
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
        info "$(msg "[dry-run] Would ask for a secret: $description" "[dry-run] 将询问敏感值: $description")"
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
    echo -ne "$(msg "${COLOR_BOLD}  $description${COLOR_RESET}\n  (Input is hidden; press Enter to skip): " "${COLOR_BOLD}  $description${COLOR_RESET}\n  (输入内容不会显示，直接回车跳过): ")" >&2
    read -r -s input </dev/tty
    echo "" >&2
    echo "$input"
}

validate_port() {
    local port="$1"
    local number
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    ((${#port} <= 5)) || return 1
    number=$((10#$port))
    ((number >= 1 && number <= 65535))
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
    [[ "$value" == "none" ]] && return 0
    [[ "$value" =~ ^[1-9][0-9]*[mMgG]$ ]] && ((${#value} <= 8))
}

validate_percent() {
    local value="$1"
    local number
    [[ "$value" =~ ^[0-9]+$ ]] || return 1
    ((${#value} <= 3)) || return 1
    number=$((10#$value))
    ((number >= 0 && number <= 100))
}

validate_zram_algo() {
    local value="$1"
    [[ "$value" == "lz4" || "$value" == "lzo" || "$value" == "zstd" ]]
}

validate_integer_range() {
    local value="$1"
    local minimum="$2"
    local maximum="$3"
    local number
    [[ "$value" =~ ^[0-9]+$ ]] || return 1
    ((${#value} <= 10)) || return 1
    number=$((10#$value))
    ((number >= minimum && number <= maximum))
}

validate_network_profile() {
    local value="$1"
    [[ "$value" == "minimal" || "$value" == "standard" || "$value" == "low-memory" ]]
}

validate_absolute_path() {
    local value="$1"
    [[ "$value" == /* && "$value" != *$'\n'* && "$value" != *$'\r'* ]]
}

validate_host_port() {
    local value="$1"
    [[ "$value" =~ ^[^[:space:]:]+:[0-9]+$ ]] && validate_port "${value##*:}"
}

validate_timezone() {
    local timezone="$1"
    [[ -n "$timezone" ]] || return 1
    [[ "$timezone" != /* && "$timezone" != *..* ]] || return 1
    [[ "$timezone" =~ ^[A-Za-z0-9._+-]+(/[A-Za-z0-9._+-]+)*$ ]] || return 1

    if [[ "$DRY_RUN" -eq 1 ]]; then
        return 0
    fi
    if command -v timedatectl >/dev/null 2>&1; then
        timedatectl list-timezones 2>/dev/null | grep -Fx "$timezone" >/dev/null 2>&1 && return 0
    fi
    [[ -f "/usr/share/zoneinfo/$timezone" ]]
}

validate_runtime_options() {
    if [[ "$RESUME" -eq 1 && "$RESET_STATE" -eq 1 ]]; then
        error "$(msg "--resume and --reset-state cannot be used together" "--resume 与 --reset-state 不能同时使用")"
        exit 1
    fi
    if [[ "$DRY_RUN" -eq 1 && "$RESUME" -eq 1 ]]; then
        error "$(msg "--dry-run does not load resume state; remove --resume" "--dry-run 不读取续跑状态；请移除 --resume")"
        exit 1
    fi
    if [[ "$DRY_RUN" -eq 1 && "$RESET_STATE" -eq 1 ]]; then
        error "$(msg "--dry-run does not write state; remove --reset-state" "--dry-run 不写状态；请移除 --reset-state")"
        exit 1
    fi
    if [[ "$SHOW_STATUS" -eq 1 && ( "$RESUME" -eq 1 || "$RESET_STATE" -eq 1 || "$DRY_RUN" -eq 1 ) ]]; then
        error "$(msg "--status cannot be combined with --resume, --reset-state, or --dry-run" "--status 不能与 --resume、--reset-state 或 --dry-run 同时使用")"
        exit 1
    fi
    if ! validate_absolute_path "$STATE_FILE"; then
        error "$(msg "--state-file must be an absolute path without newlines: $STATE_FILE" "--state-file 必须是无换行的绝对路径: $STATE_FILE")"
        exit 1
    fi
    if ! validate_absolute_path "$LOG_FILE"; then
        error "$(msg "--log-file must be an absolute path without newlines: $LOG_FILE" "--log-file 必须是无换行的绝对路径: $LOG_FILE")"
        exit 1
    fi
}

validate_config_values() {
    if [[ -n "$BOOTSTRAP_HOSTNAME" ]] && ! validate_hostname "$BOOTSTRAP_HOSTNAME"; then
        error "$(msg "Invalid BOOTSTRAP_HOSTNAME: $BOOTSTRAP_HOSTNAME" "BOOTSTRAP_HOSTNAME 不合法: $BOOTSTRAP_HOSTNAME")"
        exit 1
    fi
    if ! validate_timezone "$BOOTSTRAP_TIMEZONE"; then
        error "$(msg "Invalid or unsupported BOOTSTRAP_TIMEZONE: $BOOTSTRAP_TIMEZONE" "BOOTSTRAP_TIMEZONE 不合法或系统不支持: $BOOTSTRAP_TIMEZONE")"
        exit 1
    fi
    if [[ -n "$BOOTSTRAP_SSH_PORT" ]] && ! validate_port "$BOOTSTRAP_SSH_PORT"; then
        error "$(msg "Invalid BOOTSTRAP_SSH_PORT: $BOOTSTRAP_SSH_PORT" "BOOTSTRAP_SSH_PORT 不合法: $BOOTSTRAP_SSH_PORT")"
        exit 1
    fi
    if ! validate_port "$BOOTSTRAP_OLD_SSH_PORT"; then
        error "$(msg "Invalid BOOTSTRAP_OLD_SSH_PORT: $BOOTSTRAP_OLD_SSH_PORT" "BOOTSTRAP_OLD_SSH_PORT 不合法: $BOOTSTRAP_OLD_SSH_PORT")"
        exit 1
    fi
    if ! validate_bool "$BOOTSTRAP_KEEP_OLD_SSH_PORT" || ! validate_bool "$BOOTSTRAP_NEZHA_TLS"; then
        error "$(msg "BOOTSTRAP_KEEP_OLD_SSH_PORT and BOOTSTRAP_NEZHA_TLS must be true or false" "BOOTSTRAP_KEEP_OLD_SSH_PORT 和 BOOTSTRAP_NEZHA_TLS 只能是 true 或 false")"
        exit 1
    fi
    if [[ -n "$BOOTSTRAP_NEZHA_SERVER" ]] && ! validate_host_port "$BOOTSTRAP_NEZHA_SERVER"; then
        error "$(msg "BOOTSTRAP_NEZHA_SERVER must use host:port format" "BOOTSTRAP_NEZHA_SERVER 必须使用 host:port 格式")"
        exit 1
    fi
    if ! validate_swap_size "$BOOTSTRAP_SWAP_SIZE"; then
        error "$(msg "BOOTSTRAP_SWAP_SIZE must be a size such as 1G or 512M, or none" "BOOTSTRAP_SWAP_SIZE 必须是 1G、512M 这类大小，或 none")"
        exit 1
    fi
    if ! validate_percent "$BOOTSTRAP_ZRAM_PERCENT"; then
        error "$(msg "BOOTSTRAP_ZRAM_PERCENT must be an integer from 0 to 100" "BOOTSTRAP_ZRAM_PERCENT 必须是 0-100 的整数")"
        exit 1
    fi
    if ! validate_zram_algo "$BOOTSTRAP_ZRAM_ALGO"; then
        error "$(msg "BOOTSTRAP_ZRAM_ALGO must be lz4, lzo, or zstd" "BOOTSTRAP_ZRAM_ALGO 仅支持 lz4、lzo、zstd")"
        exit 1
    fi
    if ! validate_integer_range "$BOOTSTRAP_SWAP_PRIORITY" 0 32767 || \
        ! validate_integer_range "$BOOTSTRAP_ZRAM_PRIORITY" 0 32767; then
        error "$(msg "Swap/ZRam priorities must be integers from 0 to 32767" "Swap/ZRam 优先级必须是 0-32767 的整数")"
        exit 1
    fi
    if ! validate_integer_range "$BOOTSTRAP_SWAPPINESS" 0 200; then
        error "$(msg "BOOTSTRAP_SWAPPINESS must be an integer from 0 to 200" "BOOTSTRAP_SWAPPINESS 必须是 0-200 的整数")"
        exit 1
    fi
    if ! validate_integer_range "$BOOTSTRAP_VFS_CACHE_PRESSURE" 0 1000; then
        error "$(msg "BOOTSTRAP_VFS_CACHE_PRESSURE must be an integer from 0 to 1000" "BOOTSTRAP_VFS_CACHE_PRESSURE 必须是 0-1000 的整数")"
        exit 1
    fi
    if ! validate_network_profile "$BOOTSTRAP_NETWORK_PROFILE"; then
        error "$(msg "BOOTSTRAP_NETWORK_PROFILE must be minimal, standard, or low-memory" "BOOTSTRAP_NETWORK_PROFILE 仅支持 minimal、standard、low-memory")"
        exit 1
    fi
    if [[ -n "${BOOTSTRAP_SSH_PUBLIC_KEY:-}" && -n "${BOOTSTRAP_SSH_PUBLIC_KEY_FILE:-}" ]]; then
        error "$(msg "Set either BOOTSTRAP_SSH_PUBLIC_KEY or BOOTSTRAP_SSH_PUBLIC_KEY_FILE, not both" "BOOTSTRAP_SSH_PUBLIC_KEY 与 BOOTSTRAP_SSH_PUBLIC_KEY_FILE 只能设置一个")"
        exit 1
    fi
    if [[ -n "${BOOTSTRAP_SSH_PUBLIC_KEY_FILE:-}" && ! -r "$BOOTSTRAP_SSH_PUBLIC_KEY_FILE" ]]; then
        error "$(msg "Cannot read SSH public-key file: $BOOTSTRAP_SSH_PUBLIC_KEY_FILE" "SSH 公钥文件不可读: $BOOTSTRAP_SSH_PUBLIC_KEY_FILE")"
        exit 1
    fi
}

package_is_installed() {
    local package="$1"
    local status
    command -v dpkg-query >/dev/null 2>&1 || return 1
    status="$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true)"
    [[ "$status" == "install ok installed" ]]
}

installed_external_time_sync_packages() {
    local package installed=""
    local -a packages=(
        chrony
        ntpsec
        openntpd
        ntp
    )

    for package in "${packages[@]}"; do
        if package_is_installed "$package"; then
            installed="${installed:+$installed, }$package"
        fi
    done
    printf "%s" "$installed"
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
    backup="$BACKUP_DIR/$(basename "$file").$(date +%Y%m%d-%H%M%S).$$.$RANDOM"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "$(msg "[dry-run] Back up $file to $backup" "[dry-run] 备份 $file 到 $backup")"
        echo "$backup"
        return 0
    fi
    install -d -m 0700 "$BACKUP_DIR" || return 1
    cp -a "$file" "$backup" || return 1
    echo "$backup"
}

restore_file_from_backup() {
    local target="$1"
    local backup="$2"
    if [[ -n "$backup" && -f "$backup" ]]; then
        cp -a "$backup" "$target" && return 0
        warn "$(msg "Cannot restore ${target} from backup; check manually: $backup" "无法从备份恢复 ${target}，请手动检查: $backup")"
        return 1
    else
        rm -f "$target" && return 0
        warn "$(msg "Cannot remove ${target}; check manually" "无法移除 ${target}，请手动检查")"
        return 1
    fi
}

download_file() {
    local url="$1"
    local output="$2"
    if [[ ! "$url" =~ ^https:// ]]; then
        error "$(msg "Downloads require HTTPS: $url" "仅允许通过 HTTPS 下载: $url")"
        return 1
    fi
    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "$(msg "[dry-run] Download $url to $output" "[dry-run] 下载 $url 到 $output")"
        return 0
    fi
    curl --fail --location --silent --show-error --retry 3 --proto '=https' --tlsv1.2 \
        --output "$output" "$url"
}

contains_step() {
    local list="$1"
    local step="$2"
    local item
    local -a items=()
    [[ -z "$list" ]] && return 1
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
    local max_step_padded
    local item number
    local -a items
    printf -v max_step_padded "%02d" "$MAX_STEP"
    [[ -z "$list" ]] && return 0
    IFS=',' read -r -a items <<<"$list"
    for item in "${items[@]}"; do
        item="${item//[[:space:]]/}"
        if [[ -z "$item" ]]; then
            error "$(msg "$option_name contains an empty step" "$option_name 包含空步骤")"
            exit 1
        fi
        if [[ ! "$item" =~ ^[0-9]+$ ]]; then
            error "$(msg "$option_name contains an invalid step: $item" "$option_name 包含非法步骤: $item")"
            exit 1
        fi
        number=$((10#$item))
        if ((number < 1 || number > MAX_STEP)); then
            error "$(msg "$option_name requires steps from 01 to ${max_step_padded}: $item" "$option_name 只能指定 01-${max_step_padded} 之间的步骤: $item")"
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

step_name() {
    case "$1" in
        01) msg "Update the system" "更新系统" ;;
        02) msg "Install essential tools" "安装基础工具" ;;
        03) msg "Change the root password" "修改 root 密码" ;;
        04) msg "Set the hostname" "修改主机名" ;;
        05) msg "Change the SSH port" "修改 SSH 端口" ;;
        06) msg "Enable the UFW firewall" "启用 UFW 防火墙" ;;
        07) msg "Add SSH public keys" "添加 SSH 公钥" ;;
        08) msg "Configure the shell profile" "配置 Profile" ;;
        09) msg "Install the Nezha agent" "安装哪吒探针" ;;
        10) msg "Configure network settings" "配置网络参数" ;;
        11) msg "Disable IPv6 (including UFW)" "禁用 IPv6（含 UFW）" ;;
        12) msg "Configure Swap and ZRam" "配置 Swap 与 ZRam" ;;
        13) msg "Install CrowdSec" "安装 CrowdSec" ;;
        14) msg "Install Docker" "安装 Docker" ;;
        15) msg "Configure Vim" "配置 Vim" ;;
        16) msg "Configure time synchronization" "配置时间同步" ;;
        17) msg "Run NodeQuality" "运行 NodeQuality" ;;
        *) msg "Unknown step" "未知步骤" ;;
    esac
}

list_steps() {
    local number=1 step
    while ((number <= MAX_STEP)); do
        printf -v step "%02d" "$number"
        printf "%s  %s\n" "$step" "$(step_name "$step")"
        number=$((number + 1))
    done
}

hash_stdin() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 | awk '{print $1}'
    else
        error "$(msg "sha256sum or shasum is required to fingerprint the resume configuration" "缺少 sha256sum 或 shasum，无法生成续跑配置指纹")"
        return 1
    fi
}

file_fingerprint() {
    local path="$1"
    if [[ -z "$path" ]]; then
        echo ""
    elif [[ -r "$path" ]]; then
        hash_stdin <"$path"
    else
        echo "unreadable"
    fi
}

configuration_fingerprint() {
    local public_key_file_hash
    public_key_file_hash="$(file_fingerprint "${BOOTSTRAP_SSH_PUBLIC_KEY_FILE:-}")" || return 1
    {
        printf "script_version=%s\n" "$SCRIPT_VERSION"
        printf "only=%s\n" "$ONLY_STEPS"
        printf "skip=%s\n" "$SKIP_STEPS"
        printf "hostname=%s\n" "$BOOTSTRAP_HOSTNAME"
        printf "timezone=%s\n" "$BOOTSTRAP_TIMEZONE"
        printf "ssh_port=%s\n" "$BOOTSTRAP_SSH_PORT"
        printf "old_ssh_port=%s\n" "$BOOTSTRAP_OLD_SSH_PORT"
        printf "keep_old_ssh_port=%s\n" "$BOOTSTRAP_KEEP_OLD_SSH_PORT"
        printf "nezha_server=%s\n" "$BOOTSTRAP_NEZHA_SERVER"
        printf "nezha_tls=%s\n" "$BOOTSTRAP_NEZHA_TLS"
        printf "nezha_secret=%s\n" "${BOOTSTRAP_NEZHA_SECRET:-}"
        printf "nezha_installer=%s\n" "$BOOTSTRAP_NEZHA_INSTALLER_URL"
        printf "nodequality_url=%s\n" "$BOOTSTRAP_NODEQUALITY_URL"
        printf "ssh_public_key=%s\n" "${BOOTSTRAP_SSH_PUBLIC_KEY:-}"
        printf "ssh_public_key_file=%s\n" "${BOOTSTRAP_SSH_PUBLIC_KEY_FILE:-}"
        printf "ssh_public_key_file_hash=%s\n" "$public_key_file_hash"
        printf "swap_size=%s\n" "$BOOTSTRAP_SWAP_SIZE"
        printf "zram_percent=%s\n" "$BOOTSTRAP_ZRAM_PERCENT"
        printf "zram_algo=%s\n" "$BOOTSTRAP_ZRAM_ALGO"
        printf "swap_priority=%s\n" "$BOOTSTRAP_SWAP_PRIORITY"
        printf "zram_priority=%s\n" "$BOOTSTRAP_ZRAM_PRIORITY"
        printf "swappiness=%s\n" "$BOOTSTRAP_SWAPPINESS"
        printf "vfs_cache_pressure=%s\n" "$BOOTSTRAP_VFS_CACHE_PRESSURE"
        printf "network_profile=%s\n" "$BOOTSTRAP_NETWORK_PROFILE"
    } | hash_stdin
}

state_uses_legacy_step_layout() {
    case "$STATE_SCRIPT_VERSION" in
        3.0.0 | 3.0.1 | 3.0.2) return 0 ;;
        *) return 1 ;;
    esac
}

map_legacy_step() {
    local raw_step="$1"
    local number
    [[ "$raw_step" =~ ^[0-9]+$ ]] || return 1
    number=$((10#$raw_step))
    case "$number" in
        12) number=17 ;;
        13) number=12 ;;
        14) number=13 ;;
        15) number=14 ;;
        16) number=15 ;;
        17) number=16 ;;
    esac
    printf "%02d" "$number"
}

map_legacy_step_list() {
    local list="$1"
    local item mapped result=""
    local -a items=()
    [[ -z "$list" ]] && return 0
    IFS=',' read -r -a items <<<"$list"
    for item in "${items[@]}"; do
        item="${item//[[:space:]]/}"
        mapped="$(map_legacy_step "$item")" || return 1
        result="${result:+$result,}$mapped"
    done
    printf "%s" "$result"
}

remove_step_from_list() {
    local list="$1"
    local target="$2"
    local item result=""
    local -a items=()
    [[ -z "$list" ]] && return 0
    IFS=',' read -r -a items <<<"$list"
    for item in "${items[@]}"; do
        item="${item//[[:space:]]/}"
        if [[ "$item" != "$target" && "$item" != "${target#0}" ]]; then
            result="${result:+$result,}$item"
        fi
    done
    printf "%s" "$result"
}

migrate_loaded_state_steps() {
    state_uses_legacy_step_layout || return 0
    STATE_ONLY_STEPS="$(map_legacy_step_list "$STATE_ONLY_STEPS")" || return 1
    STATE_SKIP_STEPS="$(map_legacy_step_list "$STATE_SKIP_STEPS")" || return 1
    COMPLETED_STEPS="$(map_legacy_step_list "$COMPLETED_STEPS")" || return 1
    if [[ -n "$CURRENT_STEP" ]]; then
        CURRENT_STEP="$(map_legacy_step "$CURRENT_STEP")" || return 1
    fi
    if [[ -n "$FAILED_STEP" ]]; then
        FAILED_STEP="$(map_legacy_step "$FAILED_STEP")" || return 1
    fi
    if [[ "$RUN_STATUS" != "complete" ]] && contains_step "$COMPLETED_STEPS" "17"; then
        COMPLETED_STEPS="$(remove_step_from_list "$COMPLETED_STEPS" "17")" || return 1
        warn "$(msg "The old NodeQuality completion flag was reset; it will run again after the remaining configuration" "旧 NodeQuality 完成标记已重置，将在剩余配置完成后重新测试")"
    fi
    STATE_LAYOUT_MIGRATED=1
    warn "$(msg "Detected a v3.0.x checkpoint; step numbers were automatically migrated to v3.1" "检测到 v3.0.x 检查点，已将步骤编号自动迁移到 v3.1")"
}

write_state() {
    local tmp
    [[ "$STATE_ENABLED" -eq 1 ]] || return 0
    ensure_dir "$(dirname "$STATE_FILE")" 0755 || return 1
    tmp="$(mktemp "${STATE_FILE}.tmp.XXXXXX")" || return 1
    {
        printf "STATE_VERSION=1\n"
        printf "SCRIPT_VERSION=%s\n" "$SCRIPT_VERSION"
        printf "FINGERPRINT=%s\n" "$RUN_FINGERPRINT"
        printf "STARTED_AT=%s\n" "$RUN_STARTED_AT"
        printf "UPDATED_AT=%s\n" "$(timestamp_utc)"
        printf "STATUS=%s\n" "$RUN_STATUS"
        printf "ONLY_STEPS=%s\n" "$ONLY_STEPS"
        printf "SKIP_STEPS=%s\n" "$SKIP_STEPS"
        printf "COMPLETED_STEPS=%s\n" "$COMPLETED_STEPS"
        printf "CURRENT_STEP=%s\n" "$CURRENT_STEP"
        printf "FAILED_STEP=%s\n" "$FAILED_STEP"
        printf "LOG_FILE=%s\n" "$LOG_FILE"
    } >"$tmp" || {
        rm -f "$tmp"
        return 1
    }
    chmod 0600 "$tmp" || {
        rm -f "$tmp"
        return 1
    }
    mv "$tmp" "$STATE_FILE"
}

load_state() {
    local key value state_version="" stored_log_file=""
    [[ -r "$STATE_FILE" ]] || {
        error "$(msg "No readable checkpoint: $STATE_FILE" "没有可读取的检查点: $STATE_FILE")"
        return 1
    }

    STATE_FINGERPRINT=""
    STATE_SCRIPT_VERSION=""
    STATE_ONLY_STEPS=""
    STATE_SKIP_STEPS=""
    STATE_LAYOUT_MIGRATED=0
    RUN_STARTED_AT=""
    RUN_STATUS=""
    COMPLETED_STEPS=""
    CURRENT_STEP=""
    FAILED_STEP=""

    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        case "$key" in
            STATE_VERSION) state_version="$value" ;;
            SCRIPT_VERSION) STATE_SCRIPT_VERSION="$value" ;;
            FINGERPRINT) STATE_FINGERPRINT="$value" ;;
            STARTED_AT) RUN_STARTED_AT="$value" ;;
            STATUS) RUN_STATUS="$value" ;;
            ONLY_STEPS) STATE_ONLY_STEPS="$value" ;;
            SKIP_STEPS) STATE_SKIP_STEPS="$value" ;;
            COMPLETED_STEPS) COMPLETED_STEPS="$value" ;;
            CURRENT_STEP) CURRENT_STEP="$value" ;;
            FAILED_STEP) FAILED_STEP="$value" ;;
            LOG_FILE) stored_log_file="$value" ;;
        esac
    done <"$STATE_FILE"

    if [[ "$state_version" != "1" || -z "$STATE_SCRIPT_VERSION" || ! "$STATE_FINGERPRINT" =~ ^[0-9a-f]{64}$ ]]; then
        error "$(msg "Invalid checkpoint format: $STATE_FILE" "检查点格式无效: $STATE_FILE")"
        return 1
    fi
    STATE_LOG_FILE="$stored_log_file"
    migrate_loaded_state_steps || {
        error "$(msg "Failed to migrate legacy checkpoint step numbers: $STATE_FILE" "旧检查点步骤编号迁移失败: $STATE_FILE")"
        return 1
    }
    return 0
}

initialize_state() {
    RUN_STARTED_AT="$(timestamp_utc)"
    RUN_STATUS="running"
    COMPLETED_STEPS=""
    CURRENT_STEP=""
    FAILED_STEP=""
    STATE_ONLY_STEPS="$ONLY_STEPS"
    STATE_SKIP_STEPS="$SKIP_STEPS"
    STATE_ENABLED=1
    write_state
}

prepare_state() {
    local current_fingerprint previous_status
    current_fingerprint="$(configuration_fingerprint)" || return 1

    if [[ "$RESUME" -eq 1 ]]; then
        load_state || return 1
        if [[ "$STATE_FINGERPRINT" != "$current_fingerprint" ]]; then
            warn "$(msg "The current configuration or script version differs from the checkpoint" "当前配置或脚本版本与检查点不同")"
            warn "$(msg "Completed steps will still be skipped; new settings affect only failed and pending steps, and the original step selection is retained" "已完成步骤仍会跳过；新配置只影响失败和待执行步骤，原步骤选择保持不变")"
        fi
        ONLY_STEPS="$STATE_ONLY_STEPS"
        SKIP_STEPS="$STATE_SKIP_STEPS"
        RUN_FINGERPRINT="$(configuration_fingerprint)" || return 1
        STATE_ENABLED=1
        if [[ "$RUN_STATUS" == "complete" ]]; then
            success "$(msg "The checkpoint shows this run is complete; nothing to resume" "检查点显示本轮已经完成，无需续跑")"
            return 2
        fi
        RUN_STATUS="running"
        CURRENT_STEP=""
        FAILED_STEP=""
        write_state || return 1
        return 0
    fi

    if [[ -e "$STATE_FILE" && "$RESET_STATE" -eq 0 ]]; then
        if load_state; then
            previous_status="$RUN_STATUS"
            if [[ "$previous_status" != "complete" ]]; then
                error "$(msg "Found an unfinished checkpoint (status: ${previous_status})" "发现未完成的检查点（状态: ${previous_status}）")"
                warn "$(msg "Use --resume to continue, or --reset-state to discard the previous progress" "继续执行请加 --resume；放弃旧进度请加 --reset-state")"
                return 1
            fi
        else
            warn "$(msg "The old checkpoint is corrupt; review it before overwriting with --reset-state" "旧检查点损坏；请确认后使用 --reset-state 覆盖")"
            return 1
        fi
    fi

    RUN_FINGERPRINT="$current_fingerprint"
    initialize_state
}

print_state_status() {
    local number=1 step label
    load_state || return 1
    printf "%s: %s\n" "$(msg Status 状态)" "$RUN_STATUS"
    printf "%s: %s\n" "$(msg Script 脚本)" "$STATE_SCRIPT_VERSION"
    printf "%s: %s\n" "$(msg Started 开始)" "$RUN_STARTED_AT"
    printf "%s: %s\n" "$(msg Log 日志)" "${STATE_LOG_FILE:-$LOG_FILE}"
    while ((number <= MAX_STEP)); do
        printf -v step "%02d" "$number"
        if contains_step "$COMPLETED_STEPS" "$step"; then
            label="$(msg "Completed" "完成")"
        elif [[ "$step" == "$FAILED_STEP" && "$RUN_STATUS" == "interrupted" ]]; then
            label="$(msg "Interrupted" "中断")"
        elif [[ "$step" == "$FAILED_STEP" ]]; then
            label="$(msg "Failed" "失败")"
        elif [[ "$step" == "$CURRENT_STEP" ]]; then
            label="$(msg "Interrupted" "中断")"
        elif [[ -n "$STATE_ONLY_STEPS" ]] && ! contains_step "$STATE_ONLY_STEPS" "$step"; then
            label="$(msg "Not selected" "未选择")"
        elif contains_step "$STATE_SKIP_STEPS" "$step"; then
            label="$(msg "Excluded" "已排除")"
        else
            label="$(msg "Pending" "待执行")"
        fi
        printf "%s  %-12s  %s\n" "$step" "$label" "$(step_name "$step")"
        number=$((number + 1))
    done
}

add_completed_step() {
    local step="$1"
    if ! contains_step "$COMPLETED_STEPS" "$step"; then
        COMPLETED_STEPS="${COMPLETED_STEPS:+$COMPLETED_STEPS,}$step"
    fi
}

handle_signal() {
    local signal_name="$1"
    local exit_code="$2"
    warn "$(msg "Received ${signal_name}; the checkpoint has been preserved" "收到 ${signal_name}，已保留检查点")"
    if [[ "$STATE_ENABLED" -eq 1 ]]; then
        RUN_STATUS="interrupted"
        FAILED_STEP="$CURRENT_STEP"
        write_state || true
    fi
    exit "$exit_code"
}

handle_exit() {
    local exit_code="$1"
    if [[ "$exit_code" -ne 0 && "$STATE_ENABLED" -eq 1 && "$RUN_STATUS" == "running" ]]; then
        RUN_STATUS="failed"
        FAILED_STEP="$CURRENT_STEP"
        write_state || true
    fi
}

install_state_traps() {
    trap 'handle_signal INT 130' INT
    trap 'handle_signal TERM 143' TERM
    trap 'handle_exit $?' EXIT
}

run_step() {
    local step_num="$1"
    local step_func="$2"
    local step_name ret
    step_name="$(step_name "$step_num")"

    if ! should_run_step "$step_num"; then
        warn "$(msg "Skipping step ${step_num}: ${step_name}" "跳过步骤 ${step_num}: ${step_name}")"
        return 0
    fi

    if [[ "$RESUME" -eq 1 ]] && contains_step "$COMPLETED_STEPS" "$step_num"; then
        success "$(msg "Step ${step_num} is already complete; skipping on resume: ${step_name}" "步骤 ${step_num} 已完成，续跑时跳过: ${step_name}")"
        return 0
    fi

    echo "" >&2
    echo -e "${COLOR_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${COLOR_RESET}" >&2
    echo -e "$(msg "${COLOR_BOLD}  Step ${step_num}: ${step_name}${COLOR_RESET}" "${COLOR_BOLD}  步骤 ${step_num}: ${step_name}${COLOR_RESET}")" >&2
    echo -e "${COLOR_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${COLOR_RESET}" >&2

    CURRENT_STEP="$step_num"
    FAILED_STEP=""
    RUN_STATUS="running"
    write_state || {
        error "$(msg "Cannot write the checkpoint; stopping" "无法写入检查点，停止执行")"
        exit 1
    }
    log_event "STEP $step_num START $step_name"

    "$step_func"
    ret=$?
    if [[ $ret -eq 0 ]]; then
        add_completed_step "$step_num"
        CURRENT_STEP=""
        write_state || {
            error "$(msg "The step succeeded but the checkpoint could not be updated; stopping" "步骤成功但无法更新检查点，停止执行")"
            exit 1
        }
        log_event "STEP $step_num OK $step_name"
        success "$(msg "Step ${step_num} completed" "步骤 ${step_num} 完成")"
    else
        RUN_STATUS="failed"
        FAILED_STEP="$step_num"
        write_state || true
        log_event "STEP $step_num FAIL ($ret) $step_name"
        error "$(msg "Step ${step_num} failed" "步骤 ${step_num} 执行失败")"
        warn "$(msg "Fix the problem, then use the same arguments with --resume to continue" "修复问题后使用相同参数加 --resume 继续")"
        exit "$ret"
    fi
}

apt_install() {
    run_cmd "$(msg "Install packages: $*" "安装软件包: $*")" apt-get install -y "$@"
}

write_file() {
    local path="$1"
    local mode="${2:-0644}"
    local content="$3"
    local tmp
    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "$(msg "[dry-run] Write $path" "[dry-run] 写入 $path")"
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
        info "$(msg "[dry-run] Update the bootstrap configuration block in $path" "[dry-run] 更新 $path 中的 bootstrap 配置块")"
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
        run_cmd "$(msg "UFW is active; allow the new SSH port $port/tcp first" "UFW 已启用，先开放 SSH 新端口 $port/tcp")" ufw allow "$port/tcp" || return 1
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
    if ! confirm "$(msg "Update the apt index and upgrade all installed packages" "更新 apt 索引并升级所有已安装软件包")"; then
        warn "$(msg "Skipping step 01" "跳过步骤 01")"
        return 0
    fi
    run_cmd "$(msg "Update the apt index" "更新 apt 索引")" apt-get update || return 1
    run_cmd "$(msg "Upgrade packages" "升级软件包")" apt-get upgrade -y || return 1
}

step_02_software() {
    if ! confirm "$(msg "Install essential tools: vim htop net-tools unzip curl wget" "安装必要软件: vim htop net-tools unzip curl wget")"; then
        warn "$(msg "Skipping step 02" "跳过步骤 02")"
        return 0
    fi
    apt_install vim htop net-tools unzip curl wget || return 1
}

step_03_password() {
    if ! confirm "$(msg "Change the root password" "修改 root 密码")"; then
        warn "$(msg "Skipping step 03" "跳过步骤 03")"
        return 0
    fi
    if [[ "$AUTO_YES" -eq 1 && "$DRY_RUN" -ne 1 ]]; then
        warn "$(msg "--yes does not change the root password; run this step interactively" "--yes 模式不会自动修改 root 密码，请交互执行此步骤")"
        return 0
    fi
    run_interactive_cmd "$(msg "Change the root password" "修改 root 密码")" passwd || return 1
}

step_04_hostname() {
    local new_hostname
    new_hostname="$(prompt_input "$(msg "New hostname (leave empty to skip)" "新主机名（留空跳过）")" "$BOOTSTRAP_HOSTNAME")"
    if [[ -z "$new_hostname" ]]; then
        warn "$(msg "No hostname provided; skipping step 04" "未输入主机名，跳过步骤 04")"
        return 0
    fi
    if ! validate_hostname "$new_hostname"; then
        error "$(msg "Invalid hostname: $new_hostname" "主机名不合法: $new_hostname")"
        return 1
    fi
    if ! confirm "$(msg "Set the hostname to '$new_hostname'" "将主机名设置为 '$new_hostname'")"; then
        warn "$(msg "Skipping step 04" "跳过步骤 04")"
        return 0
    fi
    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "[dry-run] hostnamectl set-hostname $new_hostname"
        return 0
    fi
    if [[ "$(hostname 2>/dev/null)" == "$new_hostname" ]]; then
        warn "$(msg "The hostname is already ${new_hostname}; skipping" "主机名已经是 ${new_hostname}，跳过")"
        return 0
    fi
    backup_file /etc/hostname >/dev/null || return 1
    run_cmd "$(msg "Set the hostname" "设置主机名")" hostnamectl set-hostname "$new_hostname" || return 1
}

timesyncd_config_for_timezone() {
    cat <<'TIMESYNCD_GLOBAL_EOF'
[Time]
NTP=0.debian.pool.ntp.org 1.debian.pool.ntp.org 2.debian.pool.ntp.org 3.debian.pool.ntp.org
FallbackNTP=0.pool.ntp.org 1.pool.ntp.org 2.pool.ntp.org 3.pool.ntp.org
TIMESYNCD_GLOBAL_EOF
}

step_16_timesync() {
    local timezone content installed_time_sync
    installed_time_sync="$(installed_external_time_sync_packages)"
    if [[ -n "$installed_time_sync" ]]; then
        warn "$(msg "Other time synchronization packages are installed (${installed_time_sync}); skipping systemd-timesyncd configuration" "已安装其他时间同步软件包（${installed_time_sync}），跳过 systemd-timesyncd 配置")"
        return 0
    fi

    timezone="$(prompt_input "$(msg "System time zone" "系统时区")" "$BOOTSTRAP_TIMEZONE")"
    if [[ -z "$timezone" ]]; then
        warn "$(msg "No time zone provided; skipping step 16" "未输入时区，跳过步骤 16")"
        return 0
    fi
    if ! validate_timezone "$timezone"; then
        error "$(msg "Invalid or unsupported time zone: $timezone" "时区不合法或系统不支持: $timezone")"
        return 1
    fi

    if ! confirm "$(msg "Set the time zone to ${timezone} and enable systemd-timesyncd (Debian/NTP Pool)" "配置时区为 ${timezone}，启用 systemd-timesyncd（Debian/NTP Pool）")"; then
        warn "$(msg "Skipping step 16" "跳过步骤 16")"
        return 0
    fi

    content="$(timesyncd_config_for_timezone "$timezone")"
    apt_install systemd-timesyncd || return 1
    backup_file /etc/systemd/timesyncd.conf.d/60-ntp.conf >/dev/null || return 1
    write_file /etc/systemd/timesyncd.conf.d/60-ntp.conf 0644 "$content" || return 1
    run_cmd "$(msg "Set the system time zone" "设置系统时区")" timedatectl set-timezone "$timezone" || return 1
    run_cmd "$(msg "Enable systemd-timesyncd" "启用 systemd-timesyncd")" systemctl enable --now systemd-timesyncd || return 1
    run_cmd "$(msg "Restart systemd-timesyncd" "重启 systemd-timesyncd")" systemctl restart systemd-timesyncd || return 1
    run_cmd "$(msg "Verify the systemd-timesyncd service" "验证 systemd-timesyncd 服务")" systemctl is-active --quiet systemd-timesyncd || return 1
    run_cmd "$(msg "Show time synchronization status" "显示时间同步状态")" timedatectl timesync-status || true
}

step_05_ssh_port() {
    local ssh_port backup port_dropin port_backup service sshd_bin
    ssh_port="$(prompt_input "$(msg "SSH port (leave empty to skip)" "SSH 端口（留空跳过）")" "$BOOTSTRAP_SSH_PORT")"
    if [[ -z "$ssh_port" ]]; then
        warn "$(msg "No SSH port provided; skipping step 05" "未输入 SSH 端口，跳过步骤 05")"
        return 0
    fi
    if ! validate_port "$ssh_port"; then
        error "$(msg "Invalid SSH port: $ssh_port" "SSH 端口不合法: $ssh_port")"
        return 1
    fi
    if ! confirm "$(msg "Change the SSH port to ${ssh_port} and validate the configuration before restarting" "修改 SSH 端口为 ${ssh_port}，并在重启前验证配置")"; then
        warn "$(msg "Skipping step 05" "跳过步骤 05")"
        return 0
    fi

    backup="$(backup_file /etc/ssh/sshd_config)" || return 1
    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "$(msg "[dry-run] Comment out existing Port lines in /etc/ssh/sshd_config" "[dry-run] 注释 /etc/ssh/sshd_config 中已有 Port 行")"
        info "$(msg "[dry-run] Ensure /etc/ssh/sshd_config includes sshd_config.d" "[dry-run] 确保 /etc/ssh/sshd_config 引入 sshd_config.d")"
        info "$(msg "[dry-run] Write /etc/ssh/sshd_config.d/00-bootstrap-port.conf" "[dry-run] 写入 /etc/ssh/sshd_config.d/00-bootstrap-port.conf")"
        info "$(msg "[dry-run] Remove the old /etc/ssh/sshd_config.d/99-bootstrap-port.conf" "[dry-run] 清理旧的 /etc/ssh/sshd_config.d/99-bootstrap-port.conf")"
        info "[dry-run] sshd -t -f /etc/ssh/sshd_config"
        info "$(msg "[dry-run] If UFW is active, allow $ssh_port/tcp first" "[dry-run] 如果 UFW 已启用，先放行 $ssh_port/tcp")"
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
        error "$(msg "sshd was not found; cannot validate SSH configuration" "未找到 sshd，无法验证 SSH 配置")"
        restore_file_from_backup /etc/ssh/sshd_config "$backup"
        restore_file_from_backup "$port_dropin" "$port_backup"
        return 1
    fi
    if ! "$sshd_bin" -t -f /etc/ssh/sshd_config; then
        error "$(msg "SSH configuration validation failed; restoring the backup" "SSH 配置验证失败，正在恢复备份")"
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
    if ! run_cmd "$(msg "Restart the SSH service" "重启 SSH 服务")" systemctl restart "$service"; then
        error "$(msg "The SSH service failed to restart; restoring the original configuration" "SSH 服务重启失败，正在恢复原配置")"
        restore_file_from_backup /etc/ssh/sshd_config "$backup"
        restore_file_from_backup "$port_dropin" "$port_backup"
        "$sshd_bin" -t -f /etc/ssh/sshd_config >/dev/null 2>&1 && systemctl restart "$service" >/dev/null 2>&1 || true
        return 1
    fi
    success "$(msg "The SSH port is now ${ssh_port}. Ensure this port is allowed before enabling the firewall." "SSH 端口已设置为 ${ssh_port}。启用防火墙前请确认该端口已放行。")"
}

step_06_ufw() {
    local ufw_ssh_port
    ufw_ssh_port="$(prompt_input "$(msg "SSH port to allow through the firewall (leave empty to skip)" "防火墙允许的 SSH 端口（留空跳过）")" "$BOOTSTRAP_SSH_PORT")"
    if [[ -z "$ufw_ssh_port" ]]; then
        warn "$(msg "No SSH port provided; skipping step 06" "未输入 SSH 端口，跳过步骤 06")"
        return 0
    fi
    if ! validate_port "$ufw_ssh_port"; then
        error "$(msg "Invalid firewall SSH port: $ufw_ssh_port" "防火墙 SSH 端口不合法: $ufw_ssh_port")"
        return 1
    fi
    if ! validate_bool "$BOOTSTRAP_KEEP_OLD_SSH_PORT"; then
        error "$(msg "BOOTSTRAP_KEEP_OLD_SSH_PORT must be true or false" "BOOTSTRAP_KEEP_OLD_SSH_PORT 只能是 true 或 false")"
        return 1
    fi
    if [[ "$BOOTSTRAP_KEEP_OLD_SSH_PORT" == "true" ]] && ! validate_port "$BOOTSTRAP_OLD_SSH_PORT"; then
        error "$(msg "Invalid BOOTSTRAP_OLD_SSH_PORT: $BOOTSTRAP_OLD_SSH_PORT" "BOOTSTRAP_OLD_SSH_PORT 不合法: $BOOTSTRAP_OLD_SSH_PORT")"
        return 1
    fi
    if ! confirm "$(msg "Install and enable UFW; allow $ufw_ssh_port/tcp, 80/tcp, and 443/tcp" "安装并启用 UFW，开放 $ufw_ssh_port/tcp、80/tcp、443/tcp")"; then
        warn "$(msg "Skipping step 06" "跳过步骤 06")"
        return 0
    fi
    apt_install ufw || return 1
    run_cmd "$(msg "Allow SSH port $ufw_ssh_port/tcp" "开放 SSH 端口 $ufw_ssh_port/tcp")" ufw allow "$ufw_ssh_port/tcp" || return 1
    if [[ "$BOOTSTRAP_KEEP_OLD_SSH_PORT" == "true" && -n "$BOOTSTRAP_OLD_SSH_PORT" && "$BOOTSTRAP_OLD_SSH_PORT" != "$ufw_ssh_port" ]]; then
        run_cmd "$(msg "Temporarily keep the old SSH port $BOOTSTRAP_OLD_SSH_PORT/tcp open" "临时保留旧 SSH 端口 $BOOTSTRAP_OLD_SSH_PORT/tcp")" ufw allow "$BOOTSTRAP_OLD_SSH_PORT/tcp" || return 1
    fi
    run_cmd "$(msg "Allow HTTP port 80/tcp" "开放 HTTP 端口 80/tcp")" ufw allow 80/tcp || return 1
    run_cmd "$(msg "Allow HTTPS port 443/tcp" "开放 HTTPS 端口 443/tcp")" ufw allow 443/tcp || return 1
    run_cmd "$(msg "Enable UFW" "启用 UFW")" ufw --force enable || return 1
    run_cmd "$(msg "Show UFW status" "显示 UFW 状态")" ufw status verbose || return 1
    if [[ "$BOOTSTRAP_KEEP_OLD_SSH_PORT" == "true" && -n "$BOOTSTRAP_OLD_SSH_PORT" && "$BOOTSTRAP_OLD_SSH_PORT" != "$ufw_ssh_port" ]]; then
        warn "$(msg "The old SSH port is still open as configured. After verifying login on the new port, run manually: ufw delete allow ${BOOTSTRAP_OLD_SSH_PORT}/tcp" "旧 SSH 端口已按配置保留。确认新端口能登录后，可手动执行: ufw delete allow ${BOOTSTRAP_OLD_SSH_PORT}/tcp")"
    fi
}

step_07_ssh_keys() {
    local key_file="$HOME/.ssh/authorized_keys"
    local tmp line added=0
    if ! confirm "$(msg "Add SSH public keys to $key_file" "添加 SSH 公钥到 $key_file")"; then
        warn "$(msg "Skipping step 07" "跳过步骤 07")"
        return 0
    fi
    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "$(msg "[dry-run] Create $HOME/.ssh and append to authorized_keys" "[dry-run] 将创建 $HOME/.ssh 并追加 authorized_keys")"
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
            warn "$(msg "No SSH public key provided in --yes mode; skipping step 07" "--yes 模式未提供 SSH 公钥，跳过步骤 07")"
            rm -f "$tmp"
            return 0
        fi
        echo -e "$(msg "${COLOR_WARN}Paste SSH public keys (press Ctrl+D when finished):${COLOR_RESET}" "${COLOR_WARN}请粘贴 SSH 公钥（粘贴后按 Ctrl+D 结束）:${COLOR_RESET}")" >&2
        cat >"$tmp" </dev/tty
    fi

    if [[ ! -s "$tmp" ]]; then
        warn "$(msg "No SSH public keys received; skipping" "没有读取到 SSH 公钥，跳过")"
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
    success "$(msg "SSH public keys processed; added $added lines" "SSH 公钥处理完成，新增 $added 行")"
}

step_08_profile() {
    local content
    if ! confirm "$(msg "Configure /etc/profile.d/99-bootstrap.sh (Git prompt, PS1, history timestamps, aliases)" "配置 /etc/profile.d/99-bootstrap.sh（git 提示、PS1、HISTFORMAT、别名）")"; then
        warn "$(msg "Skipping step 08" "跳过步骤 08")"
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
HISTTIMEFORMAT="%F %T "
export HISTTIMEFORMAT
alias ll='ls -al'
# -- bootstrap 配置 end --
PROFILE_EOF
)
    backup_file /etc/profile.d/99-bootstrap.sh >/dev/null || return 1
    write_file /etc/profile.d/99-bootstrap.sh 0644 "$content" || return 1
    run_cmd "$(msg "Validate shell profile syntax" "验证 Profile 配置语法")" bash -n /etc/profile.d/99-bootstrap.sh || return 1
    warn "$(msg "The current shell does not inherit a child process's profile; after the script finishes, run: source /etc/profile.d/99-bootstrap.sh (or log in again via SSH)" "当前 Shell 不会继承子进程的 Profile；脚本结束后执行: source /etc/profile.d/99-bootstrap.sh（或重新登录 SSH）")"
}

step_09_nezha() {
    local nezha_server nezha_secret nezha_tls tmp
    nezha_server="$(prompt_input "$(msg "Nezha server address (host:port; leave empty to skip)" "哪吒探针服务器地址（格式 host:port，留空跳过）")" "$BOOTSTRAP_NEZHA_SERVER")"
    if [[ -z "$nezha_server" ]]; then
        warn "$(msg "Nezha is not configured; skipping step 09" "未配置哪吒探针，跳过步骤 09")"
        return 0
    fi
    if ! validate_host_port "$nezha_server"; then
        error "$(msg "Invalid Nezha server address: $nezha_server" "哪吒探针服务器地址不合法: $nezha_server")"
        return 1
    fi
    nezha_secret="$(prompt_secret "$(msg "Nezha agent secret" "哪吒探针客户端密钥")" "${BOOTSTRAP_NEZHA_SECRET:-}")"
    if [[ -z "$nezha_secret" ]]; then
        warn "$(msg "No secret provided; skipping step 09" "未输入密钥，跳过步骤 09")"
        return 0
    fi
    nezha_tls="$(prompt_input "$(msg "Use TLS (true/false)" "是否使用 TLS（true/false）")" "$BOOTSTRAP_NEZHA_TLS")"
    if ! validate_bool "$nezha_tls"; then
        error "$(msg "The TLS option must be true or false" "TLS 选项只能是 true 或 false")"
        return 1
    fi
    if ! confirm "$(msg "Download and install the Nezha agent (server: $nezha_server)" "下载并安装哪吒探针 (server: $nezha_server)")"; then
        warn "$(msg "Skipping step 09" "跳过步骤 09")"
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

network_profile_content() {
    case "$1" in
        minimal)
            cat <<'NETWORK_MINIMAL_EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
NETWORK_MINIMAL_EOF
            ;;
        standard)
            cat <<'NETWORK_STANDARD_EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_default = 262144
net.core.wmem_default = 524288
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.core.netdev_max_backlog = 2500
NETWORK_STANDARD_EOF
            ;;
        low-memory)
            cat <<'NETWORK_LOW_MEMORY_EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max = 8388608
net.core.wmem_max = 8388608
net.ipv4.tcp_rmem = 4096 87380 8388608
net.ipv4.tcp_wmem = 4096 65536 8388608
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.core.netdev_max_backlog = 1000
NETWORK_LOW_MEMORY_EOF
            ;;
        *)
            return 1
            ;;
    esac
}

step_10_bbr() {
    local content current_cc current_qdisc modules_content
    if ! confirm "$(msg "Apply ${BOOTSTRAP_NETWORK_PROFILE} network settings (BBR + FQ)" "应用 ${BOOTSTRAP_NETWORK_PROFILE} 网络参数（BBR + FQ）")"; then
        warn "$(msg "Skipping step 10" "跳过步骤 10")"
        return 0
    fi
    content="$(network_profile_content "$BOOTSTRAP_NETWORK_PROFILE")" || return 1
    modules_content=$'tcp_bbr\nsch_fq'
    backup_file /etc/sysctl.d/99-bootstrap-bbr.conf >/dev/null || return 1
    backup_file /etc/modules-load.d/99-bootstrap-network.conf >/dev/null || return 1
    write_file /etc/sysctl.d/99-bootstrap-bbr.conf 0644 "$content" || return 1
    write_file /etc/modules-load.d/99-bootstrap-network.conf 0644 "$modules_content" || return 1
    if [[ "$DRY_RUN" -ne 1 ]] && command -v modprobe >/dev/null 2>&1; then
        modprobe tcp_bbr >>"$LOG_FILE" 2>&1 || true
        modprobe sch_fq >>"$LOG_FILE" 2>&1 || true
    fi
    run_cmd "$(msg "Apply network sysctl settings" "应用网络 sysctl 配置")" sysctl --load=/etc/sysctl.d/99-bootstrap-bbr.conf || return 1
    if [[ "$DRY_RUN" -ne 1 ]]; then
        current_cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
        current_qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
        if [[ "$current_cc" != "bbr" || "$current_qdisc" != "fq" ]]; then
            error "$(msg "Network settings validation failed: congestion_control=${current_cc:-unknown}, qdisc=${current_qdisc:-unknown}" "网络参数验证失败：congestion_control=${current_cc:-unknown}, qdisc=${current_qdisc:-unknown}")"
            return 1
        fi
        success "$(msg "Network settings are active: profile=${BOOTSTRAP_NETWORK_PROFILE}, BBR + FQ" "网络配置已生效：profile=${BOOTSTRAP_NETWORK_PROFILE}, BBR + FQ")"
    fi
}

configure_ufw_ipv6_disabled() {
    local ufw_defaults="/etc/default/ufw"
    local backup="" tmp

    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "$(msg "[dry-run] If UFW is installed, set /etc/default/ufw: IPV6=no" "[dry-run] 如果 UFW 已安装，设置 /etc/default/ufw: IPV6=no")"
        info "$(msg "[dry-run] If UFW is active, run ufw reload and verify that no (v6) rules remain" "[dry-run] 如果 UFW 已启用，执行 ufw reload 并确认不再显示 (v6) 规则")"
        return 0
    fi
    if [[ ! -f "$ufw_defaults" ]]; then
        info "$(msg "/etc/default/ufw was not found; skipping UFW IPv6 changes" "未发现 /etc/default/ufw，跳过 UFW IPv6 联动")"
        return 0
    fi

    if grep -Eq '^[[:space:]]*IPV6[[:space:]]*=[[:space:]]*no[[:space:]]*$' "$ufw_defaults"; then
        info "$(msg "UFW already has IPV6=no" "UFW 已配置 IPV6=no")"
    else
        backup="$(backup_file "$ufw_defaults")" || return 1
        tmp="$(mktemp)" || return 1
        awk '
            BEGIN { written=0 }
            /^[[:space:]]*IPV6[[:space:]]*=/ {
                if (written == 0) print "IPV6=no"
                written=1
                next
            }
            { print }
            END { if (written == 0) print "IPV6=no" }
        ' "$ufw_defaults" >"$tmp" || {
            rm -f "$tmp"
            return 1
        }
        if ! install -m 0644 "$tmp" "$ufw_defaults"; then
            rm -f "$tmp"
            restore_file_from_backup "$ufw_defaults" "$backup"
            return 1
        fi
        rm -f "$tmp"
        success "$(msg "Set UFW to IPV6=no" "UFW 已设置 IPV6=no")"
    fi

    if command -v ufw >/dev/null 2>&1 && LC_ALL=C ufw status 2>/dev/null | grep -Eq '^Status:[[:space:]]+active'; then
        if ! run_cmd "$(msg "Reload UFW to remove IPv6 rules" "重载 UFW 以移除 IPv6 规则")" ufw reload; then
            if [[ -n "$backup" ]]; then
                restore_file_from_backup "$ufw_defaults" "$backup"
                ufw reload >>"$LOG_FILE" 2>&1 || true
            fi
            return 1
        fi
        if LC_ALL=C ufw status 2>/dev/null | grep -Fq '(v6)'; then
            error "$(msg "UFW still shows (v6) rules after reloading; check: ufw status" "UFW 重载后仍显示 (v6) 规则，请检查: ufw status")"
            return 1
        fi
    fi
}

step_11_ipv6() {
    local content
    if ! confirm "$(msg "Disable IPv6 (optional)" "禁用 IPv6（可选）")"; then
        warn "$(msg "Skipping step 11" "跳过步骤 11")"
        return 0
    fi
    content=$(cat <<'IPV6_EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
IPV6_EOF
)
    configure_ufw_ipv6_disabled || return 1
    backup_file /etc/sysctl.d/99-bootstrap-disable-ipv6.conf >/dev/null || return 1
    write_file /etc/sysctl.d/99-bootstrap-disable-ipv6.conf 0644 "$content" || return 1
    run_cmd "$(msg "Apply IPv6 sysctl settings" "应用 IPv6 sysctl 配置")" sysctl --load=/etc/sysctl.d/99-bootstrap-disable-ipv6.conf || return 1
}

step_17_nodequality() {
    local tmp ret
    if ! confirm "$(msg "Run the NodeQuality latency test (downloads the official test script)" "运行 NodeQuality 延迟测试（会下载官方测试脚本）")"; then
        warn "$(msg "Skipping step 17" "跳过步骤 17")"
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
    run_interactive_cmd "$(msg "Run the NodeQuality test" "运行 NodeQuality 测试")" bash "$tmp"
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

swap_size_to_bytes() {
    local value="$1"
    local mb
    mb="$(swap_size_to_mb "$value")" || return 1
    echo $((mb * 1024 * 1024))
}

ensure_swap_fstab_entry() {
    local priority="$1"
    local desired="/swapfile none swap sw,pri=${priority} 0 0"
    local count backup tmp

    count="$(awk '$1 == "/swapfile" { count++ } END { print count + 0 }' /etc/fstab 2>/dev/null || echo 0)"
    if [[ "$count" == "1" ]] && grep -Fxq "$desired" /etc/fstab; then
        return 0
    fi

    backup="$(backup_file /etc/fstab)" || return 1
    tmp="$(mktemp)" || return 1
    awk '$1 != "/swapfile" { print }' /etc/fstab >"$tmp" || {
        rm -f "$tmp"
        return 1
    }
    printf "%s\n" "$desired" >>"$tmp" || {
        rm -f "$tmp"
        return 1
    }
    if ! install -m 0644 "$tmp" /etc/fstab; then
        rm -f "$tmp"
        restore_file_from_backup /etc/fstab "$backup"
        return 1
    fi
    rm -f "$tmp"
}

configure_swapfile() {
    local swap_size="$1"
    local priority="$2"
    local tmp_swap="/swapfile.bootstrap.$$"
    local old_swap_backup=""
    local count_mb target_bytes current_bytes current_priority old_was_active=0

    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "$(msg "[dry-run] Ensure $swap_size /swapfile (priority=${priority}) and add it to /etc/fstab" "[dry-run] 确保 $swap_size /swapfile（priority=${priority}）并写入 /etc/fstab")"
        return 0
    fi

    target_bytes="$(swap_size_to_bytes "$swap_size")" || return 1
    current_bytes="$(stat -c %s /swapfile 2>/dev/null || echo 0)"
    if [[ "$current_bytes" == "$target_bytes" ]]; then
        current_priority="$(awk '$1 == "/swapfile" { print $5 }' /proc/swaps 2>/dev/null || true)"
        if [[ -z "$current_priority" ]]; then
            run_cmd "$(msg "Enable the existing swapfile" "启用现有 swapfile")" swapon -p "$priority" /swapfile || return 1
        elif [[ "$current_priority" != "$priority" ]]; then
            run_cmd "$(msg "Deactivate the swapfile to update its priority" "停用 swapfile 以更新优先级")" swapoff /swapfile || return 1
            if ! run_cmd "$(msg "Reactivate the swapfile with priority $priority" "按优先级 $priority 重新启用 swapfile")" swapon -p "$priority" /swapfile; then
                warn "$(msg "Activation with the new priority failed; trying to restore priority $current_priority" "新优先级启用失败，尝试恢复优先级 $current_priority")"
                swapon -p "$current_priority" /swapfile >>"$LOG_FILE" 2>&1 || true
                return 1
            fi
        fi
        ensure_swap_fstab_entry "$priority" || return 1
        info "$(msg "Reusing the existing /swapfile with the requested size" "现有 /swapfile 大小正确，已复用")"
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
        old_was_active=1
        swapoff /swapfile || {
            rm -f "$tmp_swap"
            return 1
        }
    fi
    if [[ -e /swapfile ]]; then
        old_swap_backup="/swapfile.bak.$(date +%Y%m%d-%H%M%S).$$"
        mv /swapfile "$old_swap_backup" || {
            rm -f "$tmp_swap"
            return 1
        }
    fi
    if ! mv "$tmp_swap" /swapfile; then
        if [[ -n "$old_swap_backup" && -e "$old_swap_backup" ]]; then
            mv "$old_swap_backup" /swapfile
            [[ "$old_was_active" -eq 1 ]] && swapon /swapfile 2>/dev/null || true
        fi
        return 1
    fi
    if ! swapon -p "$priority" /swapfile; then
        warn "$(msg "The new swapfile failed to activate; trying to restore the old file" "新 swapfile 启用失败，尝试恢复旧文件")"
        swapoff /swapfile 2>/dev/null || true
        rm -f /swapfile
        if [[ -n "$old_swap_backup" && -e "$old_swap_backup" ]]; then
            mv "$old_swap_backup" /swapfile
            [[ "$old_was_active" -eq 1 ]] && swapon /swapfile 2>/dev/null || true
        fi
        return 1
    fi

    if ! ensure_swap_fstab_entry "$priority"; then
        swapoff /swapfile 2>/dev/null || true
        rm -f /swapfile
        if [[ -n "$old_swap_backup" && -e "$old_swap_backup" ]]; then
            mv "$old_swap_backup" /swapfile
            [[ "$old_was_active" -eq 1 ]] && swapon /swapfile 2>/dev/null || true
        fi
        return 1
    fi
    if [[ -n "$old_swap_backup" ]]; then
        warn "$(msg "The old swapfile was preserved at: $old_swap_backup" "旧 swapfile 已保留为: $old_swap_backup")"
    fi
}

restart_zramswap_safely() {
    local reset_path="/sys/block/zram0/reset"
    local device="/dev/zram0"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "$(msg "[dry-run] Stop zramswap; verify /dev/zram0 is not mounted; swapoff + reset if needed; then start" "[dry-run] stop zramswap；确认 /dev/zram0 未挂载；必要时 swapoff + reset；再 start")"
        return 0
    fi

    run_cmd "$(msg "Enable zramswap at boot" "设置 zramswap 开机启动")" systemctl enable zramswap.service || return 1
    if ! systemctl stop zramswap.service >>"$LOG_FILE" 2>&1; then
        warn "$(msg "zramswap stop did not fully clean up the device; performing a controlled reset" "zramswap stop 未完全清理设备，将执行受控 reset")"
        log_event "WARN zramswap stop returned non-zero"
    fi

    if command -v findmnt >/dev/null 2>&1 && findmnt -rn -S "$device" >/dev/null 2>&1; then
        error "$(msg "$device is a mounted filesystem; refusing to reset it" "$device 被用作挂载文件系统，拒绝重置")"
        return 1
    fi
    if grep -q "^${device}[[:space:]]" /proc/swaps 2>/dev/null; then
        run_cmd "$(msg "Deactivate the old ZRam swap" "停用旧 ZRam swap")" swapoff "$device" || return 1
    fi
    if [[ -e "$reset_path" ]]; then
        if ! printf '1\n' >"$reset_path"; then
            error "$(msg "Cannot reset $device" "无法重置 $device")"
            return 1
        fi
        log_event "OK reset $device"
    fi
    run_cmd "$(msg "Start the zramswap service" "启动 zramswap 服务")" systemctl start zramswap.service || return 1
}

step_12_swap_zram() {
    local choice swap_size zram_percent zram_algo desc content
    choice="$(prompt_input "$(msg "Configuration mode (1=Swap only, 2=Swap+ZRam)" "配置模式（1=仅Swap, 2=Swap+ZRam）")" "2")"
    if [[ -z "$choice" ]]; then
        warn "$(msg "Skipping step 12" "跳过步骤 12")"
        return 0
    fi
    if [[ "$choice" != "1" && "$choice" != "2" ]]; then
        error "$(msg "Configuration mode must be 1 or 2" "配置模式只能是 1 或 2")"
        return 1
    fi

    swap_size="$(prompt_input "$(msg "Swap file size (e.g. 1G; leave empty to skip)" "Swap 文件大小（如 1G，留空跳过）")" "$BOOTSTRAP_SWAP_SIZE")"
    if [[ -n "$swap_size" ]] && ! validate_swap_size "$swap_size"; then
        error "$(msg "Invalid swap size: $swap_size" "Swap 大小不合法: $swap_size")"
        return 1
    fi
    [[ "$swap_size" == "none" ]] && swap_size=""

    if [[ "$choice" == "2" ]]; then
        zram_percent="$(prompt_input "$(msg "ZRam percentage of physical memory (leave empty to skip)" "ZRam 占物理内存百分比（留空跳过）")" "$BOOTSTRAP_ZRAM_PERCENT")"
        if [[ -n "$zram_percent" ]] && ! validate_percent "$zram_percent"; then
            error "$(msg "Invalid ZRam percentage: $zram_percent" "ZRam 百分比不合法: $zram_percent")"
            return 1
        fi
        if [[ -n "$zram_percent" && "$zram_percent" != "0" ]]; then
            zram_algo="$(prompt_input "$(msg "ZRam compression algorithm (lz4/lzo/zstd)" "ZRam 压缩算法（lz4/lzo/zstd）")" "$BOOTSTRAP_ZRAM_ALGO")"
            if ! validate_zram_algo "$zram_algo"; then
                error "$(msg "Unsupported ZRam compression algorithm: $zram_algo" "ZRam 压缩算法不支持: $zram_algo")"
                return 1
            fi
        fi
    else
        zram_percent=""
    fi

    if [[ -z "$swap_size" && -z "${zram_percent:-}" ]]; then
        warn "$(msg "Neither Swap nor ZRam is configured; skipping step 12" "未配置 Swap 和 ZRam，跳过步骤 12")"
        return 0
    fi
    if [[ -z "$swap_size" && "${zram_percent:-}" == "0" ]]; then
        warn "$(msg "Neither Swap nor ZRam is configured; skipping step 12" "未配置 Swap 和 ZRam，跳过步骤 12")"
        return 0
    fi

    desc=""
    [[ -n "$swap_size" ]] && desc="Swap ($swap_size)"
    [[ -n "${zram_percent:-}" && "$zram_percent" != "0" ]] && desc="${desc:+$desc + }ZRam (${zram_percent}%/$zram_algo)"
    if ! confirm "$(msg "Configure $desc" "配置 $desc")"; then
        warn "$(msg "Skipping step 12" "跳过步骤 12")"
        return 0
    fi

    if [[ -n "$swap_size" ]]; then
        configure_swapfile "$swap_size" "$BOOTSTRAP_SWAP_PRIORITY" || return 1
        success "$(msg "Swapfile configuration complete" "Swapfile 配置完成")"
    fi

    if [[ -n "${zram_percent:-}" && "$zram_percent" != "0" ]]; then
        apt_install zram-tools || return 1
        content=$(cat <<ZRAM_EOF
ALGO=$zram_algo
PERCENT=$zram_percent
PRIORITY=$BOOTSTRAP_ZRAM_PRIORITY
ZRAM_EOF
)
        backup_file /etc/default/zramswap >/dev/null || return 1
        write_file /etc/default/zramswap 0644 "$content" || return 1
        content=$(cat <<SYSCTL_ZRAM_EOF
vm.swappiness=$BOOTSTRAP_SWAPPINESS
vm.vfs_cache_pressure=$BOOTSTRAP_VFS_CACHE_PRESSURE
SYSCTL_ZRAM_EOF
)
        backup_file /etc/sysctl.d/99-zram-swap.conf >/dev/null || return 1
        write_file /etc/sysctl.d/99-zram-swap.conf 0644 "$content" || return 1
        run_cmd "$(msg "Apply memory sysctl settings" "应用内存 sysctl 配置")" sysctl --load=/etc/sysctl.d/99-zram-swap.conf || return 1
        restart_zramswap_safely || return 1
        if [[ "$DRY_RUN" -ne 1 ]] && ! awk -v priority="$BOOTSTRAP_ZRAM_PRIORITY" '
            $1 ~ /^\/dev\/zram/ && $5 == priority { found=1 }
            END { exit(found ? 0 : 1) }
        ' /proc/swaps; then
            error "$(msg "ZRam started but is not active with the expected priority ${BOOTSTRAP_ZRAM_PRIORITY}" "ZRam 已启动但未以期望优先级 ${BOOTSTRAP_ZRAM_PRIORITY} 生效")"
            return 1
        fi
        success "$(msg "ZRam configuration complete" "ZRam 配置完成")"
    fi

    run_cmd "$(msg "Show swap status" "显示 swap 状态")" swapon --show || return 1
    run_cmd "$(msg "Show ZRam status" "显示 zram 状态")" zramctl || true
    run_cmd "$(msg "Show memory status" "显示内存状态")" free -h || true
}

install_crowdsec_repo() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "$(msg "[dry-run] Add the CrowdSec packagecloud repository and keyring" "[dry-run] 添加 CrowdSec packagecloud 仓库和 keyring")"
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
    run_cmd "$(msg "Install/verify CrowdSec collection: $collection" "安装/确认 CrowdSec collection: $collection")" cscli collections install "$collection"
}

step_13_crowdsec() {
    if ! confirm "$(msg "Install CrowdSec protection (UFW logs, rsyslog, nginx-proxy-manager, iptables, and sshd rules)" "安装 CrowdSec 防护（ufw 日志、rsyslog、nginx-proxy-manager、iptables、sshd 规则）")"; then
        warn "$(msg "Skipping step 13" "跳过步骤 13")"
        return 0
    fi
    apt_install ufw rsyslog curl gnupg apt-transport-https || return 1
    if [[ "$DRY_RUN" -ne 1 ]]; then
        parse_os_release
        if [[ "${OS_ID:-}" == "debian" ]]; then
            apt_install debian-archive-keyring || return 1
        fi
    fi
    run_cmd "$(msg "Enable UFW logging" "开启 UFW 日志")" ufw logging on || return 1
    run_cmd "$(msg "Enable rsyslog" "启用 rsyslog")" systemctl enable rsyslog --now || return 1
    install_crowdsec_repo || return 1
    run_cmd "$(msg "Update the apt index" "更新 apt 索引")" apt-get update || return 1
    apt_install crowdsec crowdsec-firewall-bouncer-iptables || return 1
    run_cmd "$(msg "Update the CrowdSec hub" "更新 CrowdSec hub")" cscli hub update || return 1
    install_crowdsec_collection crowdsecurity/nginx-proxy-manager || return 1
    install_crowdsec_collection crowdsecurity/iptables || return 1
    install_crowdsec_collection crowdsecurity/sshd || return 1
    run_cmd "$(msg "Enable CrowdSec" "启用 CrowdSec")" systemctl enable crowdsec --now || return 1
    run_cmd "$(msg "Validate CrowdSec configuration" "验证 CrowdSec 配置")" crowdsec -t || return 1
    run_cmd "$(msg "Restart CrowdSec" "重启 CrowdSec")" systemctl restart crowdsec || return 1
    run_cmd "$(msg "Show CrowdSec collections" "显示 CrowdSec collections")" cscli collections list || return 1
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
        info "$(msg "[dry-run] Check for and remove old packages that may conflict with official Docker packages" "[dry-run] 检查并移除可能与 Docker 官方包冲突的旧包")"
        return 0
    fi
    for pkg in "${packages[@]}"; do
        if dpkg -s "$pkg" >/dev/null 2>&1; then
            run_cmd "$(msg "Remove conflicting package: $pkg" "移除冲突软件包: $pkg")" apt-get remove -y "$pkg" || return 1
        fi
    done
}

install_docker_repo() {
    local docker_os docker_codename arch key_tmp
    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "$(msg "[dry-run] Add the official Docker apt repository (selected for the Debian/Ubuntu release at runtime)" "[dry-run] 添加 Docker 官方 apt 仓库（运行时按 Debian/Ubuntu 版本自动选择）")"
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
            error "$(msg "Automatic Docker repository setup is not supported on: ${OS_ID:-unknown}" "暂不支持自动配置 Docker 仓库的系统: ${OS_ID:-unknown}")"
            return 1
            ;;
    esac
    if [[ -z "$docker_codename" ]]; then
        error "$(msg "Cannot identify the OS release codename; cannot configure the Docker repository" "无法识别系统版本代号，不能配置 Docker 仓库")"
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

step_14_docker() {
    local content shim docker_daemon_backup
    if ! confirm "$(msg "Install Docker Engine, Buildx, and Docker Compose, and configure log rotation" "安装 Docker Engine、Buildx、Docker Compose，并配置日志轮转")"; then
        warn "$(msg "Skipping step 14" "跳过步骤 14")"
        return 0
    fi
    remove_conflicting_docker_packages || return 1
    apt_install ca-certificates curl gnupg || return 1
    install_docker_repo || return 1
    run_cmd "$(msg "Update the apt index" "更新 apt 索引")" apt-get update || return 1
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
    if ! run_cmd "$(msg "Restart Docker" "重启 Docker")" systemctl restart docker; then
        error "$(msg "Docker failed to restart; restoring the original daemon.json" "Docker 重启失败，正在恢复原 daemon.json")"
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

    run_cmd "$(msg "Check the Docker version" "检查 Docker 版本")" docker --version || return 1
    run_cmd "$(msg "Check the Docker Compose version" "检查 Docker Compose 版本")" docker compose version || return 1
    run_cmd "$(msg "Check the docker-compose compatibility command" "检查 docker-compose 兼容命令")" docker-compose version || return 1
    warn "$(msg "Docker modifies iptables directly. If you rely on UFW for strict inbound filtering, also review the DOCKER-USER chain." "Docker 会直接操作 iptables。若依赖 UFW 做严格入站控制，请额外检查 DOCKER-USER 链。")"
}

step_15_vim() {
    local content
    if ! confirm "$(msg "Configure ~/.vimrc" "配置 ~/.vimrc")"; then
        warn "$(msg "Skipping step 15" "跳过步骤 15")"
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
    local state_ret
    select_language "$@"
    parse_args "$@"
    validate_runtime_options
    if [[ "$LIST_STEPS" -eq 1 ]]; then
        list_steps
        return 0
    fi
    if [[ "$SHOW_STATUS" -eq 1 ]]; then
        print_state_status
        return $?
    fi

    load_config
    set_defaults
    apply_cli_overrides
    validate_step_selection
    validate_config_values
    echo_banner
    check_root
    check_supported_system

    export DEBIAN_FRONTEND=noninteractive

    setup_log || {
        error "$(msg "Cannot initialize the log: $LOG_FILE" "无法初始化日志: $LOG_FILE")"
        return 1
    }
    if [[ "$DRY_RUN" -eq 0 ]]; then
        prepare_state
        state_ret=$?
        if [[ "$state_ret" -eq 2 ]]; then
            return 0
        elif [[ "$state_ret" -ne 0 ]]; then
            return "$state_ret"
        fi
        install_state_traps
    fi

    echo -e "$(msg "\n${COLOR_BOLD}Starting server bootstrap...${COLOR_RESET}\n" "\n${COLOR_BOLD}开始服务器初始化...${COLOR_RESET}\n")" >&2
    run_step "01" step_01_update
    run_step "02" step_02_software
    run_step "03" step_03_password
    run_step "04" step_04_hostname
    run_step "05" step_05_ssh_port
    run_step "06" step_06_ufw
    run_step "07" step_07_ssh_keys
    run_step "08" step_08_profile
    run_step "09" step_09_nezha
    run_step "10" step_10_bbr
    run_step "11" step_11_ipv6
    run_step "12" step_12_swap_zram
    run_step "13" step_13_crowdsec
    run_step "14" step_14_docker
    run_step "15" step_15_vim
    run_step "16" step_16_timesync
    run_step "17" step_17_nodequality

    if [[ "$STATE_ENABLED" -eq 1 ]]; then
        RUN_STATUS="complete"
        CURRENT_STEP=""
        FAILED_STEP=""
        write_state || {
            error "$(msg "Execution finished, but the final checkpoint could not be written" "执行完成，但无法写入最终检查点")"
            return 1
        }
    fi
    log_event "$(msg "===== bootstrap v${SCRIPT_VERSION} complete =====" "===== bootstrap v${SCRIPT_VERSION} 完成 =====")"

    echo -e "\n${COLOR_SUCCESS}${COLOR_BOLD}========================================${COLOR_RESET}" >&2
    echo -e "$(msg "${COLOR_SUCCESS}${COLOR_BOLD}  All steps finished!${COLOR_RESET}" "${COLOR_SUCCESS}${COLOR_BOLD}  所有步骤执行完毕！${COLOR_RESET}")" >&2
    echo -e "${COLOR_SUCCESS}${COLOR_BOLD}========================================${COLOR_RESET}\n" >&2
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
