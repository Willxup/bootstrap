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
for language in en zh; do
    bash bootstrap.sh --list-steps --lang "$language" >"$tmp_dir/steps-$language"
    [[ "$(wc -l <"$tmp_dir/steps-$language" | tr -d ' ')" == 17 ]]
done
grep -Fq '17  Run NodeQuality' "$tmp_dir/steps-en"
grep -Fq '17  运行 NodeQuality' "$tmp_dir/steps-zh"
for language in en zh; do
    bash bootstrap.sh --lang "$language" --dry-run --yes \
        --config bootstrap.conf.example --only 01,02,03,04,05,06,07,08,09,10,11,12,13,14,15,16,17 \
        >"$tmp_dir/bootstrap-$language" 2>&1
done
grep -Fq 'Change the SSH port to 2222' "$tmp_dir/bootstrap-en"
grep -Fq 'Install and enable UFW' "$tmp_dir/bootstrap-en"
grep -Fq 'Download and install the Nezha agent' "$tmp_dir/bootstrap-en"
grep -Fq '修改 SSH 端口为 2222' "$tmp_dir/bootstrap-zh"
grep -Fq '安装并启用 UFW' "$tmp_dir/bootstrap-zh"
grep -Fq '下载并安装哪吒探针' "$tmp_dir/bootstrap-zh"
grep -Fq 'Apply minimal network settings' "$tmp_dir/bootstrap-en"
grep -Fq 'Run the NodeQuality latency test' "$tmp_dir/bootstrap-en"
grep -Fq 'Configure Swap (1G) + ZRam (25%/lz4)' "$tmp_dir/bootstrap-en"
grep -Fq '应用 minimal 网络参数' "$tmp_dir/bootstrap-zh"
grep -Fq '运行 NodeQuality 延迟测试' "$tmp_dir/bootstrap-zh"
grep -Fq '配置 Swap (1G) + ZRam (25%/lz4)' "$tmp_dir/bootstrap-zh"
grep -Fq 'Install CrowdSec protection' "$tmp_dir/bootstrap-en"
grep -Fq 'Install Docker Engine' "$tmp_dir/bootstrap-en"
grep -Fq 'Configure ~/.vimrc' "$tmp_dir/bootstrap-en"
grep -Fq '安装 CrowdSec 防护' "$tmp_dir/bootstrap-zh"
grep -Fq '安装 Docker Engine' "$tmp_dir/bootstrap-zh"
grep -Fq '配置 ~/.vimrc' "$tmp_dir/bootstrap-zh"
if BOOTSTRAP_LANG=invalid bash bootstrap.sh --help >"$tmp_dir/error" 2>&1; then
    echo 'invalid environment language was accepted' >&2
    exit 1
fi
grep -Fq 'Unsupported language:' "$tmp_dir/error"

echo 'language tests passed'
