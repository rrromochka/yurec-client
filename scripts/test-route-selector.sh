#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(dirname "$script_dir")
test_binary="${TMPDIR:-/tmp}/yurec-route-selector-tests-$$"

trap 'rm -f "$test_binary"' EXIT

xcrun swiftc -parse-as-library \
    "$repo_root/YurecClient/Managers/RouteSelectorStore.swift" \
    "$repo_root/Tests/RouteSelectorStoreTests.swift" \
    -o "$test_binary"

"$test_binary"
