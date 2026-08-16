#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
sed "s|[$]HOME/[.]ssh|$tmp_dir/ssh|g" bootstrap.sh >"$tmp_dir/bootstrap.sh"
source "$tmp_dir/bootstrap.sh"
AUTO_YES=1
BOOTSTRAP_SSH_PUBLIC_KEY=
BOOTSTRAP_SSH_PUBLIC_KEY_FILE="$tmp_dir/input.pub"

# Synthetic public-key records exercise file import without real credentials.
first='ssh-ed25519 AAAA fixture-one'
second='ssh-ed25519 BBBB fixture-two'
printf '%s\n%s\n' "$first" "$second" >"$tmp_dir/expected"
for newline in present absent; do
    mkdir -p "$tmp_dir/ssh"
    : >"$tmp_dir/ssh/authorized_keys"
    printf '%s\n%s' "$first" "$second" >"$BOOTSTRAP_SSH_PUBLIC_KEY_FILE"
    [[ "$newline" == absent ]] || printf '\n' >>"$BOOTSTRAP_SSH_PUBLIC_KEY_FILE"
    step_07_ssh_keys >"$tmp_dir/output" 2>&1
    cmp "$tmp_dir/expected" "$tmp_dir/ssh/authorized_keys"
    grep -Fq 'added 2 lines' "$tmp_dir/output"

    step_07_ssh_keys >"$tmp_dir/output" 2>&1
    cmp "$tmp_dir/expected" "$tmp_dir/ssh/authorized_keys"
    grep -Fq 'added 0 lines' "$tmp_dir/output"
done

echo 'SSH public-key import tests passed'
