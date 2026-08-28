#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

# UFW uses the applied port or reads the existing SSH configuration without asking.
for scenario in changed unchanged declined skipped only-ufw resume preconfigured multiple read-failure empty-config; do
    case_dir="$tmp_dir/$scenario"
    mkdir -p "$case_dir/ssh/sshd_config.d"
    sed "s|/etc/ssh|$case_dir/ssh|g" bootstrap.sh >"$case_dir/bootstrap.sh"
    (
        source "$case_dir/bootstrap.sh"
        set_defaults
        DRY_RUN=1
        BOOTSTRAP_SSH_PORT=2222
        detect_ssh_service() { echo ssh; }
        systemctl() { return 1; }
        apt_install() { printf 'apt-get install -y %s\n' "$*"; }
        run_cmd() { shift; quote_cmd "$@"; }
        sshd() {
            [[ "$*" == -T ]] || return 1
            printf '%s\n' "$*" >>"$case_dir/sshd-calls"
            case "$scenario" in
                resume|preconfigured) echo 'port 3333' ;;
                multiple) printf 'port 22\nport 3333\n' ;;
                read-failure) echo 'fixture SSH configuration error' >&2; return 1 ;;
                empty-config) echo 'addressfamily any' ;;
                *) echo 'port 22' ;;
            esac
        }
        prompt_input() {
            if [[ "$1" != 'SSH port (leave empty to skip)' ]]; then
                echo 'UFW unexpectedly asked for a port' >&2
                return 1
            fi
            case "$scenario" in
                changed) echo 3333 ;;
                declined) echo 2222 ;;
                unchanged|skipped) echo '' ;;
            esac
        }
        confirm() {
            if [[ "$scenario" == declined && "$1" == 'Change the SSH port'* ]]; then
                return 1
            fi
            printf '%s\n' "$1" >>"$case_dir/confirmations"
        }
        expected_ports=22
        case "$scenario" in
            changed)
                step_05_ssh_port
                expected_ports=3333
                ;;
            unchanged|declined|skipped)
                [[ "$scenario" != unchanged ]] || BOOTSTRAP_SSH_PORT=""
                step_05_ssh_port
                ;;
            resume|preconfigured)
                if [[ "$scenario" == resume ]]; then
                    RESUME=1
                    COMPLETED_STEPS=05
                fi
                expected_ports=3333
                ;;
            multiple) expected_ports='22 3333' ;;
        esac
        DRY_RUN=0
        result=0
        step_06_ufw >"$case_dir/ufw-output" 2>&1 || result=$?
        if [[ "$scenario" == read-failure || "$scenario" == empty-config ]]; then
            [[ "$result" -ne 0 ]]
            grep -Fq 'UFW has not been enabled' "$case_dir/ufw-output"
            [[ ! -f "$case_dir/confirmations" ]]
            if grep -Eq 'apt-get|ufw allow|ufw --force enable' "$case_dir/ufw-output"; then
                echo 'UFW changed despite unreadable SSH ports' >&2
                exit 1
            fi
            exit 0
        fi
        [[ "$result" -eq 0 ]]
        ports_label=""
        for port in $expected_ports; do
            grep -Fq "ufw allow $port/tcp" "$case_dir/ufw-output"
            ports_label="${ports_label:+$ports_label, }$port/tcp"
        done
        grep -Fq 'ufw --force enable' "$case_dir/ufw-output"
        grep -Fq "allow $ports_label, 80/tcp, and 443/tcp" "$case_dir/confirmations"
        if grep -Fq 'ufw allow 2222/tcp' "$case_dir/ufw-output"; then
            echo 'UFW used a configured port that was never applied' >&2
            exit 1
        fi
    ) >"$case_dir/output" 2>&1 || {
        cat "$case_dir/output" "$case_dir/ufw-output" >&2
        exit 1
    }
done

echo 'SSH firewall port tests passed'
