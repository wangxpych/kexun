#!/bin/bash
set -euo pipefail

# Extract the exact production value types; do not maintain a second mock of
# extension outcomes. The UIKit controller itself is compiled by the app build.
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/kexun-share-checks.XXXXXX")"
trap 'rm -f "$check_dir/ShareBatchLogic.swift" "$check_dir/share-checks"; rmdir "$check_dir"' EXIT
{
    printf 'import Foundation\n'
    sed -n '/^\/\/ BEGIN SHARE_BATCH_LOGIC$/,/^\/\/ END SHARE_BATCH_LOGIC$/p' "$project_dir/KexunShare/ShareViewController.swift"
} > "$check_dir/ShareBatchLogic.swift"
xcrun swiftc -parse-as-library \
    "$project_dir/Kexun/Core/CollectionRecord.swift" \
    "$project_dir/Kexun/Core/CollectionRepository.swift" \
    "$check_dir/ShareBatchLogic.swift" \
    "$project_dir/Tests/ShareExtensionChecks.swift" \
    -o "$check_dir/share-checks"
"$check_dir/share-checks"
