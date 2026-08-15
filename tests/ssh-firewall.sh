#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
sed "s|/etc/ssh|$tmp_dir/ssh|g" bootstrap.sh >"$tmp_dir/bootstrap.sh"
source "$tmp_dir/bootstrap.sh"
set_defaults
DRY_RUN=1
BOOTSTRAP_SSH_PORT=2222
detect_ssh_service() { echo ssh; }
systemctl() { return 1; }
prompt_input() {
    case "$1" in
        'SSH port (leave empty to skip)') echo 3333 ;;
        *) printf '%s\n' "${2:-}" ;;
    esac
}

step_05_ssh_port >"$tmp_dir/ssh-output" 2>&1
[[ "$BOOTSTRAP_SSH_PORT" == 3333 ]]
step_06_ufw >"$tmp_dir/ufw-output" 2>&1
grep -Fq 'ufw allow 3333/tcp' "$tmp_dir/ufw-output"
if grep -Fq 'ufw allow 2222/tcp' "$tmp_dir/ufw-output"; then
    echo 'UFW used the stale configured SSH port' >&2
    exit 1
fi

# Resume step 06 after step 05 has already applied a different interactive port.
BOOTSTRAP_SSH_PORT=2222
RESUME=1
COMPLETED_STEPS=05
mkdir -p "$tmp_dir/ssh/sshd_config.d"
printf 'Port 3333\n' >"$tmp_dir/ssh/sshd_config.d/00-bootstrap-port.conf"
step_06_ufw >"$tmp_dir/resume-output" 2>&1
grep -Fq 'ufw allow 3333/tcp' "$tmp_dir/resume-output"
if grep -Fq 'ufw allow 2222/tcp' "$tmp_dir/resume-output"; then
    exit 1
fi

# Declining the SSH change must leave the configured default untouched.
confirm() { return 1; }
step_05_ssh_port >"$tmp_dir/declined-output" 2>&1
[[ "$BOOTSTRAP_SSH_PORT" == 2222 ]]

echo 'SSH firewall port tests passed'
