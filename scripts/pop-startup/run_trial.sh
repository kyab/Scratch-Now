#!/usr/bin/env bash
# Phase 0 pop-startup harness. Records Background Music via sox coreaudio,
# plays longnote_C.wav, launches Scratch Now for 3s, then runs automatic
# discontinuity detection. Set NO_APP=1 for a tone-only capture baseline.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TRIAL_ID="${1:-T0}"
OUT_ROOT="${OUT_ROOT:-/tmp/scratch-now-pop-startup}"
OUT_DIR="${OUT_ROOT}/${TRIAL_ID}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
SCHEME="Scratch Now"

log() { echo "[pop-startup] $*"; }

mkdir -p "${OUT_DIR}"

NO_APP="${NO_APP:-0}"
CAPTURE_ARGS=(
  --trial "${TRIAL_ID}"
  --out-dir "${OUT_DIR}"
  --detect-script "${SCRIPT_DIR}/detect_pop.py"
)

if [ "${NO_APP}" = "1" ]; then
  CAPTURE_ARGS+=(--no-app)
  log "trial=${TRIAL_ID} (no-app baseline)"
  log "out=${OUT_DIR}"
else
  if [ -n "${APP_PATH:-}" ]; then
    :
  else
    APP_PATH="$(
      xcodebuild -project "${REPO_ROOT}/Scratch Now.xcodeproj" \
        -scheme "${SCHEME}" -configuration Release \
        -destination 'platform=macOS' -showBuildSettings 2>/dev/null \
        | awk -F' = ' '/BUILT_PRODUCTS_DIR/ {print $2; exit}'
    )/Scratch Now.app"
  fi
  if [ ! -d "${APP_PATH}" ]; then
    log "ERROR: Release app not found at ${APP_PATH}"
    log "Build it first (Phase 0 does not modify app code):"
    log "  xcodebuild -project \"Scratch Now.xcodeproj\" -scheme \"Scratch Now\" -configuration Release -destination 'platform=macOS' build"
    exit 1
  fi
  CAPTURE_ARGS+=(--app "${APP_PATH}")
  log "trial=${TRIAL_ID}"
  log "app=${APP_PATH}"
  log "out=${OUT_DIR}"
fi

"${PYTHON_BIN}" "${SCRIPT_DIR}/run_capture.py" "${CAPTURE_ARGS[@]}"
