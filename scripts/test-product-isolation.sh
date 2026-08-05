#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(dirname "$script_dir")
test_binary="${TMPDIR:-/tmp}/cambodgia-product-isolation-tests-$$"

trap 'rm -f "$test_binary"' EXIT

xcrun swiftc -parse-as-library \
    "$repo_root/YurecClient/App/ProductIdentity.swift" \
    "$repo_root/Tests/ProductIsolationTests.swift" \
    -o "$test_binary"

"$test_binary"
