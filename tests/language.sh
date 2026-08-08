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
if BOOTSTRAP_LANG=invalid bash bootstrap.sh --help >"$tmp_dir/error" 2>&1; then
    echo 'invalid environment language was accepted' >&2
    exit 1
fi
grep -Fq 'Unsupported language:' "$tmp_dir/error"

echo 'language tests passed'
