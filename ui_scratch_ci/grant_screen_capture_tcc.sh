#!/usr/bin/env bash
# Pre-grant the Screen Recording permission to the given executables so ffmpeg
# can capture the screen (with the cursor) for the evidence video without a
# blocking dialog.
#
# Two mechanisms are needed (proven combination used by other projects doing
# E2E screen recording on macOS runners, e.g. manaflow-ai/cmux PR #784, and by
# the runner image itself in actions/runner-images configure-tccdb-macos.sh):
#   1. kTCCServiceScreenCapture rows in the TCC databases (same approach as
#      grant_ui_automation_tcc.sh). TCC attributes the request to the
#      *responsible* process — for scripted job steps this can be the shell or
#      the runner provisioner binary — so grant every plausible client path.
#   2. On macOS 15+ the legacy capture APIs (AVCaptureScreenInput) addition-
#      ally trigger the "requesting to bypass the system private window
#      picker" prompt managed by replayd. Its approvals live in
#      ScreenCaptureApprovals.plist keyed by executable path with an expiry
#      date, so a far-future entry silences the prompt
#      (https://lapcatsoftware.com/articles/2024/8/10.html).
#
# Usage: grant_screen_capture_tcc.sh <executable-path> [<executable-path>...]
set -uo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: grant_screen_capture_tcc.sh <executable-path> [...]" >&2
  exit 1
fi

USER_TCC="${HOME}/Library/Application Support/com.apple.TCC/TCC.db"
SYSTEM_TCC="/Library/Application Support/com.apple.TCC/TCC.db"
APPROVALS_DIR="${HOME}/Library/Group Containers/group.com.apple.replayd"
APPROVALS_PLIST="${APPROVALS_DIR}/ScreenCaptureApprovals.plist"

log() { echo "[tcc-screen] $*"; }

# auth_value=2 -> allowed, client_type=1 -> absolute executable path.
grant_in_db() {
  local db="$1"
  local sudo_prefix="$2"
  local client="$3"
  local now
  now="$(date +%s)"

  ${sudo_prefix} sqlite3 "${db}" \
    "INSERT OR REPLACE INTO access
       (service, client, client_type, auth_value, auth_reason, auth_version,
        indirect_object_identifier_type, indirect_object_identifier, flags, last_modified)
     VALUES
       ('kTCCServiceScreenCapture', '${client}', 1, 2, 2, 1, 0, 'UNUSED', 0, ${now});" 2>/dev/null
}

mkdir -p "${APPROVALS_DIR}" 2>/dev/null || true

for client in "$@"; do
  log "granting kTCCServiceScreenCapture to ${client}"
  grant_in_db "${SYSTEM_TCC}" "sudo" "${client}" \
    && log "system TCC.db grant applied" \
    || log "system TCC.db grant failed"
  grant_in_db "${USER_TCC}" "" "${client}" || true

  log "pre-approving legacy screen capture (replayd) for ${client}"
  defaults write "${APPROVALS_PLIST}" "${client}" -date "3024-01-01 00:00:00 +0000" \
    2>/dev/null || log "replayd approval write failed for ${client}"
done

sudo launchctl stop com.apple.tccd 2>/dev/null || true
launchctl stop com.apple.tccd 2>/dev/null || true
killall -9 replayd 2>/dev/null || true
sleep 1
exit 0
