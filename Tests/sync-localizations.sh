#!/bin/bash
set -euo pipefail

# Compile Release first; use compiler output, not a regex over Swift source.
# This keeps preview/fixture copy out of the shipping string catalogs.
if [ "$#" -ne 1 ]; then
  echo "Usage: bash Tests/sync-localizations.sh /absolute/DerivedData" >&2
  exit 2
fi
project_root="$(cd "$(dirname "$0")/.." && pwd)"
localization_data="$1/Build/Intermediates.noindex/Kexun.build/Release-iphonesimulator"

for target in Kexun KexunShare; do
  strings_directory="$localization_data/$target.build/Objects-normal/arm64"
  if [ ! -d "$strings_directory" ]; then
    echo "Missing Release compiler strings: $strings_directory" >&2
    exit 1
  fi
  localization_inputs=()
  while IFS= read -r input; do
    localization_inputs+=("$input")
  done < <(rg --files "$strings_directory" -g '*.stringsdata' | sort)
  if [ "${#localization_inputs[@]}" -eq 0 ]; then
    echo "No compiler strings for $target; enable SWIFT_EMIT_LOC_STRINGS." >&2
    exit 1
  fi
  xcrun xcstringstool sync "$project_root/$target/Localizable.xcstrings" --stringsdata "${localization_inputs[@]}"
  node "$project_root/Tests/materialize-source-localizations.mjs" "$project_root/$target/Localizable.xcstrings"
done
