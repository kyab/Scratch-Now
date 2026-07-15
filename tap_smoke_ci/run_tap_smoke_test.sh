#!/usr/bin/env bash
# CATap smoke test orchestrator.
#
# Flow (mirrors the plan's goal):
#   1. Start real-time pleasant audio playback in a separate process.
#   2. Build + launch the SCRATCH_NOW_TAP_SMOKE_CI Scratch Now build; it writes
#      tap status (peak/rms/estimatedHz/frames) to a JSONL file. The played tone
#      changes frequency partway through and we confirm the tap follows it.
#   3. Quit Scratch Now and stop playback, then assert on the captured data.
#
# This script is intentionally decoupled from the GitHub Actions YAML so it can
# be run directly on a local MacBook. See README.md.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

BUNDLE_ID="com.kyab.Scratch-Now"
SCHEME="Scratch Now"
STATUS_DIR="/tmp/scratch-now-tap-smoke-ci"
STATUS_FILE="${STATUS_DIR}/tap.jsonl"
DERIVED_DIR="${DERIVED_DIR:-${REPO_ROOT}/build/tap-smoke-ci}"

# Timing matches tap_smoke_ci/play_pleasant_tone.py fixed constants.
PHASE_A_SECONDS=5.0
GLIDE_SECONDS=1.5
APP_SETTLE_SECONDS=3.0

PYTHON_BIN="${PYTHON_BIN:-python3}"

TONE_PID=""
WATCHER_PID=""

log() { echo "[smoke] $*"; }

cleanup() {
  log "cleaning up"
  # Quit Scratch Now (graceful, then force).
  osascript -e "tell application id \"${BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true
  sleep 1
  killall "${SCHEME}" >/dev/null 2>&1 || true

  if [ -n "${TONE_PID}" ]; then
    kill "${TONE_PID}" >/dev/null 2>&1 || true
    wait "${TONE_PID}" 2>/dev/null || true
  fi
  if [ -n "${WATCHER_PID}" ]; then
    kill "${WATCHER_PID}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# Guard: this test only makes sense on macOS.
if [ "$(uname -s)" != "Darwin" ]; then
  log "ERROR: this smoke test requires macOS (CATap). Host is $(uname -s)."
  exit 1
fi

log "resetting status dir ${STATUS_DIR}"
rm -rf "${STATUS_DIR}"
mkdir -p "${STATUS_DIR}"

# 1) Build the tap-smoke CI variant (macro on, sandbox off, ad-hoc signed).
log "building ${SCHEME} (SCRATCH_NOW_TAP_SMOKE_CI=1)"
xcodebuild \
  -project "${REPO_ROOT}/Scratch Now.xcodeproj" \
  -scheme "${SCHEME}" \
  -configuration Debug \
  -derivedDataPath "${DERIVED_DIR}" \
  build \
  GCC_PREPROCESSOR_DEFINITIONS='$(inherited) SCRATCH_NOW_TAP_SMOKE_CI=1' \
  CODE_SIGN_ENTITLEMENTS='Scratch Now/Scratch_Now_TapSmokeCI.entitlements' \
  CODE_SIGN_IDENTITY='-' \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM='' \
  CODE_SIGNING_ALLOWED=YES \
  ENABLE_HARDENED_RUNTIME=NO \
  | tee "${STATUS_DIR}/xcodebuild.log" \
  || { log "ERROR: build failed"; exit 1; }

APP_PATH="${DERIVED_DIR}/Build/Products/Debug/${SCHEME}.app"
if [ ! -d "${APP_PATH}" ]; then
  log "ERROR: built app not found at ${APP_PATH}"
  exit 1
fi
log "built app: ${APP_PATH}"

# 2) Pre-grant System Audio Recording (TCC) and optionally start the watcher.
GRANT_OUTPUT="$(bash "${SCRIPT_DIR}/grant_audio_capture_tcc.sh" "${BUNDLE_ID}" "${APP_PATH}")"
echo "${GRANT_OUTPUT}"
if [ "${TAP_SMOKE_CI_ENABLE_DIALOG_WATCHER:-0}" = "1" ]; then
  WATCHER_PID="$(echo "${GRANT_OUTPUT}" | tail -n1)"
fi

# 3) Start the real-time pleasant tone (separate process => tap can capture it).
log "starting pleasant tone playback"
"${PYTHON_BIN}" "${SCRIPT_DIR}/play_pleasant_tone.py" \
  > "${STATUS_DIR}/tone.log" 2>&1 &
TONE_PID=$!
sleep 1

# 4) Launch Scratch Now via LaunchServices so TCC attributes capture to the app
#    bundle (a loose binary would be attributed to the terminal -> silent deny).
log "launching ${SCHEME} via open (LaunchServices)"
open "${APP_PATH}"

# Let the app start capturing and let the tone run through both phases.
WAIT_SECONDS="$(${PYTHON_BIN} -c "print(${APP_SETTLE_SECONDS} + ${PHASE_A_SECONDS} + ${GLIDE_SECONDS} + 4.0)")"
log "capturing for ${WAIT_SECONDS}s (phase A -> glide -> phase B)"
sleep "${WAIT_SECONDS}"

# 5) Stop the app and playback (cleanup trap also covers early exits).
log "stopping app and playback"
osascript -e "tell application id \"${BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true
sleep 1
killall "${SCHEME}" >/dev/null 2>&1 || true
if [ -n "${TONE_PID}" ]; then
  kill "${TONE_PID}" >/dev/null 2>&1 || true
  wait "${TONE_PID}" 2>/dev/null || true
  TONE_PID=""
fi

# 6) Assert on the captured tap data.
log "asserting tap capture from ${STATUS_FILE}"
if [ ! -f "${STATUS_FILE}" ]; then
  log "ERROR: no status file; tap delivered no data"
  exit 1
fi

"${PYTHON_BIN}" "${SCRIPT_DIR}/assert_tap_capture.py"
RESULT=$?

if [ "${RESULT}" -eq 0 ]; then
  log "SUCCESS: tap smoke test passed"
else
  log "FAILURE: tap smoke test failed (code ${RESULT})"
fi
exit "${RESULT}"
