#!/usr/bin/env bash
set -euo pipefail
export BOOTSTRAP_LANG=en

cd "$(dirname "$0")/.."

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

# shellcheck source=../bootstrap.sh
source ./bootstrap.sh

STATE_FILE="$tmp_dir/state"
LOG_FILE="$tmp_dir/bootstrap.log"
ONLY_STEPS="04,10,12"
SKIP_STEPS=""
set_defaults

RUN_FINGERPRINT="$(configuration_fingerprint)"
UI_LANG=zh
[[ "$(configuration_fingerprint)" == "$RUN_FINGERPRINT" ]]
UI_LANG=en
initialize_state
add_completed_step "04"
write_state

RESUME=1
prepare_state
if ! contains_step "$COMPLETED_STEPS" "04"; then
    echo "completed step was not restored" >&2
    exit 1
fi

status_output="$(bash bootstrap.sh --status --state-file "$STATE_FILE")"
printf '%s\n' "$status_output" | grep -Fq 'Status: running'
printf '%s\n' "$status_output" | grep -Fq '04  Completed'
zh_status="$(bash bootstrap.sh --status --state-file "$STATE_FILE" --lang zh)"
printf '%s\n' "$zh_status" | grep -Fq '状态: running'
printf '%s\n' "$zh_status" | grep -Fq '04  完成'

BOOTSTRAP_NETWORK_PROFILE=standard
if ! prepare_state >"$tmp_dir/mismatch.log" 2>&1; then
    echo "changed configuration could not resume" >&2
    exit 1
fi
grep -Fq 'The current configuration or script version differs from the checkpoint' "$tmp_dir/mismatch.log"
if ! contains_step "$COMPLETED_STEPS" "04"; then
    echo "completed step was lost after config change" >&2
    exit 1
fi

legacy_state="$tmp_dir/legacy.state"
{
    printf 'STATE_VERSION=1\n'
    printf 'SCRIPT_VERSION=3.0.2\n'
    printf 'FINGERPRINT=0000000000000000000000000000000000000000000000000000000000000000\n'
    printf 'STARTED_AT=2026-01-01T00:00:00Z\n'
    printf 'UPDATED_AT=2026-01-01T00:00:01Z\n'
    printf 'STATUS=failed\n'
    printf 'ONLY_STEPS=12,13,14,15,16,17\n'
    printf 'SKIP_STEPS=\n'
    printf 'COMPLETED_STEPS=12,13,14,16\n'
    printf 'CURRENT_STEP=17\n'
    printf 'FAILED_STEP=17\n'
    printf 'LOG_FILE=%s\n' "$tmp_dir/legacy.log"
} >"$legacy_state"

STATE_FILE="$legacy_state"
load_state 2>"$tmp_dir/migration.log"
if [[ "$STATE_LAYOUT_MIGRATED" -ne 1 ]]; then
    echo "legacy checkpoint layout was not detected" >&2
    exit 1
fi
for migrated_step in 12 13 15; do
    if ! contains_step "$COMPLETED_STEPS" "$migrated_step"; then
        echo "legacy completed step $migrated_step was not migrated" >&2
        exit 1
    fi
done
if [[ "$CURRENT_STEP" != "16" || "$FAILED_STEP" != "16" ]]; then
    echo "legacy failed timesync step was not migrated to 16" >&2
    exit 1
fi
if ! contains_step "$STATE_ONLY_STEPS" "17"; then
    echo "legacy NodeQuality selection was not migrated to 17" >&2
    exit 1
fi
if contains_step "$COMPLETED_STEPS" "17"; then
    echo "legacy NodeQuality completion was not reset for final retest" >&2
    exit 1
fi
grep -Fq 'step numbers were automatically migrated to v3.1' "$tmp_dir/migration.log"
grep -Fq 'it will run again after the remaining configuration' "$tmp_dir/migration.log"

flow_state="$tmp_dir/flow.state"
set +e
TEST_STATE_FILE="$flow_state" TEST_LOG_FILE="$tmp_dir/flow.log" bash -c '
    source ./bootstrap.sh
    STATE_FILE="$TEST_STATE_FILE"
    LOG_FILE="$TEST_LOG_FILE"
    ONLY_STEPS="01,02"
    SKIP_STEPS=""
    set_defaults
    RUN_FINGERPRINT="$(configuration_fingerprint)"
    initialize_state
    step_ok() { return 0; }
    step_fail() { return 9; }
    run_step "01" step_ok
    run_step "02" step_fail
' >"$tmp_dir/flow-first.log" 2>&1
flow_ret=$?
set -e
if [[ "$flow_ret" -ne 9 ]]; then
    echo "failed step did not stop with its exit code" >&2
    exit 1
fi

TEST_STATE_FILE="$flow_state" TEST_LOG_FILE="$tmp_dir/flow.log" bash -c '
    source ./bootstrap.sh
    STATE_FILE="$TEST_STATE_FILE"
    LOG_FILE="$TEST_LOG_FILE"
    ONLY_STEPS="01,02"
    SKIP_STEPS=""
    set_defaults
    RESUME=1
    select_language --lang zh
    prepare_state
    must_not_run() { return 77; }
    step_ok() { return 0; }
    run_step "01" must_not_run
    run_step "02" step_ok
    RUN_STATUS="complete"
    write_state
' >"$tmp_dir/flow-resume.log" 2>&1

flow_status="$(bash bootstrap.sh --status --state-file "$flow_state")"
printf '%s\n' "$flow_status" | grep -Fq 'Status: complete'
printf '%s\n' "$flow_status" | grep -Fq '01  Completed'
printf '%s\n' "$flow_status" | grep -Fq '02  Completed'

echo "state tests passed"
