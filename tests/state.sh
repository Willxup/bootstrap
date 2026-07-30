#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

# shellcheck source=../bootstrap.sh
source ./bootstrap.sh

STATE_FILE="$tmp_dir/state"
LOG_FILE="$tmp_dir/bootstrap.log"
ONLY_STEPS="04,10,13"
SKIP_STEPS=""
set_defaults

RUN_FINGERPRINT="$(configuration_fingerprint)"
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
printf '%s\n' "$status_output" | grep -Fq '状态: running'
printf '%s\n' "$status_output" | grep -Fq '04  完成'

BOOTSTRAP_NETWORK_PROFILE=standard
if ! prepare_state >"$tmp_dir/mismatch.log" 2>&1; then
    echo "changed configuration could not resume" >&2
    exit 1
fi
grep -Fq '当前配置或脚本版本与检查点不同' "$tmp_dir/mismatch.log"
if ! contains_step "$COMPLETED_STEPS" "04"; then
    echo "completed step was lost after config change" >&2
    exit 1
fi

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
    run_step "01" "测试成功" step_ok
    run_step "02" "测试失败" step_fail
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
    prepare_state
    must_not_run() { return 77; }
    step_ok() { return 0; }
    run_step "01" "应跳过" must_not_run
    run_step "02" "重试成功" step_ok
    RUN_STATUS="complete"
    write_state
' >"$tmp_dir/flow-resume.log" 2>&1

flow_status="$(bash bootstrap.sh --status --state-file "$flow_state")"
printf '%s\n' "$flow_status" | grep -Fq '状态: complete'
printf '%s\n' "$flow_status" | grep -Fq '01  完成'
printf '%s\n' "$flow_status" | grep -Fq '02  完成'

echo "state tests passed"
