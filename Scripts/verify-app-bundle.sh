#!/bin/bash
set -euo pipefail

app_path="${1:?Usage: verify-app-bundle.sh path/to/LogicPluginSweeper.app}"
binary_path="$app_path/Contents/MacOS/LogicPluginSweeper"
resource_bundle="$app_path/Contents/Resources/LogicPluginSweeper_LogicPluginSweeper.bundle"

test -d "$app_path" || { printf '%s\n' "Missing app bundle: $app_path"; exit 1; }
test -x "$binary_path" || { printf '%s\n' "Missing executable: $binary_path"; exit 1; }
test -d "$resource_bundle" || { printf '%s\n' "Missing SwiftPM resource bundle: $resource_bundle"; exit 1; }
test -f "$resource_bundle/fr.lproj/Localizable.strings" || { printf '%s\n' "Missing French localization"; exit 1; }
test -f "$resource_bundle/en.lproj/Localizable.strings" || { printf '%s\n' "Missing English localization"; exit 1; }
if [[ ! -f "$resource_bundle/branding/LogicPluginSweeper-logo.jpeg" && ! -f "$resource_bundle/LogicPluginSweeper-logo.jpeg" ]]; then
    printf '%s\n' "Missing application logo"
    find "$resource_bundle" -maxdepth 2 -type f -print
    exit 1
fi
test -f "$app_path/Contents/Resources/LogicPluginSweeper.icns" || { printf '%s\n' "Missing application icon"; exit 1; }
plutil -lint "$app_path/Contents/Info.plist" || { printf '%s\n' "Invalid Info.plist"; exit 1; }

binary_type=$(file "$binary_path")
printf '%s\n' "$binary_type"
printf '%s\n' "$binary_type" | grep -Eq 'arm64(e)?' || { printf '%s\n' "The executable is not an Apple Silicon binary"; exit 1; }

set +e
"$binary_path" >/tmp/LogicPluginSweeper-startup.log 2>&1 &
app_pid=$!
set -e
sleep 5

if ! kill -0 "$app_pid" 2>/dev/null; then
    set +e
    wait "$app_pid"
    startup_status=$?
    set -e
    cat /tmp/LogicPluginSweeper-startup.log
    printf '%s\n' "The packaged app exited during its startup smoke test (status $startup_status)."
    exit 1
fi

kill -TERM "$app_pid" 2>/dev/null || true
wait "$app_pid" 2>/dev/null || true
