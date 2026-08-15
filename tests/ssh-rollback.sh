#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

# Redirect the script's fixed SSH paths into fixtures, never the host's /etc/ssh.
sed "s|/etc/ssh|$tmp_dir/ssh|g" bootstrap.sh >"$tmp_dir/bootstrap.sh"
source "$tmp_dir/bootstrap.sh"
BACKUP_DIR="$tmp_dir/backups"
LOG_FILE="$tmp_dir/commands.log"
AUTO_YES=1
BOOTSTRAP_SSH_PORT=2222

detect_ssh_service() { echo ssh; }
sshd() { [[ "$failure" != validation ]]; }
allow_ufw_port_if_active() { [[ "$failure" != firewall ]]; }
systemctl() {
    if [[ "$1" == is-active ]]; then
        [[ "$mode" == socket ]]
        return
    fi
    printf '%s\n' "$*" >>"$tmp_dir/systemctl.calls"
    if [[ ( "$failure" == restart && "$1" == restart ) || ( "$failure" == reload && "$1" == daemon-reload ) ]]; then
        if [[ ! -e "$tmp_dir/failed-once" ]]; then
            touch "$tmp_dir/failed-once"
            return 1
        fi
    fi
    return 0
}

# The production script targets GNU sed; use the equivalent macOS invocation locally.
sed() {
    if [[ "$(uname -s)" == Darwin && "$1" == -i ]]; then
        shift
        command sed -i '' "$@"
    else
        command sed "$@"
    fi
}

for mode in service socket; do
    for legacy in present absent; do
        for failure in validation firewall reload restart none; do
            [[ "$mode" == service && "$failure" == reload ]] && continue
            rm -f "$tmp_dir/failed-once" "$tmp_dir/systemctl.calls"
            mkdir -p "$tmp_dir/ssh/sshd_config.d"
            printf 'Port 22\n' >"$tmp_dir/ssh/sshd_config"
            printf 'Port 2200\n' >"$tmp_dir/ssh/sshd_config.d/00-bootstrap-port.conf"
            cp "$tmp_dir/ssh/sshd_config" "$tmp_dir/original-main"
            cp "$tmp_dir/ssh/sshd_config.d/00-bootstrap-port.conf" "$tmp_dir/original-port"
            if [[ "$legacy" == present ]]; then
                printf 'Port 2022\n' >"$tmp_dir/ssh/sshd_config.d/99-bootstrap-port.conf"
                cp "$tmp_dir/ssh/sshd_config.d/99-bootstrap-port.conf" "$tmp_dir/original-legacy"
            else
                rm -f "$tmp_dir/ssh/sshd_config.d/99-bootstrap-port.conf"
            fi

            result=0
            step_05_ssh_port >"$tmp_dir/output" 2>&1 || result=$?
            if [[ "$failure" == none ]]; then
                if [[ "$mode" == socket ]]; then
                    [[ "$(cat "$tmp_dir/systemctl.calls")" == $'daemon-reload\nrestart ssh.socket ssh' ]]
                else
                    [[ "$(cat "$tmp_dir/systemctl.calls")" == 'restart ssh' ]]
                fi
                [[ "$result" -eq 0 ]]
                grep -Fxq 'Port 2222' "$tmp_dir/ssh/sshd_config.d/00-bootstrap-port.conf"
                [[ ! -e "$tmp_dir/ssh/sshd_config.d/99-bootstrap-port.conf" ]]
            else
                [[ "$result" -ne 0 ]]
                if [[ "$mode" == socket && ( "$failure" == reload || "$failure" == restart ) ]]; then
                    [[ "$(grep -c '^daemon-reload$' "$tmp_dir/systemctl.calls")" -eq 2 ]]
                    [[ "$(tail -n 1 "$tmp_dir/systemctl.calls")" == 'restart ssh.socket ssh' ]]
                fi
                cmp "$tmp_dir/original-main" "$tmp_dir/ssh/sshd_config"
                cmp "$tmp_dir/original-port" "$tmp_dir/ssh/sshd_config.d/00-bootstrap-port.conf"
                if [[ "$legacy" == present ]]; then
                    cmp "$tmp_dir/original-legacy" "$tmp_dir/ssh/sshd_config.d/99-bootstrap-port.conf"
                else
                    [[ ! -e "$tmp_dir/ssh/sshd_config.d/99-bootstrap-port.conf" ]]
                fi
            fi
        done
    done
done

echo 'SSH rollback tests passed'
