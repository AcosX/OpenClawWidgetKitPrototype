#!/bin/zsh
set -euo pipefail

label="local.openclaw.sub2api-refresh"
uid="$(id -u)"
domain="gui/${uid}"
source_plist="${0:A:h}/../launchd/${label}.plist"
target_dir="${HOME}/Library/LaunchAgents"
target_plist="${target_dir}/${label}.plist"
app_path="${OPENCLAW_APP_PATH:-/Applications/OpenClawWidgetKitPrototype.app}"
[[ "${app_path}" == /* ]] || { print -u2 "OPENCLAW_APP_PATH must be an absolute path"; exit 64; }
[[ "${app_path}" != *$'\n'* ]] || { print -u2 "OPENCLAW_APP_PATH must not contain newlines"; exit 64; }
worker="${app_path}/Contents/Helpers/Sub2APIRefreshWorker"
[[ -x "${worker}" ]] || { print -u2 "Worker is not installed or executable: ${worker}"; exit 66; }
runtime_dir="$("${worker}" --print-data-directory)"
[[ "${runtime_dir}" == /* ]] || { print -u2 "Worker returned a non-absolute data directory: ${runtime_dir}"; exit 65; }
[[ "${runtime_dir}" != *$'\n'* ]] || { print -u2 "Worker returned an invalid data directory"; exit 65; }
stdout_log="${runtime_dir}/sub2api-refresh-launchd.out.log"
stderr_log="${runtime_dir}/sub2api-refresh-launchd.err.log"

sed_escape() {
    print -r -- "$1" | /usr/bin/sed 's/[\\&|]/\\&/g'
}

/usr/bin/plutil -lint "${source_plist}" >/dev/null
/bin/mkdir -p -m 700 "${runtime_dir}"
/bin/chmod 700 "${runtime_dir}"
/usr/bin/touch "${stdout_log}" "${stderr_log}"
/bin/chmod 600 "${stdout_log}" "${stderr_log}"
/bin/mkdir -p "${target_dir}"
runtime_replacement="$(sed_escape "${runtime_dir}")"
worker_replacement="$(sed_escape "${worker}")"
/usr/bin/sed -e "s|__RUNTIME_DIR__|${runtime_replacement}|g" -e "s|__WORKER_PATH__|${worker_replacement}|g" "${source_plist}" > "${target_plist}"
/bin/chmod 600 "${target_plist}"
/bin/launchctl bootout "${domain}/${label}" 2>/dev/null || true
/bin/launchctl bootstrap "${domain}" "${target_plist}"
/bin/launchctl enable "${domain}/${label}"
/bin/launchctl kickstart "${domain}/${label}"
/bin/launchctl print "${domain}/${label}"
