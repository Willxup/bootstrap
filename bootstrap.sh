#!/bin/bash
# =============================================================================
# 服务器初始化脚本
# Usage: sudo ./bootstrap.sh [--all] [--dry-run] [--verbose]
# =============================================================================

set -e

# ==================== 全局变量 ====================
AUTO_RUN=""
DRY_RUN=""
VERBOSE=""

# ==================== 颜色输出 ====================
COLOR_INFO='\033[1;36m'
COLOR_SUCCESS='\033[1;32m'
COLOR_WARN='\033[1;33m'
COLOR_ERROR='\033[1;31m'
COLOR_BOLD='\033[1m'
COLOR_RESET='\033[0m'

info()    { echo -e "${COLOR_INFO}    [INFO]${COLOR_RESET} $*" >&2; }
success() { echo -e "${COLOR_SUCCESS}  [SUCCESS]${COLOR_RESET} $*" >&2; }
warn()    { echo -e "${COLOR_WARN}    [WARN]${COLOR_RESET} $*" >&2; }
error()   { echo -e "${COLOR_ERROR}   [ERROR]${COLOR_RESET} $*" >&2; }

# ==================== 参数解析 ====================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --all)     AUTO_RUN=1 ;;
            --dry-run) DRY_RUN=1 ;;
            --verbose) VERBOSE=1 ;;
            -h|--help)
                usage
                exit 0 ;;
            *)
                error "未知参数: $1"
                usage
                exit 1 ;;
        esac
        shift
    done
}

usage() {
    cat << 'EOF'
用法: sudo ./bootstrap.sh [选项]

选项:
  --all              跳过所有确认，自动执行全部步骤
  --dry-run           预览模式，只打印将要执行的操作
  --verbose          详细输出
  -h, --help         显示此帮助信息
EOF
}

# ==================== 检查 root ====================
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "此脚本必须以 root 权限运行，请使用 sudo"
        exit 1
    fi
}

# ==================== 交互式输入 ====================
prompt_input() {
    local description="$1"
    local default="$2"

    if [[ -n "$DRY_RUN" ]]; then
        echo -e "  ${COLOR_INFO}[dry-run]${COLOR_RESET} 将询问: $description (默认: $default)" >&2
        return
    fi
    if [[ -n "$AUTO_RUN" && -n "$default" ]]; then
        echo "$default"
        return
    fi

    echo -ne "${COLOR_BOLD}  $description${COLOR_RESET}" >&2
    if [[ -n "$default" ]]; then
        echo -ne "\n  (直接回车使用默认值: $default, 输入 n 跳过): " >&2
    else
        echo -ne "\n  (直接回车跳过): " >&2
    fi
    read -r input < /dev/tty
    if [[ "$input" == "n" || "$input" == "N" ]]; then
        echo ""
    elif [[ -z "$input" && -n "$default" ]]; then
        echo "$default"
    else
        echo "$input"
    fi
}

# ==================== 确认提示 ====================
confirm() {
    local msg="$1"
    if [[ -n "$DRY_RUN" ]]; then
        info "[dry-run] $msg"
        return 0
    fi
    if [[ -n "$AUTO_RUN" ]]; then
        return 0
    fi

    local prompt answer
    prompt="${COLOR_BOLD}${msg}${COLOR_RESET}"
    while true; do
        echo -ne "\n$prompt [y/n]: " >&2
        read -r answer < /dev/tty
        case $answer in
            y|Y) return 0 ;;
            n|N) return 1 ;;
        esac
    done
}

# ==================== 执行步骤 ====================
run_step() {
    local step_num="$1"
    local step_name="$2"
    local step_func="$3"

    echo "" >&2
    echo -e "${COLOR_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${COLOR_RESET}" >&2
    echo -e "${COLOR_BOLD}  步骤 ${step_num}: ${step_name}${COLOR_RESET}" >&2
    echo -e "${COLOR_BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${COLOR_RESET}" >&2

    if [[ -n "$DRY_RUN" ]]; then
        info "[dry-run] 跳过执行，继续下一步"
        return 0
    fi

    if [[ -n "$VERBOSE" ]]; then
        set -x
    fi

    $step_func
    local ret=$?

    if [[ -n "$VERBOSE" ]]; then
        set +x
    fi

    if [[ $ret -eq 0 ]]; then
        success "步骤 ${step_num} 完成"
    else
        error "步骤 ${step_num} 执行失败"
    fi
    echo "" >&2
}

