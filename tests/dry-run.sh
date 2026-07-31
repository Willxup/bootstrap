#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

output="$tmp_dir/dry-run.log"
bash bootstrap.sh \
    --dry-run \
    --yes \
    --config bootstrap.conf.example \
    --only 04,10,13 \
    --hostname cli-server \
    --network-profile standard \
    --swap-size 2G \
    --zram-percent 20 >"$output" 2>&1

grep -Fq 'hostnamectl set-hostname cli-server' "$output"
grep -Fq '应用 standard 网络参数' "$output"
grep -Fq '确保 2G /swapfile' "$output"
grep -Fq 'ZRam (20%/lz4)' "$output"

bash bootstrap.sh \
    --dry-run \
    --yes \
    --only 13 \
    --swap-size none \
    --zram-percent 20 >"$tmp_dir/zram-only.log" 2>&1
grep -Fq '配置 ZRam (20%/lz4)' "$tmp_dir/zram-only.log"
if grep -Fq '/swapfile（priority=' "$tmp_dir/zram-only.log"; then
    echo "swapfile was configured in zram-only mode" >&2
    exit 1
fi

bash bootstrap.sh \
    --dry-run \
    --yes \
    --only 17 \
    --timezone Asia/Shanghai >"$tmp_dir/timesync.log" 2>&1
grep -Fq 'systemctl enable --now systemd-timesyncd' "$tmp_dir/timesync.log"
grep -Fq 'systemctl restart systemd-timesyncd' "$tmp_dir/timesync.log"
grep -Fq 'systemctl is-active --quiet systemd-timesyncd' "$tmp_dir/timesync.log"
if grep -Fq 'timedatectl set-ntp true' "$tmp_dir/timesync.log"; then
    echo "redundant timedatectl set-ntp call is still present" >&2
    exit 1
fi

bad_config="$tmp_dir/bad.conf"
printf 'BOOTSTRAP_UNKNOWN=value\n' >"$bad_config"
if bash bootstrap.sh --dry-run --config "$bad_config" >"$tmp_dir/bad.log" 2>&1; then
    echo "unknown config key was accepted" >&2
    exit 1
fi
grep -Fq '未知配置项' "$tmp_dir/bad.log"

marker="$tmp_dir/should-not-exist"
printf 'BOOTSTRAP_HOSTNAME=$(touch %s)\n' "$marker" >"$tmp_dir/literal.conf"
if bash bootstrap.sh --dry-run --config "$tmp_dir/literal.conf" >"$tmp_dir/literal.log" 2>&1; then
    echo "invalid literal config unexpectedly succeeded" >&2
    exit 1
fi
if [[ -e "$marker" ]]; then
    echo "config value was executed as shell code" >&2
    exit 1
fi

echo "dry-run tests passed"
