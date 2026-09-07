#!/usr/bin/env bash
# Pre-grant the macOS "System Audio Recording" (kTCCServiceAudioCapture)
# permission so the Scratch Now tap smoke build can capture audio without a
# blocking dialog.
#
# Primary path (GitHub-hosted runner): write the grant straight into the user
# and system TCC databases, then restart tccd. GitHub runners allow passwordless
# sudo and SIP only protects /System, so the TCC db write succeeds.
#
# Fallback (local Mac / restricted TCC db): start a background AppleScript
# watcher that clicks the "Allow"/"許可" button if the dialog appears. If the
# grant cannot be applied at all, the caller still runs and surfaces silence as
# a failure; the README explains the one-time manual "Allow" for local Macs.
#
# Usage: grant_audio_capture_tcc.sh <bundle-id> [app-path]
set -uo pipefail

BUNDLE_ID="${1:-com.kyab.Scratch-Now}"
APP_PATH="${2:-}"

SERVICE="kTCCServiceAudioCapture"
USER_TCC="${HOME}/Library/Application Support/com.apple.TCC/TCC.db"
SYSTEM_TCC="/Library/Application Support/com.apple.TCC/TCC.db"

log() { echo "[tcc] $*"; }

# Insert (or replace) an allow grant into the given TCC database. Uses named
# columns so it keeps working as Apple adds columns across macOS versions.
# auth_value=2 -> allowed, client_type=0 -> bundle identifier.
grant_in_db() {
  local db="$1"
  local sudo_prefix="$2"
  local now
  now="$(date +%s)"

  ${sudo_prefix} sqlite3 "${db}" \
    "INSERT OR REPLACE INTO access
       (service, client, client_type, auth_value, auth_reason, auth_version,
        indirect_object_identifier_type, indirect_object_identifier, flags, last_modified)
     VALUES
       ('${SERVICE}', '${BUNDLE_ID}', 0, 2, 2, 1, 0, 'UNUSED', 0, ${now});" 2>/dev/null
}

granted_any=0

log "granting ${SERVICE} to ${BUNDLE_ID}"

# User database (no sudo required).
if grant_in_db "${USER_TCC}" ""; then
  log "user TCC.db grant applied"
  granted_any=1
else
  log "user TCC.db grant failed (may not exist yet)"
fi

# System database (needs sudo; available on GitHub runners).
if grant_in_db "${SYSTEM_TCC}" "sudo"; then
  log "system TCC.db grant applied"
  granted_any=1
else
  log "system TCC.db grant failed (restricted db or no sudo)"
fi

# Restart tccd so the grant is picked up immediately.
if [ "${granted_any}" -eq 1 ]; then
  sudo launchctl stop com.apple.tccd 2>/dev/null || true
  launchctl stop com.apple.tccd 2>/dev/null || true
  sleep 1
fi

# Fallback dialog watcher: spawn only if requested via env. It clicks the
# permission dialog's Allow button for local Macs where the db write is blocked.
if [ "${TAP_SMOKE_CI_ENABLE_DIALOG_WATCHER:-0}" = "1" ]; then
  log "starting AppleScript dialog watcher (fallback)"
  (
    end=$(( $(date +%s) + 30 ))
    while [ "$(date +%s)" -lt "${end}" ]; do
      osascript <<'APPLESCRIPT' >/dev/null 2>&1 || true
tell application "System Events"
  set procs to (every process whose name is "UserNotificationCenter" or name is "coreauthd" or name is "universalAccessAuthWarn")
  repeat with p in procs
    try
      repeat with w in windows of p
        repeat with b in buttons of w
          set bn to name of b
          if bn is "Allow" or bn is "許可" or bn is "OK" then
            click b
          end if
        end repeat
      end repeat
    end try
  end repeat
end tell
APPLESCRIPT
      sleep 1
    done
  ) &
  echo "$!"
fi

if [ "${granted_any}" -eq 1 ]; then
  exit 0
fi

log "no TCC grant could be applied; capture may require manual approval"
# Do not hard-fail: the harness treats persistent silence as the real failure.
exit 0