# ==================== 执行命令 ====================
run_cmd() {
    local description="$1"
    shift
    info "$description..."
    if [[ -n "$DRY_RUN" ]]; then
        info "[dry-run] 命令: $*"
        return 0
    fi
    if [[ -n "$VERBOSE" ]]; then
        "$@"
    else
        "$@" > /dev/null 2>&1
    fi
}

# ==================== 幂等标记 ====================
mark_done() {
    local marker="$1"
    mkdir -p /var/lib/bootstrap
    touch "/var/lib/bootstrap/$marker"
}

is_done() {
    local marker="$1"
    [[ -f "/var/lib/bootstrap/$marker" ]]
}

# =============================================================================
# 步骤函数
# =============================================================================

step_01_update() {
    if ! confirm "更新 apt 索引并升级所有已安装软件包"; then
        warn "跳过步骤 01"
        return 0
    fi
    if [[ -n "$DRY_RUN" ]]; then return 0; fi

    run_cmd "更新 apt" apt update
    run_cmd "升级软件包" apt upgrade -y
    success "系统已更新"
}

step_02_software() {
    if ! confirm "安装必要软件: vim htop net-tools unzip curl wget"; then
        warn "跳过步骤 02"
        return 0
    fi
    if [[ -n "$DRY_RUN" ]]; then return 0; fi

    apt install -y vim htop net-tools unzip curl wget
    success "必要软件安装完成"
}

step_03_password() {
    if ! confirm "修改 root 密码"; then
        warn "跳过步骤 03"
        return 0
    fi
    if [[ -n "$DRY_RUN" ]]; then return 0; fi

    passwd
    success "密码已修改"
}

step_04_hostname() {
    local new_hostname
    new_hostname=$(prompt_input "新主机名（留空跳过）" "")
    if [[ -z "$new_hostname" ]]; then
        warn "未输入主机名，跳过步骤 04"
        return 0
    fi
    if ! confirm "将主机名设置为 '$new_hostname'"; then
        warn "跳过步骤 04"
        return 0
    fi
    if [[ -n "$DRY_RUN" ]]; then return 0; fi

    hostnamectl set-hostname "$new_hostname"
    echo "$new_hostname" > /etc/hostname
    success "主机名已设置为: $new_hostname"
}

step_05_ssh_port() {
    local ssh_port
    ssh_port=$(prompt_input "SSH 端口（留空跳过）" "22")
    if [[ -z "$ssh_port" ]]; then
        warn "未输入 SSH 端口，跳过步骤 05"
        return 0
    fi

    if ! confirm "修改 SSH 端口为 $ssh_port 并重启 sshd"; then
        warn "跳过步骤 05"
        return 0
    fi
    if [[ -n "$DRY_RUN" ]]; then return 0; fi

    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%F-%T)

    if grep -q "^#\?Port " /etc/ssh/sshd_config; then
        sed -i "s/^#\?Port.*/Port $ssh_port/" /etc/ssh/sshd_config
    else
        echo "Port $ssh_port" >> /etc/ssh/sshd_config
    fi

    systemctl restart sshd
    success "SSH 端口已修改为: $ssh_port，记得用新端口测试连接"
}

step_06_ufw() {
    local ufw_ssh_port
    ufw_ssh_port=$(prompt_input "防火墙允许的 SSH 端口（留空跳过）" "22")
    if [[ -z "$ufw_ssh_port" ]]; then
        warn "未输入 SSH 端口，跳过步骤 06"
        return 0
    fi

    if ! confirm "安装并启用 ufw 防火墙，开放 $ufw_ssh_port/tcp、80/tcp、443/tcp"; then
        warn "跳过步骤 06"
        return 0
    fi
    if [[ -n "$DRY_RUN" ]]; then return 0; fi

    apt install -y ufw
    ufw allow "$ufw_ssh_port/tcp"
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw --force enable
    success "防火墙已启用"
}

step_07_ssh_keys() {
    if ! confirm "添加 SSH 公钥到 ~/.ssh/authorized_keys"; then
        warn "跳过步骤 07"
        return 0
    fi
    if [[ -n "$DRY_RUN" ]]; then return 0; fi

    mkdir -p ~/.ssh
    chmod 700 ~/.ssh

    echo -e "${COLOR_WARN}请粘贴你的 SSH 公钥（粘贴后按 Ctrl+D 结束）:${COLOR_RESET}" >&2
    cat >> ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys
    success "SSH 公钥已添加"
}

