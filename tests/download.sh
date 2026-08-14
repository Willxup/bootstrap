#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
source ./bootstrap.sh

# Simulate curl timing out: the wrapper must bound each attempt and retries,
# preserve the timeout status, and never invoke curl for dry-run or plain HTTP.
curl() {
    printf '%s\n' "$@" >"$tmp_dir/args"
    return 28
}

result=0
download_file https://example.com/installer.sh "$tmp_dir/download" || result=$?
[[ "$result" -eq 28 ]]
for option in --connect-timeout --max-time --retry-max-time; do
    value="$(awk -v option="$option" '$0 == option { getline; print; exit }' "$tmp_dir/args")"
    [[ "$value" =~ ^[1-9][0-9]*$ ]]
done
grep -Fxq "$tmp_dir/download" "$tmp_dir/args"
grep -Fxq 'https://example.com/installer.sh' "$tmp_dir/args"
rm "$tmp_dir/args"

DRY_RUN=1
download_file https://example.com/installer.sh "$tmp_dir/download" >"$tmp_dir/output" 2>&1
[[ ! -e "$tmp_dir/args" && ! -e "$tmp_dir/download" ]]
DRY_RUN=0
if download_file http://example.com/installer.sh "$tmp_dir/download" >"$tmp_dir/output" 2>&1; then
    echo 'an HTTP download was accepted' >&2
    exit 1
fi
[[ ! -e "$tmp_dir/args" ]]

echo 'download timeout tests passed'
