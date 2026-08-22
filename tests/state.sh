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

# Skips retain checkpoint behavior, but must not be announced or logged as success.
for language in en zh; do
    TEST_STATE_FILE="$tmp_dir/skips-$language.state" TEST_LOG_FILE="$tmp_dir/skips-$language.log" \
        TEST_LANGUAGE="$language" bash -c '
            source ./bootstrap.sh
            select_language --lang "$TEST_LANGUAGE"
            set_defaults
            STATE_FILE="$TEST_STATE_FILE"
            LOG_FILE="$TEST_LOG_FILE"
            ONLY_STEPS="01,02,04"
            AUTO_YES=1
            BOOTSTRAP_HOSTNAME=""
            RUN_FINGERPRINT="$(configuration_fingerprint)"
            initialize_state
            setup_log
            run_step 04 step_04_hostname
            confirm() { return 1; }
            run_step 01 step_01_update
            step_ok() { return 0; }
            run_step 02 step_ok
            contains_step "$COMPLETED_STEPS" 04
            contains_step "$COMPLETED_STEPS" 01
            contains_step "$COMPLETED_STEPS" 02
        ' >"$tmp_dir/skips-$language.out" 2>&1
    grep -Fq 'STEP 04 SKIP' "$tmp_dir/skips-$language.log"
    grep -Fq 'STEP 01 SKIP' "$tmp_dir/skips-$language.log"
    grep -Fq 'STEP 02 OK' "$tmp_dir/skips-$language.log"
    if grep -Eq 'Step (01|04) completed|步骤 (01|04) 完成' "$tmp_dir/skips-$language.out"; then
        echo 'a skipped step was announced as completed' >&2
        exit 1
    fi
done
grep -Fq 'Step 02 completed' "$tmp_dir/skips-en.out"
grep -Fq '步骤 02 完成' "$tmp_dir/skips-zh.out"

# Custom state/log paths must preserve existing private or shared directory modes.
file_mode() {
    local raw_mode
    if stat -c '%a' "$1" 2>/dev/null; then
        return 0
    fi
    raw_mode="$(stat -f '%p' "$1")" || return 1
    printf '%o\n' "$((8#$raw_mode & 07777))"
}
for mode in 700 1777; do
    parent_dir="$tmp_dir/parent-$mode"
    mkdir "$parent_dir"
    chmod "$mode" "$parent_dir"
    (
        STATE_FILE="$parent_dir/state"
        LOG_FILE="$parent_dir/bootstrap.log"
        initialize_state
        setup_log
    )
    [[ "$(file_mode "$parent_dir")" == "$mode" ]]
    [[ "$(file_mode "$parent_dir/state")" == 600 ]]
    [[ "$(file_mode "$parent_dir/bootstrap.log")" == 600 ]]
done
ensure_dir "$tmp_dir/new-parent/child" 0700
[[ "$(file_mode "$tmp_dir/new-parent/child")" == 700 ]]

echo "state tests passed"
