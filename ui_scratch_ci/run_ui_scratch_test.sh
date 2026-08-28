#!/usr/bin/env bash
# UI scratch E2E test orchestrator.
#
# Browser-test style end-to-end check of the scratch audio effect:
#   1. Play a steady 220 Hz tone from a separate process (tap source).
#   2. Launch the SCRATCH_NOW_TAP_SMOKE_CI build of Scratch Now. It logs the
#      turntable geometry (ui.jsonl), the rendered output audio (output.jsonl)
#      and the scratch DSP state (scratch.jsonl).
#   3. drive_scratch.py posts real CGEvents that press and rotate the platter
#      (reverse -1x, then forward 2x) exactly like a human scratching.
#   4. assert_scratch_effect.py checks that the output pitch followed the
#      platter: ~220 Hz at 1x, non-silent reversed playback, ~440 Hz at 2x,
#      and back to ~220 Hz after release.
#
# Decoupled from the GitHub Actions YAML so it can run on a local MacBook too.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

BUNDLE_ID="com.kyab.Scratch-Now"
SCHEME="Scratch Now"
STATUS_DIR="/tmp/scratch-now-tap-smoke-ci"
DERIVED_DIR="${DERIVED_DIR:-${REPO_ROOT}/build/ui-scratch-ci}"

PYTHON_BIN="${PYTHON_BIN:-python3}"
TONE_DURATION_SECONDS=90
OUTPUT_WAIT_TIMEOUT=45

TONE_PID=""
RECORD_PID=""
RECORD_STOP_TS=""
FFMPEG_BIN="$(command -v ffmpeg || true)"
FFPROBE_BIN="$(command -v ffprobe || true)"

log() { echo "[ui-scratch] $*"; }

# Stop the evidence screen recording gracefully (SIGINT lets ffmpeg finalize
# the container) and remember the wall-clock stop time for audio alignment.
stop_screen_recording() {
  if [ -z "${RECORD_PID}" ]; then
    return
  fi
  RECORD_STOP_TS="$(${PYTHON_BIN} -c 'import time; print(f"{time.time():.3f}")')"
  kill -INT "${RECORD_PID}" >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if ! kill -0 "${RECORD_PID}" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  kill -9 "${RECORD_PID}" >/dev/null 2>&1 || true
  wait "${RECORD_PID}" 2>/dev/null || true
  RECORD_PID=""
}

