#!/bin/bash
# Renders widget views to PNG without adding them to the desktop, so clipped or
# wrapping text is visible (desktop widgets are usually covered by windows).
# Usage: Tools/render-preview.sh [output dir] [args passed to the renderer]
#   e.g. Tools/render-preview.sh build/preview -AppleLocale en_US -AppleLanguages "(en)"
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:-$root/build/preview}"
shift || true
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp "$root"/Sources/Shared/*.swift "$work/"
cp "$root"/Sources/Widget/*.swift "$work/"
# The WidgetBundle's @main clashes with the CLI entry point.
sed 's/^@main$//' "$root/Sources/Widget/PanoWidgets.swift" > "$work/PanoWidgets.swift"
cp "$root/Tools/preview/main.swift" "$work/"
swiftc -O "$work"/*.swift -o "$work/prev"
mkdir -p "$out"
(cd "$out" && "$work/prev" "$@")
echo "→ $out"
