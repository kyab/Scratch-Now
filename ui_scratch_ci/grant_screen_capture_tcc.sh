#!/usr/bin/env bash
# Pre-grant the Screen Recording TCC permission to the given executable so
# ffmpeg can capture the screen (with the cursor) for the evidence video
# without a blocking dialog.
#
# Same approach as grant_ui_automation_tcc.sh: on GitHub-hosted runners the
# TCC databases are writable (passwordless sudo, SIP only protects /System),
# so the grant is inserted directly and tccd is restarted.
#
# Usage: grant_screen_capture_tcc.sh <executable-path>
set -uo pipefail

CLIENT_PATH="${1:?usage: grant_screen_capture_tcc.sh <executable-path>}"

USER_TCC="${HOME}/Library/Application Support/com.apple.TCC/TCC.db"
SYSTEM_TCC="/Library/Application Support/com.apple.TCC/TCC.db"

log() { echo "[tcc-screen] $*"; }

# auth_value=2 -> allowed, client_type=1 -> absolute executable path.
grant_in_db() {
  local db="$1"
  local sudo_prefix="$2"
  local service="$3"
  local now
  now="$(date +%s)"

  ${sudo_prefix} sqlite3 "${db}" \
    "INSERT OR REPLACE INTO access
       (service, client, client_type, auth_value, auth_reason, auth_version,
        indirect_object_identifier_type, indirect_object_identifier, flags, last_modified)
     VALUES
       ('${service}', '${CLIENT_PATH}', 1, 2, 2, 1, 0, 'UNUSED', 0, ${now});" 2>/dev/null
}

granted_any=0

for service in kTCCServiceScreenCapture; do
  log "granting ${service} to ${CLIENT_PATH}"
  if grant_in_db "${SYSTEM_TCC}" "sudo" "${service}"; then
    log "system TCC.db grant applied (${service})"
    granted_any=1
  else
    log "system TCC.db grant failed (${service})"
  fi
  if grant_in_db "${USER_TCC}" "" "${service}"; then
    granted_any=1
  fi
done

if [ "${granted_any}" -eq 1 ]; then
  sudo launchctl stop com.apple.tccd 2>/dev/null || true
  launchctl stop com.apple.tccd 2>/dev/null || true
  sleep 1
  exit 0
fi

log "no TCC grant could be applied; screen capture may be blocked"
exit 0
