#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
source ./bootstrap.sh
set_defaults
DRY_RUN=1
BOOTSTRAP_SWAPPINESS=20
BOOTSTRAP_VFS_CACHE_PRESSURE=75

configure_swapfile() { return 0; }
apt_install() { return 0; }
backup_file() { return 0; }
restart_zramswap_safely() { return 0; }
write_file() {
    if [[ "$1" == /etc/sysctl.d/99-zram-swap.conf ]]; then
        printf '%s\n' "$3" >"$tmp_dir/memory.conf"
    fi
    return 0
}
run_cmd() { shift; quote_cmd "$@" >>"$tmp_dir/commands"; }
prompt_input() {
    if [[ "$1" == 'Configuration mode (1=Swap only, 2=Swap+ZRam)' && "$mode" == interactive-swap ]]; then
        echo 1
    else
        printf '%s\n' "${2:-}"
    fi
}

for mode in swap interactive-swap zram both neither; do
    rm -f "$tmp_dir/memory.conf" "$tmp_dir/commands"
    BOOTSTRAP_SWAP_SIZE=1G
    BOOTSTRAP_ZRAM_PERCENT=25
    case "$mode" in
        swap) BOOTSTRAP_ZRAM_PERCENT=0 ;;
        zram) BOOTSTRAP_SWAP_SIZE=none ;;
        neither) BOOTSTRAP_SWAP_SIZE=none; BOOTSTRAP_ZRAM_PERCENT=0 ;;
    esac
    step_12_swap_zram >"$tmp_dir/output" 2>&1
    if [[ "$mode" == neither ]]; then
        [[ ! -e "$tmp_dir/memory.conf" && ! -e "$tmp_dir/commands" ]]
    else
        grep -Fxq 'vm.swappiness=20' "$tmp_dir/memory.conf"
        grep -Fxq 'vm.vfs_cache_pressure=75' "$tmp_dir/memory.conf"
        grep -Fxq 'sysctl --load=/etc/sysctl.d/99-zram-swap.conf' "$tmp_dir/commands"
    fi
done

echo 'memory parameter tests passed'
