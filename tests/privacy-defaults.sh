#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

assert_line() {
    local file="$1"
    local expected="$2"
    if ! grep -Fqx "$expected" "$file"; then
        printf "missing expected line in %s:\n%s\n" "$file" "$expected" >&2
        return 1
    fi
}

assert_line bootstrap.sh '    : "${BOOTSTRAP_HOSTNAME:=}"'
assert_line bootstrap.sh '    : "${BOOTSTRAP_TIMEZONE:=UTC}"'
assert_line bootstrap.sh '    : "${BOOTSTRAP_SSH_PORT:=}"'
assert_line bootstrap.sh '    : "${BOOTSTRAP_NEZHA_SERVER:=}"'
assert_line bootstrap.sh '    : "${BOOTSTRAP_NETWORK_PROFILE:=minimal}"'

assert_line bootstrap.conf.example 'BOOTSTRAP_HOSTNAME=server-01'
assert_line bootstrap.conf.example 'BOOTSTRAP_TIMEZONE=UTC'
assert_line bootstrap.conf.example 'BOOTSTRAP_SSH_PORT=2222'
assert_line bootstrap.conf.example 'BOOTSTRAP_NEZHA_SERVER=monitor.example.com:5555'