step_08_profile() {
    if is_done "profile"; then
        warn "Profile 已配置（已完成），跳过"
        return 0
    fi
    if ! confirm "配置 /etc/profile（git 提示、PS1、HISTFORMAT、别名）"; then
        warn "跳过步骤 08"
        return 0
    fi
    if [[ -n "$DRY_RUN" ]]; then return 0; fi

    if grep -q "bootstrap 配置" /etc/profile 2>/dev/null; then
        warn "Profile 已配置，跳过"
        return 0
    fi

    tee -a /etc/profile << 'PROFILE_EOF'

# -- bootstrap 配置 --
export GIT_PS1_SHOWDIRTYSTATE=1
PS1='\[\e[1;32m\][\u@\h \W]\[\e[1;33m\]$(__git_ps1 " (%s)")\[\e[1;32m\]\$ \[\e[0m\]'
HISTFILESIZE=4000
HISTSIZE=4000
USER_IP=`who -u am i 2>/dev/null| awk '{print $NF}'|sed -e 's/[()]//g'`
if [ -z "$USER_IP" ]; then USER_IP=`hostname`; fi
HISTTIMEFORMAT="%F %T $USER_IP:`whoami` "
export HISTTIMEFORMAT
alias ll='ls -al'
# -- bootstrap 配置 end --
PROFILE_EOF

    source /etc/profile
    success "Profile 配置完成"
    mark_done "profile"
}

step_09_nezha() {
    if is_done "nezha"; then
        warn "哪吒探针已安装（已完成），跳过"
        return 0
    fi
    local nezha_server nezha_secret nezha_tls
    nezha_server=$(prompt_input "哪吒探针服务器地址（格式 host:port，留空跳过）" "")
    if [[ -z "$nezha_server" ]]; then
        warn "未配置哪吒探针，跳过步骤 09"
        return 0
    fi

    nezha_secret=$(prompt_input "哪吒探针客户端密钥" "")
    if [[ -z "$nezha_secret" ]]; then
        warn "未输入密钥，跳过步骤 09"
        return 0
    fi

    nezha_tls=$(prompt_input "是否使用 TLS（true/false）" "false")

    if ! confirm "安装哪吒探针 (server: $nezha_server)"; then
        warn "跳过步骤 09"
        return 0
    fi
    if [[ -n "$DRY_RUN" ]]; then return 0; fi

    curl -L https://raw.githubusercontent.com/nezhahq/scripts/main/agent/install.sh \
        -o /tmp/nezha-agent.sh && chmod +x /tmp/nezha-agent.sh
    env NZ_SERVER="$nezha_server" NZ_TLS="$nezha_tls" \
        NZ_CLIENT_SECRET="$nezha_secret" /tmp/nezha-agent.sh
    rm -f /tmp/nezha-agent.sh
    success "哪吒探针安装完成"
    mark_done "nezha"
}

step_10_bbr() {
    if is_done "bbr"; then
        warn "BBR 已配置（已完成），跳过"
        return 0
    fi
    if ! confirm "开启 BBR 和 FQ 拥塞控制算法"; then
        warn "跳过步骤 10"
        return 0
    fi
    if [[ -n "$DRY_RUN" ]]; then return 0; fi

    if grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf 2>/dev/null; then
        warn "BBR 已配置，跳过"
        sysctl --system > /dev/null 2>&1
        return 0
    fi

    echo -e "\nnet.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl --system
    if lsmod | grep -q bbr; then
        success "BBR 已启用"
    else
        warn "BBR 模块可能未加载，当前内核可能不支持"
    fi
    mark_done "bbr"
}

step_11_ipv6() {
    if is_done "ipv6"; then
        warn "IPv6 已禁用（已完成），跳过"
        return 0
    fi
    if ! confirm "禁用 IPv6"; then
        warn "跳过步骤 11"
        return 0
    fi
    if [[ -n "$DRY_RUN" ]]; then return 0; fi

    if grep -q "net.ipv6.conf.all.disable_ipv6 = 1" /etc/sysctl.conf 2>/dev/null; then
        warn "IPv6 已禁用，跳过"
        return 0
    fi

    tee -a /etc/sysctl.conf << 'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    sysctl -p > /dev/null 2>&1
    success "IPv6 已禁用"
    mark_done "ipv6"
}

