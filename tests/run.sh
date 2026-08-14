#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

for test_file in \
    tests/privacy-defaults.sh \
    tests/language.sh \
    tests/dry-run.sh \
    tests/state.sh \
    tests/ssh-rollback.sh \
    tests/input.sh; do
    echo "==> $test_file"
    bash "$test_file"
done

echo "all tests passed"
