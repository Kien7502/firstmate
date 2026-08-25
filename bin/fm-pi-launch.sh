#!/usr/bin/env bash
# fm-pi-launch.sh - canonical captain-facing entry point for starting or
# restarting the Firstmate PRIMARY session on Pi or pi-signed.
#
# WHY THIS EXISTS: `pi`/`pi-signed` auto-discover .pi/extensions/*.ts only
# when the process cwd IS this repo root AND the directory is already
# trusted. Either condition failing silently - a restart from a different
# shell/cwd, or a declined/reset trust decision - starts an ORDINARY Pi
# session with neither required primary extension loaded. That failure is
# doubly silent because the native session-start nudge
# (docs/sessionstart-nudge.md) is ITSELF delivered by the turn-end guard
# extension, so a missing extension also means bin/fm-session-start.sh's own
# PI_WATCH_EXTENSION diagnostic never gets a chance to run and warn about it.
#
# This script removes both failure modes for good: it always execs pi from
# the resolved repo root regardless of invocation cwd, and always passes both
# required primary extensions by absolute -e path. An explicit -e path loads
# unconditionally regardless of project trust (a documented trust-free
# fallback), and empirically does not double-load when the directory is also
# trusted - Pi dedupes an explicit -e path against its own discovery of the
# same resolved file (tests/fm-pi-launch.test.sh records the live proof).
# Every other project file (AGENTS.md, skills, the optional fm-calm.ts /
# fm-pending-command-footer.ts extensions) keeps its ordinary discovery and
# trust-dialog behavior untouched, so a genuinely new clone still shows the
# normal one-time trust prompt.
#
# Usage:
#   bin/fm-pi-launch.sh                 Start a fresh Firstmate session
#                                        (default; same shape as the README's
#                                        prior bare `pi`).
#   bin/fm-pi-launch.sh --resume        Resume the most recent Firstmate Pi
#                                        conversation for THIS repo (adds
#                                        pi's own --continue, which is scoped
#                                        per project directory).
#   bin/fm-pi-launch.sh --signed        Launch the pi-signed wrapper identity
#                                        instead of plain pi. An ambient
#                                        FM_PI_HARNESS=pi-signed does the same
#                                        without the flag.
#   bin/fm-pi-launch.sh --print-command Print the resolved command instead of
#                                        executing it: a safe dry run and the
#                                        test seam for the regression suite.
#   Any other argument passes through to pi unchanged (e.g. --model,
#   --thinking).
#
# This script owns launch/restart mechanics only. It never arms or touches
# watcher supervision - that stays entirely extension-owned
# (.pi/extensions/fm-primary-pi-watch.ts, docs/supervision-protocols/pi.md) so
# there is exactly one place a watcher cycle can ever be started from.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

TURNEND_EXT="$FM_ROOT/.pi/extensions/fm-primary-turnend-guard.ts"
WATCH_EXT="$FM_ROOT/.pi/extensions/fm-primary-pi-watch.ts"

usage() {
  sed -n '2,43p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

EXECUTABLE=pi
[ "${FM_PI_HARNESS:-}" = pi-signed ] && EXECUTABLE=pi-signed
RESUME=0
PRINT_ONLY=0
EXTRA_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --resume|--continue) RESUME=1 ;;
    --signed) EXECUTABLE=pi-signed ;;
    --print-command) PRINT_ONLY=1 ;;
    -h|--help) usage; exit 0 ;;
    --)
      shift
      while [ $# -gt 0 ]; do EXTRA_ARGS+=("$1"); shift; done
      break
      ;;
    *) EXTRA_ARGS+=("$1") ;;
  esac
  shift
done

if [ "$EXECUTABLE" = pi-signed ] && ! command -v pi-signed >/dev/null 2>&1; then
  echo "error: pi-signed executable not found on PATH; install the signed Pi wrapper or run without --signed" >&2
  exit 1
fi

for ext in "$TURNEND_EXT" "$WATCH_EXT"; do
  if [ ! -f "$ext" ]; then
    echo "error: required primary extension missing: $ext (corrupt or non-Firstmate checkout?)" >&2
    exit 1
  fi
done

CMD=("$EXECUTABLE" -e "$TURNEND_EXT" -e "$WATCH_EXT")
[ "$RESUME" -eq 1 ] && CMD+=(--continue)
if [ "${#EXTRA_ARGS[@]}" -gt 0 ]; then
  CMD+=("${EXTRA_ARGS[@]}")
fi

if [ "$PRINT_ONLY" -eq 1 ]; then
  printf 'FM_PI_HARNESS=%q ' "$EXECUTABLE"
  printf '%q ' "${CMD[@]}"
  printf '\n'
  exit 0
fi

cd "$FM_ROOT" || exit 1
export FM_PI_HARNESS="$EXECUTABLE"
exec "${CMD[@]}"