step_12_nodequality() {
    if ! confirm "运行 NodeQuality 延迟测试"; then
        warn "跳过步骤 12"
        return 0
    fi
    if [[ -n "$DRY_RUN" ]]; then return 0; fi

    info "正在运行 NodeQuality 测试脚本..."
    bash <(curl -sL https://run.NodeQuality.com)
    success "NodeQuality 测试完成"
}

step_13_swap_zram() {
    if is_done "swap_zram"; then
        warn "Swap & ZRam 已配置（已完成），跳过"
        return 0
    fi
    local swap_size zram_percent zram_algo choice
    choice=$(prompt_input "配置模式（1=仅Swap, 2=Swap+ZRam）" "2")

    if [[ -z "$choice" ]]; then
        warn "跳过步骤 13"
        return 0
    elif [[ "$choice" == "1" ]]; then
        swap_size=$(prompt_input "Swap 文件大小（如 1G，留空跳过）" "1G")
        zram_percent=""
    else
        swap_size=$(prompt_input "Swap 文件大小（如 1G，留空跳过）" "")
        zram_percent=$(prompt_input "ZRam 占物理内存百分比（留空跳过）" "25")
    fi

    if [[ -z "$swap_size" && -z "$zram_percent" ]]; then
        warn "未配置 Swap 和 ZRam，跳过步骤 13"
        return 0
    fi

    if [[ -n "$zram_percent" && "$zram_percent" != "0" ]]; then
        zram_algo=$(prompt_input "ZRam 压缩算法（lz4/lzo/zstd）" "lz4")
    fi

    local desc=""
    [[ -n "$swap_size" ]] && desc="Swap ($swap_size)"
    [[ -n "$zram_percent" && "$zram_percent" != "0" ]] && desc="${desc:+$desc + }ZRam (${zram_percent}%)"
    if ! confirm "配置 $desc"; then
        warn "跳过步骤 13"
        return 0
    fi
    if [[ -n "$DRY_RUN" ]]; then return 0; fi

    if [[ -n "$swap_size" ]]; then
        info "配置 swapfile..."
        swapoff /swapfile 2>/dev/null || true
        rm -f /swapfile
        if ! fallocate -l "$swap_size" /swapfile 2>/dev/null; then
            local count_mb
            if [[ "$swap_size" =~ ^([0-9]+)[gG]$ ]]; then
                count_mb=$(( ${BASH_REMATCH[1]} * 1024 ))
            elif [[ "$swap_size" =~ ^([0-9]+)[mM]$ ]]; then
                count_mb=${BASH_REMATCH[1]}
            else
                count_mb=1024
            fi
            dd if=/dev/zero of=/swapfile bs=1M count="$count_mb" 2>/dev/null || true
        fi
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile

        cp /etc/fstab /etc/fstab.bak.$(date +%F-%T)
        sed -i '\|^/swapfile |d' /etc/fstab
        echo '/swapfile none swap sw,pri=10 0 0' >> /etc/fstab
        success "Swapfile 配置完成"
    fi

    if [[ -n "$zram_percent" && "$zram_percent" != "0" ]]; then
        info "配置 zram..."
        apt update && apt install -y zram-tools

        cat > /etc/default/zramswap << EOF
ALGO=${zram_algo:-lz4}
PERCENT=$zram_percent
PRIORITY=100
EOF

        mkdir -p /etc/sysctl.d
        cat > /etc/sysctl.d/99-zram-swap.conf << 'EOF'
vm.swappiness=40
vm.vfs_cache_pressure=100
EOF

        systemctl enable --now zramswap
        sysctl --system > /dev/null 2>&1
        systemctl restart zramswap
        success "ZRam 配置完成"
    fi

    swapon --show
    zramctl 2>/dev/null || true
    cat /proc/sys/vm/swappiness
    mark_done "swap_zram"
}

step_14_crowdsec() {
    if is_done "crowdsec"; then
        warn "CrowdSec 已安装（已完成），跳过"
        return 0
    fi
    if ! confirm "安装 CrowdSec 防护（包含 ufw 日志、rsyslog、nginx-proxy-manager、sshd 规则）"; then
        warn "跳过步骤 14"
        return 0
    fi
    if [[ -n "$DRY_RUN" ]]; then return 0; fi

    ufw logging on
    run_cmd "安装 rsyslog" apt install -y rsyslog
    systemctl enable rsyslog --now

    run_cmd "添加 crowdsec 安装源" bash -c "curl -s https://install.crowdsec.net | sh"
    run_cmd "更新 apt" apt update
    run_cmd "安装 crowdsec" apt install -y crowdsec
    run_cmd "安装 iptables bouncer" apt install -y crowdsec-firewall-bouncer-iptables

    cscli hub update
    cscli collections install crowdsecurity/nginx-proxy-manager
    cscli collections install crowdsecurity/iptables
    cscli collections install crowdsecurity/sshd

    systemctl reload crowdsec
    crowdsec -t
    systemctl enable crowdsec --now

    success "CrowdSec 安装完成"
    mark_done "crowdsec"
}

step_15_docker() {
    if is_done "docker"; then
        warn "Docker 已安装（已完成），跳过"
        return 0
    fi
    local compose_version
    compose_version=$(prompt_input "Docker Compose 版本（留空跳过）" "v5.1.1")
    local desc="Docker"
    [[ -n "$compose_version" ]] && desc="Docker + Docker Compose ($compose_version)"

    if ! confirm "安装 $desc"; then
        warn "跳过步骤 15"
        return 0
    fi
    if [[ -n "$DRY_RUN" ]]; then return 0; fi

    run_cmd "安装 Docker" wget -qO- get.docker.com | bash
    docker --version

    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json << 'EOF'
{
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "20m",
        "max-file": "3"
    },
    "experimental": true,
    "storage-driver": "overlay2"
}
EOF

    systemctl restart docker

    if [[ -n "$compose_version" ]]; then
        run_cmd "下载 docker-compose" curl -L \
            "https://github.com/docker/compose/releases/download/$compose_version/docker-compose-linux-x86_64" \
            -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
        docker-compose --version
    fi

    success "Docker 安装完成"
    mark_done "docker"
}