cleanup() {
  log "cleaning up"
  stop_screen_recording
  osascript -e "tell application id \"${BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true
  sleep 1
  killall "${SCHEME}" >/dev/null 2>&1 || true

  if [ -n "${TONE_PID}" ]; then
    kill "${TONE_PID}" >/dev/null 2>&1 || true
    wait "${TONE_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if [ "$(uname -s)" != "Darwin" ]; then
  log "ERROR: this E2E test requires macOS (CATap + CGEvent). Host is $(uname -s)."
  exit 1
fi

log "resetting status dir ${STATUS_DIR}"
rm -rf "${STATUS_DIR}"
mkdir -p "${STATUS_DIR}"

# 1) Build the CI variant (same flags as the tap smoke test).
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

# 2) Pre-grant TCC: system audio recording for the app, event posting for the
#    Python driver, screen recording for ffmpeg (evidence video).
bash "${REPO_ROOT}/tap_smoke_ci/grant_audio_capture_tcc.sh" "${BUNDLE_ID}" "${APP_PATH}"
PYTHON_REAL="$(${PYTHON_BIN} -c 'import os, sys; print(os.path.realpath(sys.executable))')"
bash "${SCRIPT_DIR}/grant_ui_automation_tcc.sh" "${PYTHON_REAL}"
if [ -n "${FFMPEG_BIN}" ]; then
  FFMPEG_REAL="$(${PYTHON_BIN} -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "${FFMPEG_BIN}")"
  # TCC/replayd may attribute the capture to the ffmpeg binary (symlink or
  # resolved path), the responsible shell, or the runner provisioner, so
  # pre-approve every plausible client path. Otherwise macOS 15+ pops a
  # '"bash" is requesting to bypass the system private window picker' dialog
  # over the app window mid-test.
  bash "${SCRIPT_DIR}/grant_screen_capture_tcc.sh" \
    "${FFMPEG_BIN}" "${FFMPEG_REAL}" \
    /bin/bash /bin/zsh /bin/sh \
    /usr/local/opt/runner/provisioner/provisioner \
    /opt/off/opt/runner/provisioner/provisioner \
    /opt/hca/hosted-compute-agent
else
  log "WARNING: ffmpeg not found; evidence video disabled"
fi

# 3) Start the steady reference tone (separate process => tap can capture it).
log "starting steady tone playback"
"${PYTHON_BIN}" "${SCRIPT_DIR}/play_steady_tone.py" --duration "${TONE_DURATION_SECONDS}" \
  > "${STATUS_DIR}/tone.log" 2>&1 &
TONE_PID=$!
sleep 1

# 4) Launch Scratch Now via LaunchServices (TCC attribution to the bundle).
log "launching ${SCHEME} via open"
open "${APP_PATH}"

# 5) Wait until the app is actually rendering audio (output.jsonl flowing).
log "waiting for output status stream (max ${OUTPUT_WAIT_TIMEOUT}s)"
elapsed=0
while true; do
  line_count=0
  if [ -f "${STATUS_DIR}/output.jsonl" ]; then
    line_count="$(wc -l < "${STATUS_DIR}/output.jsonl" | tr -d ' ')"
  fi
  if [ "${line_count}" -ge 2 ]; then
    break
  fi
  if [ "${elapsed}" -ge "${OUTPUT_WAIT_TIMEOUT}" ]; then
    log "ERROR: app never started rendering (output.jsonl has ${line_count} lines)"
    exit 1
  fi
  sleep 1
  elapsed=$((elapsed + 1))
done
log "app is rendering audio"

# Make sure the app window is frontmost before posting mouse events.
osascript -e "tell application id \"${BUNDLE_ID}\" to activate" >/dev/null 2>&1 || true
sleep 1

# 6a) Start the evidence screen recording (video only; the runner has no audio
#     loopback device, so the app's rendered audio is dumped as PCM and muxed
#     in afterwards). -capture_cursor makes the synthetic mouse visible.
if [ -n "${FFMPEG_BIN}" ]; then
  SCREEN_IDX="$(${FFMPEG_BIN} -hide_banner -f avfoundation -list_devices true -i "" 2>&1 \
    | sed -n 's/.*\[\([0-9][0-9]*\)\] Capture screen 0.*/\1/p' | head -1)"
  if [ -n "${SCREEN_IDX}" ]; then
    log "starting screen recording (avfoundation device ${SCREEN_IDX}, cursor captured)"
    "${FFMPEG_BIN}" -hide_banner -loglevel warning -y \
      -f avfoundation -capture_cursor 1 -capture_mouse_clicks 1 \
      -pixel_format uyvy422 -framerate 30 -i "${SCREEN_IDX}:none" \
      -c:v libx264 -preset ultrafast -crf 26 -pix_fmt yuv420p \
      "${STATUS_DIR}/screen.mkv" > "${STATUS_DIR}/screen_record.log" 2>&1 &
    RECORD_PID=$!
    sleep 2
    if ! kill -0 "${RECORD_PID}" >/dev/null 2>&1; then
      log "WARNING: screen recording failed to start (see screen_record.log)"
      RECORD_PID=""
    fi
    # macOS 15+ pops a capture-approval dialog over the app even with the TCC
    # grants in place; click its Allow button if it is showing.
    "${PYTHON_BIN}" "${SCRIPT_DIR}/dismiss_capture_prompt.py" 2>&1 \
      | tee "${STATUS_DIR}/dismiss_prompt.log"
    # The dialog stole focus from the app window; re-activate so the synthetic
    # mouse press reaches the turntable view.
    osascript -e "tell application id \"${BUNDLE_ID}\" to activate" >/dev/null 2>&1 || true
    sleep 1
  else
    log "WARNING: no avfoundation screen device found; evidence video disabled"
  fi
fi

# 6) Drive the turntable with synthetic mouse events.
log "driving scratch gestures"
"${PYTHON_BIN}" "${SCRIPT_DIR}/drive_scratch.py" 2>&1 | tee "${STATUS_DIR}/driver.log"
DRIVER_RESULT=${PIPESTATUS[0]}
if [ "${DRIVER_RESULT}" -ne 0 ]; then
  log "ERROR: scratch driver failed (code ${DRIVER_RESULT})"
  exit "${DRIVER_RESULT}"
fi

# 7) Stop the recording, then the app and playback, then assert.
stop_screen_recording

log "stopping app and playback"
osascript -e "tell application id \"${BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true
sleep 1
killall "${SCHEME}" >/dev/null 2>&1 || true
if [ -n "${TONE_PID}" ]; then
  kill "${TONE_PID}" >/dev/null 2>&1 || true
  wait "${TONE_PID}" 2>/dev/null || true
  TONE_PID=""
fi

# 8) Mux the evidence video: screen capture + the app's rendered audio.
if [ -f "${STATUS_DIR}/screen.mkv" ] && [ -f "${STATUS_DIR}/output.pcm" ] \
   && [ -n "${RECORD_STOP_TS}" ] && [ -n "${FFPROBE_BIN}" ]; then
  log "muxing evidence video"
  if "${PYTHON_BIN}" "${SCRIPT_DIR}/make_evidence_video.py" \
       --video "${STATUS_DIR}/screen.mkv" \
       --pcm "${STATUS_DIR}/output.pcm" \
       --pcm-meta "${STATUS_DIR}/output_pcm_meta.json" \
       --out "${STATUS_DIR}/evidence.mp4" \
       --video-stop-ts "${RECORD_STOP_TS}" \
       --ffmpeg "${FFMPEG_BIN}" --ffprobe "${FFPROBE_BIN}"; then
    log "evidence video: ${STATUS_DIR}/evidence.mp4"
    # Keep the artifact lean; the mp4 already contains video + audio.
    rm -f "${STATUS_DIR}/screen.mkv" "${STATUS_DIR}/output.pcm"
  else
    log "WARNING: evidence video muxing failed (raw screen.mkv/output.pcm kept)"
  fi
else
  log "WARNING: evidence video inputs missing; skipping mux"
fi

log "asserting scratch effect on the rendered output"
"${PYTHON_BIN}" "${SCRIPT_DIR}/assert_scratch_effect.py"
RESULT=$?

if [ "${RESULT}" -eq 0 ]; then
  log "SUCCESS: UI scratch E2E test passed"
else
  log "FAILURE: UI scratch E2E test failed (code ${RESULT})"
fi
exit "${RESULT}"
