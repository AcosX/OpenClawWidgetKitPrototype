#!/bin/zsh
set -euo pipefail

label="local.openclaw.sub2api-refresh"
domain="gui/$(id -u)"
target_plist="${HOME}/Library/LaunchAgents/${label}.plist"

/bin/launchctl bootout "${domain}/${label}" 2>/dev/null || true
if [[ -e "${target_plist}" ]]; then
    /usr/bin/trash "${target_plist}" 2>/dev/null || /bin/rm -f "${target_plist}"
fi
