#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/yurec-session-lifecycle.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT HUP INT TERM

xcrun swiftc \
    "$repo_root/YurecClient/Managers/ConnectionMode.swift" \
    "$repo_root/Tests/SessionLifecycleTests.swift" \
    -o "$build_dir/session-lifecycle-tests"

"$build_dir/session-lifecycle-tests"
