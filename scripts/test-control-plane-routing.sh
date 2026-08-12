#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(dirname "$script_dir")
test_binary="${TMPDIR:-/tmp}/cambodgia-control-plane-routing-tests-$$"
module_cache="${TMPDIR:-/tmp}/cambodgia-control-plane-routing-modules-$$"

trap 'rm -f "$test_binary"; rm -rf "$module_cache"' EXIT
mkdir -p "$module_cache"
export CLANG_MODULE_CACHE_PATH="$module_cache"

xcrun swiftc -parse-as-library \
    "$repo_root/YurecClient/App/ProductIdentity.swift" \
    "$repo_root/YurecClient/Managers/RouteSelectorStore.swift" \
    "$repo_root/YurecClient/Helpers/DNSHelper.swift" \
    "$repo_root/YurecClient/Managers/ConfigTransformer.swift" \
    "$repo_root/Tests/ControlPlaneRoutingTests.swift" \
    -framework SystemConfiguration \
    -o "$test_binary"

"$test_binary"
