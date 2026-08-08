#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

export BOOTSTRAP_LANG=en
bash bootstrap.sh --help >"$tmp_dir/help-en"
grep -Fq 'Usage:' "$tmp_dir/help-en"
for args in '--lang zh --help' '--help --lang zh' '--lang=zh --help'; do
    # Intentional splitting of fixed argument lists.
    # shellcheck disable=SC2086
    bash bootstrap.sh $args >"$tmp_dir/help-zh"
    grep -Fq '用法:' "$tmp_dir/help-zh"
done
BOOTSTRAP_LANG=zh bash bootstrap.sh --help >"$tmp_dir/env-zh"
grep -Fq '用法:' "$tmp_dir/env-zh"
BOOTSTRAP_LANG=zh bash bootstrap.sh --help --lang en >"$tmp_dir/override"
grep -Fq 'Usage:' "$tmp_dir/override"
BOOTSTRAP_LANG=invalid bash bootstrap.sh --lang en --help >"$tmp_dir/override-invalid"
grep -Fq 'Usage:' "$tmp_dir/override-invalid"

expect_failure() {
    local expected="$1"
    shift
    if bash bootstrap.sh "$@" >"$tmp_dir/error" 2>&1; then
        printf 'unexpected success: %s\n' "$*" >&2
        exit 1
    fi
    grep -Fq -- "$expected" "$tmp_dir/error"
}

expect_failure 'Unsupported language: fr' --lang fr --help
expect_failure 'Unsupported language:' --lang= --help
expect_failure '--lang requires a value' --lang
expect_failure '--lang requires a value' --lang --help
expect_failure '未知参数: --unknown' --unknown --lang zh
expect_failure '--ssh-port 需要一个值' --ssh-port --lang zh
expect_failure 'Invalid BOOTSTRAP_SSH_PORT: invalid' --dry-run --ssh-port invalid
expect_failure 'BOOTSTRAP_SSH_PORT 不合法: invalid' --lang zh --dry-run --ssh-port invalid
expect_failure '--resume and --reset-state cannot be used together' --resume --reset-state
expect_failure '--resume 与 --reset-state 不能同时使用' --resume --reset-state --lang zh

# Prompt text goes to stderr; stdout must remain the literal input value.
for language in en zh; do
    LANGUAGE_UNDER_TEST="$language" bash -c '
        source ./bootstrap.sh
        select_language --lang "$LANGUAGE_UNDER_TEST"
        DRY_RUN=1
        value=$(prompt_input Hostname "literal %s \\ value")
        [[ "$value" == "literal %s \\ value" ]]
        [[ "$(prompt_secret Secret)" == DRY_RUN_SECRET ]]
        confirm Continue
    ' >"$tmp_dir/prompt-$language.out" 2>"$tmp_dir/prompt-$language.err"
    [[ ! -s "$tmp_dir/prompt-$language.out" ]]
done
grep -Fq 'Would ask:' "$tmp_dir/prompt-en.err"
grep -Fq '将询问:' "$tmp_dir/prompt-zh.err"
if BOOTSTRAP_LANG=invalid bash bootstrap.sh --help >"$tmp_dir/error" 2>&1; then
    echo 'invalid environment language was accepted' >&2
    exit 1
fi
grep -Fq 'Unsupported language:' "$tmp_dir/error"

echo 'language tests passed'
