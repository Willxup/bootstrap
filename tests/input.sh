#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

# Exercise EOF and a missing terminal without requiring a controlling TTY in CI.
for terminal in /dev/null "$tmp_dir/missing-tty"; do
    sed "s|/dev/tty|$terminal|g" bootstrap.sh >"$tmp_dir/bootstrap.sh"
    for language in en zh; do
        for prompt in confirm prompt_input prompt_secret; do
            result=0
            bash -c '
                source "$1"
                select_language --lang "$2"
                if ! "$3" Test; then
                    echo UNEXPECTED_CONTINUATION
                fi
                echo UNEXPECTED_CONTINUATION
            ' _ "$tmp_dir/bootstrap.sh" "$language" "$prompt" >"$tmp_dir/output" 2>&1 || result=$?
            [[ "$result" -eq 1 ]]
            if grep -Fq UNEXPECTED_CONTINUATION "$tmp_dir/output"; then
                echo 'terminal input failure did not stop execution' >&2
                exit 1
            fi
            if [[ "$language" == en ]]; then
                grep -Fq 'Input ended or could not be read' "$tmp_dir/output"
            else
                grep -Fq '输入已结束或无法读取终端' "$tmp_dir/output"
            fi
        done
    done

    # A failure inside command substitution must reach run_step and its checkpoint.
    result=0
    bash -c '
        source "$1"
        set_defaults
        STATE_FILE="$2"
        LOG_FILE="$3"
        ONLY_STEPS=04
        RUN_FINGERPRINT="$(configuration_fingerprint)"
        initialize_state
        install_state_traps
        run_step 04 step_04_hostname
        echo UNEXPECTED_CONTINUATION
    ' _ "$tmp_dir/bootstrap.sh" "$tmp_dir/state" "$tmp_dir/log" >"$tmp_dir/output" 2>&1 || result=$?
    [[ "$result" -eq 1 ]]
    grep -Fxq 'STATUS=failed' "$tmp_dir/state"
    grep -Fxq 'FAILED_STEP=04' "$tmp_dir/state"
    grep -Fxq 'COMPLETED_STEPS=' "$tmp_dir/state"
    if grep -Fq UNEXPECTED_CONTINUATION "$tmp_dir/output"; then
        exit 1
    fi

    # Noninteractive and preview modes must still work without a terminal.
    bash -c '
        source "$1"
        AUTO_YES=1
        confirm Test || exit 1
        [[ "$(prompt_input Test default-value)" == default-value ]] || exit 1
        [[ "$(prompt_secret Test placeholder)" == placeholder ]] || exit 1
        AUTO_YES=0
        DRY_RUN=1
        confirm Test || exit 1
        [[ "$(prompt_input Test default-value)" == default-value ]] || exit 1
        [[ "$(prompt_secret Test)" == DRY_RUN_SECRET ]]
    ' _ "$tmp_dir/bootstrap.sh" >"$tmp_dir/noninteractive" 2>&1
done

echo 'input interruption tests passed'
