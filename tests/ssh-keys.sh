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

# Existing target records must remain separate, with or without a comment/newline.
for existing in 'ssh-ed25519 AAAA' "$first"; do
    for newline in present absent; do
        printf '%s' "$existing" >"$tmp_dir/ssh/authorized_keys"
        [[ "$newline" == absent ]] || printf '\n' >>"$tmp_dir/ssh/authorized_keys"

        # Importing only an existing key must leave the target byte-for-byte intact.
        cp "$tmp_dir/ssh/authorized_keys" "$tmp_dir/unchanged"
        printf '%s' "$existing" >"$BOOTSTRAP_SSH_PUBLIC_KEY_FILE"
        step_07_ssh_keys >"$tmp_dir/output" 2>&1
        cmp "$tmp_dir/unchanged" "$tmp_dir/ssh/authorized_keys"
        grep -Fq 'added 0 lines' "$tmp_dir/output"

        printf '%s\n%s' "$existing" "$second" >"$BOOTSTRAP_SSH_PUBLIC_KEY_FILE"
        printf '%s\n%s\n' "$existing" "$second" >"$tmp_dir/expected"
        step_07_ssh_keys >"$tmp_dir/output" 2>&1
        cmp "$tmp_dir/expected" "$tmp_dir/ssh/authorized_keys"
        grep -Fq 'added 1 lines' "$tmp_dir/output"
    done
done

echo 'SSH public-key import tests passed'
