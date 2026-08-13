#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/yurec-process-ownership.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT

xcrun swiftc \
  "$repo_root/YurecClient/Managers/ProcessOwnershipPolicy.swift" \
  "$repo_root/Tests/ProcessOwnershipPolicyTests.swift" \
  -o "$build_dir/process-ownership-tests"

"$build_dir/process-ownership-tests"
