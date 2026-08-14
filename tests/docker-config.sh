#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

for scenario in keep overwrite fresh auto dry-run invalid input-failure restart-failure; do
    case_dir="$tmp_dir/$scenario"
    mkdir -p "$case_dir/docker" "$case_dir/bin"
    # Use real file writes/backups in fixtures; mock package and service commands.
    sed -e "s|/etc/docker|$case_dir/docker|g" \
        -e "s|/usr/local/bin/docker-compose|$case_dir/bin/docker-compose|g" \
        bootstrap.sh >"$case_dir/bootstrap.sh"
    (
        source "$case_dir/bootstrap.sh"
        BACKUP_DIR="$case_dir/backups"
        LOG_FILE="$case_dir/log"
        printf '{"data-root":"/srv/docker","registry-mirrors":["https://example.com"]}\n' >"$case_dir/original"
        if [[ "$scenario" != fresh ]]; then
            cp "$case_dir/original" "$case_dir/docker/daemon.json"
        fi
        confirm() { return 0; }
        remove_conflicting_docker_packages() { return 0; }
        apt_install() { return 0; }
        install_docker_repo() { return 0; }
        run_cmd() {
            shift
            quote_cmd "$@" >>"$case_dir/commands"
            [[ "$scenario" != restart-failure || "$*" != 'systemctl restart docker' ]]
        }
        systemctl() { printf 'recovery %s\n' "$*" >>"$case_dir/commands"; }
        case "$scenario" in
            auto) AUTO_YES=1 ;;
            dry-run) DRY_RUN=1 ;;
            fresh)
                prompt_input() { echo 'unexpected prompt for a new installation' >&2; return 1; }
                ;;
            *)
                prompt_input() {
                    case "$scenario" in
                        keep) echo 1 ;;
                        overwrite | restart-failure) echo 2 ;;
                        invalid) echo 3 ;;
                        input-failure) return 1 ;;
                    esac
                }
                ;;
        esac
        result=0
        step_14_docker >"$case_dir/output" 2>&1 || result=$?
        case "$scenario" in
            keep | auto | dry-run)
                [[ "$result" -eq 0 ]]
                cmp "$case_dir/original" "$case_dir/docker/daemon.json"
                [[ ! -d "$BACKUP_DIR" ]]
                if grep -Fq 'systemctl restart docker' "$case_dir/commands"; then
                    echo 'preserving Docker configuration still requested a restart' >&2
                    exit 1
                fi
                ;;
            overwrite | fresh)
                [[ "$result" -eq 0 ]]
                grep -Fq '"max-size": "20m"' "$case_dir/docker/daemon.json"
                grep -Fxq 'systemctl restart docker' "$case_dir/commands"
                [[ -f "$case_dir/bin/docker-compose" ]]
                ;;
            invalid | input-failure)
                [[ "$result" -ne 0 ]]
                cmp "$case_dir/original" "$case_dir/docker/daemon.json"
                [[ ! -e "$case_dir/commands" && ! -d "$BACKUP_DIR" ]]
                ;;
            restart-failure)
                [[ "$result" -ne 0 ]]
                cmp "$case_dir/original" "$case_dir/docker/daemon.json"
                grep -Fxq 'recovery restart docker' "$case_dir/commands"
                ;;
        esac
        if [[ "$scenario" == overwrite || "$scenario" == restart-failure ]]; then
            for backup in "$BACKUP_DIR"/daemon.json.*; do
                cmp "$case_dir/original" "$backup"
            done
        fi
    )
done

echo 'Docker configuration choice tests passed'
