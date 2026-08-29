#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

# Keep the portable build from silently regressing to the old installed helper
# or localhost admin fallback. This check is source-only and performs no I/O.
if rg -n 'defaultAdminBaseURL|alternateAdminBaseURL|installedWorkerFallbackURL' \
    "$root/OpenClawRefreshWorker/main.swift" "$root/OpenClawWidgetKitPrototype/ContentView.swift" >/dev/null; then
    echo "forbidden legacy worker fallback found" >&2
    exit 1
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/openclaw-widget-config.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

cp "$root/OpenClawWidgetConfiguration.swift" "$tmp/"
cp "$root/scripts/config-probe.swift" "$tmp/main.swift"

swiftc -module-cache-path "$tmp/module-cache" "$tmp/OpenClawWidgetConfiguration.swift" "$tmp/main.swift" -o "$tmp/config-probe"
"$tmp/config-probe" "$root/config.example.json"