step_16_vim() {
    if is_done "vim"; then
        warn "Vim 配置已完成，跳过"
        return 0
    fi
    if ! confirm "配置 ~/.vimrc"; then
        warn "跳过步骤 16"
        return 0
    fi
    if [[ -n "$DRY_RUN" ]]; then return 0; fi

    if grep -q "bootstrap vimrc" "$HOME/.vimrc" 2>/dev/null; then
        warn "Vim 配置已存在，跳过"
        return 0
    fi

    tee -a "$HOME/.vimrc" << 'VIM_EOF'
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
set wrap            " 不自动折行（如果单行太长，超出屏幕也不折行显示）

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

    success "Vim 配置完成"
    mark_done "vim"
}

# =============================================================================
# 主流程
# =============================================================================
main() {
    echo_banner
    parse_args "$@"
    check_root

    echo -e "\n${COLOR_BOLD}开始服务器初始化...${COLOR_RESET}\n" >&2

    run_step "01" "更新系统"               step_01_update
    run_step "02" "安装必要软件"            step_02_software
    run_step "03" "修改密码"               step_03_password
    run_step "04" "修改主机名"             step_04_hostname
    run_step "05" "修改 SSH 端口"          step_05_ssh_port
    run_step "06" "启用 UFW 防火墙"        step_06_ufw
    run_step "07" "添加 SSH 公钥"          step_07_ssh_keys
    run_step "08" "配置 Profile"           step_08_profile
    run_step "09" "安装哪吒探针"           step_09_nezha
    run_step "10" "开启 BBR & FQ"          step_10_bbr
    run_step "11" "禁用 IPv6"              step_11_ipv6
    run_step "12" "运行 NodeQuality 测试"  step_12_nodequality
    run_step "13" "配置 Swap & ZRam"       step_13_swap_zram
    run_step "14" "安装 CrowdSec"          step_14_crowdsec
    run_step "15" "安装 Docker"            step_15_docker
    run_step "16" "配置 Vim"               step_16_vim

    echo -e "\n${COLOR_SUCCESS}${COLOR_BOLD}========================================${COLOR_RESET}" >&2
    echo -e "${COLOR_SUCCESS}${COLOR_BOLD}  所有步骤执行完毕！${COLOR_RESET}" >&2
    echo -e "${COLOR_SUCCESS}${COLOR_BOLD}========================================${COLOR_RESET}\n" >&2
}

echo_banner() {
    cat << 'EOF'
    
    
██████╗  ██████╗  ██████╗ ████████╗███████╗████████╗██████╗  █████╗ ██████╗ 
██╔══██╗██╔═══██╗██╔═══██╗╚══██╔══╝██╔════╝╚══██╔══╝██╔══██╗██╔══██╗██╔══██╗
██████╔╝██║   ██║██║   ██║   ██║   ███████╗   ██║   ██████╔╝███████║██████╔╝
██╔══██╗██║   ██║██║   ██║   ██║   ╚════██║   ██║   ██╔══██╗██╔══██║██╔═══╝ 
██████╔╝╚██████╔╝╚██████╔╝   ██║   ███████║   ██║   ██║  ██║██║  ██║██║     
╚═════╝  ╚═════╝  ╚═════╝    ╚═╝   ╚══════╝   ╚═╝   ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝     

              服务器初始化脚本 v1.0 | Power By Willxup
EOF
}

main "$@"