#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

# Exercise the real step/checkpoint lifecycle with a local external-script fixture.
# No packages are installed and no network or server configuration is touched.
for test_case in zero nonzero other zh download INT TERM; do
    case_dir="$tmp_dir/$test_case"
    mkdir "$case_dir"
    result=0
    TEST_CASE="$test_case" TEST_DIR="$case_dir" bash -c '
        source ./bootstrap.sh
        set_defaults
        AUTO_YES=1
        ONLY_STEPS=17
        STATE_FILE="$TEST_DIR/state"
        LOG_FILE="$TEST_DIR/log"
        [[ "$TEST_CASE" != zh ]] || UI_LANG=zh
        RUN_FINGERPRINT="$(configuration_fingerprint)"
        initialize_state
        setup_log
        install_state_traps
        apt_install() { return 0; }
        download_file() {
            if [[ "$TEST_CASE" == download ]]; then
                error "fixture download failed"
                return 28
            fi
            printf "%s\n" "$2" >"$TEST_DIR/installer-path"
            cat >"$2" <<"FIXTURE"
#!/usr/bin/env bash
echo "external test stdout"
echo "external test stderr" >&2
echo invoked >>"$TEST_DIR/calls"
case "$TEST_CASE" in
    zero) exit 0 ;;
    nonzero|zh) exit 1 ;;
    other) exit 42 ;;
    INT|TERM) kill -s "$TEST_CASE" "$PPID"; exit 0 ;;
esac
FIXTURE
        }
        run_step 17 step_17_nodequality
        echo CONTINUED
        # A processed external test must not be invoked again on resume.
        RESUME=1
        prepare_state
        run_step 17 step_17_nodequality
        RUN_STATUS=complete
        write_state
    ' >"$case_dir/output" 2>&1 || result=$?

    case "$test_case" in
        download|INT|TERM)
            case "$test_case" in
                download) expected_code=1; expected_status=failed ;;
                INT) expected_code=130; expected_status=interrupted ;;
                TERM) expected_code=143; expected_status=interrupted ;;
            esac
            [[ "$result" -eq "$expected_code" ]]
            grep -Fxq "STATUS=$expected_status" "$case_dir/state"
            grep -Fxq FAILED_STEP=17 "$case_dir/state"
            grep -Fxq COMPLETED_STEPS= "$case_dir/state"
            if grep -Eq "CONTINUED|NodeQuality has ended|NodeQuality 已结束" "$case_dir/output"; then
                echo "preparation failure or interruption was treated as an ended test" >&2
                exit 1
            fi
            if [[ "$test_case" == download ]]; then
                grep -Fq "fixture download failed" "$case_dir/output"
                [[ ! -e "$case_dir/calls" ]]
            fi
            ;;
        *)
            [[ "$result" -eq 0 ]]
            grep -Fxq STATUS=complete "$case_dir/state"
            grep -Fxq COMPLETED_STEPS=17 "$case_dir/state"
            grep -Fxq FAILED_STEP= "$case_dir/state"
            grep -Fq "external test stdout" "$case_dir/output"
            grep -Fq "external test stderr" "$case_dir/output"
            grep -Fxq CONTINUED "$case_dir/output"
            [[ "$(wc -l <"$case_dir/calls")" -eq 1 ]]
            [[ ! -e "$(cat "$case_dir/installer-path")" ]]
            if [[ "$test_case" == zh ]]; then
                grep -Fq "NodeQuality 已结束" "$case_dir/output"
            else
                grep -Fq "NodeQuality has ended" "$case_dir/output"
            fi
            grep -Fq "STEP 17 END" "$case_dir/log"
            if grep -Eq "Step 17 (completed|failed)|步骤 17 (完成|执行失败)|STEP 17 (OK|FAIL)" "$case_dir/output" "$case_dir/log"; then
                echo "bootstrap interpreted the external test result" >&2
                exit 1
            fi
            ;;
    esac
    # Signal handling may exit before the normal per-step temporary-file cleanup.
    if [[ -f "$case_dir/installer-path" ]]; then
        rm -f "$(cat "$case_dir/installer-path")"
    fi
done

echo "optional NodeQuality tests passed"
