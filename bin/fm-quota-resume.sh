#!/usr/bin/env bash
# fm-quota-resume.sh - schedule and execute one automatic resume of paused work
# at the verified Claude five-hour (session) quota reset.
#
# A five-hour / session usage limit is a bounded external wait, not a wedge: the
# recorded work clears on its own when that window resets. This script turns that
# wait into a durable, deterministic, idempotent plan.
#
#   schedule  reads current `quota-axi --json`, takes the Claude SESSION window's
#             own resetsAt, and sets the resume time to that reset plus exactly
#             five minutes. The seven-day / weekly window is never substituted,
#             and missing or malformed quota data refuses to schedule anything.
#             It records the paused task ids, adds one safe display item to the
#             pending-command footer, and arms a registered watcher check so
#             firstmate is woken once, when the resume is actually due.
#   due       the armed watcher check body: prints one line once the recorded
#             resume time has passed and nothing at all before it. It reads only
#             the local record, so it never calls quota-axi or the network.
#   resume    refuses before the recorded due time, re-verifies against fresh
#             quota data that the session window really rolled, steers only the
#             tasks the record names, and then retires the record, the footer
#             item, and the check.
#   status    print the current plan, or `idle`.
#   clear     retire the plan without resuming anything.
#
# It never changes, upgrades, or recommends a plan; never reads, writes, or
# prints credentials, account identifiers, or balances; and records only a
# window descriptor, timestamps, and firstmate-local task ids.
#
# Usage:
#   fm-quota-resume.sh schedule [--task <id>]... [--quota-json <path>]
#   fm-quota-resume.sh status
#   fm-quota-resume.sh due
#   fm-quota-resume.sh resume [--quota-json <path>]
#   fm-quota-resume.sh clear
#   fm-quota-resume.sh --help
#
# `--quota-json <path>` reads an already-captured quota-axi document instead of
# running the tool, so one snapshot can be reused and so tests need no network.
#
# Exit status:
#   0  scheduled, already-scheduled, already-reset, resumed, idle, cleared
#   1  quota data unavailable or malformed, arming failed, resume refused
#      (not yet due, or the session window has not actually reset), or some
#      recorded task could not be steered
#   2  invalid request
#
# Idempotence: `schedule` run twice against the same session window keeps one
# record, one footer item, and one armed check, unioning any newly named tasks;
# `resume` after a completed resume reports `idle`; `clear` on a clear home
# reports `idle`. A partly failed resume keeps only the still-unresumed tasks in
# the record, so a retry steers exactly the remainder.
#
# Recorded paused work is never dropped on the floor. When current data shows a
# different session window than the record was waiting on, any task the old plan
# still named is carried into the new wait. When current data shows no future
# reset left at all, an existing plan is kept and reported as due now rather than
# retired, and a freshly named task is echoed back as work to resume immediately.
#
# The watcher re-runs the armed check every FM_CHECK_INTERVAL, so a due resume is
# re-announced until it is executed or cleared; a missed wake is never lost, and
# the durable wake queue collapses the repeats into one pending record.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

# The reserved identity of this home's single quota-resume plan. It is a valid
# task id so the ordinary registered-custom-check path applies unchanged, and
# schedule refuses if a real task ever claims the same name.
CHECK_ID=quota-resume
RECORD="$STATE/$CHECK_ID.record"
CHECK="$STATE/$CHECK_ID.check.sh"
TRUST="$STATE/$CHECK_ID.check-trust"
SCHEDULE_FILE="$STATE/scheduled-commands.json"

# The contract, not a knob: the resume is the verified session reset plus five
# minutes, so clock skew or a lazily-refreshed window cannot resume early.
GRACE_SECS=300
FOOTER_LABEL='Resume paused work at Claude limit reset'
RESUME_TEXT='Claude session quota has reset - resume your paused work and continue.'
DUE_LINE='quota-resume due: Claude session limit has reset; resume the recorded paused work'

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() {  # <message> [<exit-code>]
  printf 'fm-quota-resume: %s\n' "$1" >&2
  exit "${2:-1}"
}

is_uint() {
  case "${1-}" in
    ''|*[!0-9]*) return 1 ;;
  esac
}

now_epoch() {
  # FM_QUOTA_RESUME_NOW is a fixed-clock test seam; anything that is not a whole
  # number of seconds is ignored rather than trusted.
  if is_uint "${FM_QUOTA_RESUME_NOW:-}"; then
    printf '%s\n' "$FM_QUOTA_RESUME_NOW"
    return 0
  fi
  date +%s
}

# --- quota reading ----------------------------------------------------------

# Extract the Claude SESSION window's reset from a quota-axi document and derive
# the resume time. Prints one tab-separated record on stdout, always exit 0:
#   ok<TAB><resetsAt><TAB><resetEpoch><TAB><dueEpoch><TAB><dueIso>
#   error<TAB><reason>
# The weekly window is excluded explicitly rather than accepted as a fallback: a
# seven-day reset would park real work for days. A reset stamp without an
# explicit Z or numeric offset is refused too, because reading it in the local
# zone could place the resume hours early.
QUOTA_PARSE_JS='
const fs = require("fs");
const [path, graceRaw] = process.argv.slice(1);
const grace = Number(graceRaw);
const out = (...f) => { process.stdout.write(f.join("\t") + "\n"); process.exit(0); };
if (!Number.isInteger(grace) || grace < 0) out("error", "bad-grace");
let raw;
try { raw = fs.readFileSync(path, "utf8"); } catch { out("error", "unreadable"); }
let data;
try { data = JSON.parse(raw); } catch { out("error", "malformed-json"); }
if (!data || typeof data !== "object" || !Array.isArray(data.providers)) out("error", "malformed-json");
const claude = data.providers.find((p) => p && p.provider === "claude");
if (!claude) out("error", "no-claude-provider");
const windows = Array.isArray(claude.windows) ? claude.windows : [];
const weekly = (w) => w.id === "seven_day" || w.kind === "weekly";
const session = windows.filter((w) => w && typeof w === "object" && !weekly(w));
const chosen = session.find((w) => w.id === "five_hour") || session.find((w) => w.kind === "session");
if (!chosen) out("error", "no-session-window");
const resetsAt = typeof chosen.resetsAt === "string" ? chosen.resetsAt : "";
const unambiguous = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:?\d{2})$/;
if (!unambiguous.test(resetsAt)) out("error", "bad-reset-timestamp");
const ms = Date.parse(resetsAt);
if (!Number.isFinite(ms)) out("error", "bad-reset-timestamp");
// Round the reset UP to the next whole second so a sub-second remainder can
// never shave the resume time below the real reset plus five minutes.
const resetEpoch = Math.ceil(ms / 1000);
const dueEpoch = resetEpoch + grace;
out("ok", resetsAt, String(resetEpoch), String(dueEpoch), new Date(dueEpoch * 1000).toISOString());
'

# Rewrite the pending-command footer document, preserving every item this script
# does not own. Arguments: <source-or-empty> <out> <label> <due-iso-or-empty>.
# A missing or malformed source starts from an empty list: that file is display
# only, so unreadable local data must never block the resume plan.
FOOTER_WRITE_JS='
const fs = require("fs");
const [src, out, label, due] = process.argv.slice(1);
let items = [];
if (src) {
  try {
    const parsed = JSON.parse(fs.readFileSync(src, "utf8"));
    if (parsed && typeof parsed === "object" && Array.isArray(parsed.items)) items = parsed.items;
  } catch { items = []; }
}
const kept = items.filter((i) => !i || typeof i !== "object" || i.label !== label);
if (due) kept.push({ label, due, state: "pending" });
fs.writeFileSync(out, JSON.stringify({ version: 1, items: kept }, null, 2) + "\n");
'

require_node() {
  command -v node >/dev/null 2>&1 \
    || die "node is required to read quota data and the scheduled-command footer"
}

# Resolve a quota-axi document into the QUOTA_* globals. Returns non-zero with
# QUOTA_ERROR set to a short machine reason. The document itself is never
# echoed: it carries account detail that has no place in a wake line, a footer,
# or a durable record.
QUOTA_ERROR=
QUOTA_RESETS_AT=
QUOTA_RESET_EPOCH=
QUOTA_DUE_EPOCH=
QUOTA_DUE_AT=
quota_read() {  # [<captured-json-path>]
  local source=${1:-} tmp='' result status field
  QUOTA_ERROR=
  QUOTA_RESETS_AT=
  QUOTA_RESET_EPOCH=
  QUOTA_DUE_EPOCH=
  QUOTA_DUE_AT=
  require_node
  if [ -n "$source" ]; then
    [ -f "$source" ] || { QUOTA_ERROR=unreadable; return 1; }
  else
    command -v quota-axi >/dev/null 2>&1 || { QUOTA_ERROR=quota-axi-missing; return 1; }
    tmp=$(mktemp "${TMPDIR:-/tmp}/fm-quota-axi.XXXXXX") || { QUOTA_ERROR=temp-unavailable; return 1; }
    if ! quota-axi --json > "$tmp" 2>/dev/null; then
      rm -f -- "$tmp"
      QUOTA_ERROR=quota-axi-failed
      return 1
    fi
    source=$tmp
  fi
  result=$(node -e "$QUOTA_PARSE_JS" "$source" "$GRACE_SECS" 2>/dev/null)
  status=$?
  [ -z "$tmp" ] || rm -f -- "$tmp"
  if [ "$status" -ne 0 ]; then
    QUOTA_ERROR=quota-parse-failed
    return 1
  fi
  IFS=$'\t' read -r field QUOTA_RESETS_AT QUOTA_RESET_EPOCH QUOTA_DUE_EPOCH QUOTA_DUE_AT <<< "$result"
  if [ "${field:-}" != ok ]; then
    QUOTA_ERROR=${QUOTA_RESETS_AT:-malformed-json}
    QUOTA_RESETS_AT=
    return 1
  fi
  if ! is_uint "$QUOTA_RESET_EPOCH" || ! is_uint "$QUOTA_DUE_EPOCH" \
    || [ -z "$QUOTA_RESETS_AT" ] || [ -z "$QUOTA_DUE_AT" ]; then
    QUOTA_ERROR=bad-reset-timestamp
    return 1
  fi
}

# --- durable record ---------------------------------------------------------

REC_RESETS_AT=
REC_RESET_EPOCH=
REC_DUE_EPOCH=
REC_DUE_AT=
REC_TASKS=
record_read() {
  local line key value id
  REC_RESETS_AT=
  REC_RESET_EPOCH=
  REC_DUE_EPOCH=
  REC_DUE_AT=
  REC_TASKS=
  [ -f "$RECORD" ] && [ ! -L "$RECORD" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    key=${line%%=*}
    value=${line#*=}
    [ "$key" != "$line" ] || continue
    case "$key" in
      resets_at) REC_RESETS_AT=$value ;;
      reset_epoch) REC_RESET_EPOCH=$value ;;
      due_epoch) REC_DUE_EPOCH=$value ;;
      due_at) REC_DUE_AT=$value ;;
      tasks) REC_TASKS=$value ;;
    esac
  done < "$RECORD"
  # A record that cannot be trusted is treated as absent, so schedule replaces it
  # and resume refuses rather than steering on a half-read plan.
  is_uint "$REC_RESET_EPOCH" && is_uint "$REC_DUE_EPOCH" || return 1
  [ -n "$REC_RESETS_AT" ] && [ -n "$REC_DUE_AT" ] || return 1
  # shellcheck disable=SC2086 # tasks is a deliberate space-separated id list.
  for id in $REC_TASKS; do
    fm_task_id_path_safe "$id" && [ "${#id}" -le 64 ] || return 1
  done
}

record_write() {  # <resets-at> <reset-epoch> <due-epoch> <due-at> <tasks>
  local tmp
  tmp=$(mktemp "$STATE/.fm-quota-resume.XXXXXX") || return 1
  {
    printf 'version=1\n'
    printf 'provider=claude\n'
    printf 'window=session\n'
    printf 'resets_at=%s\n' "$1"
    printf 'reset_epoch=%s\n' "$2"
    printf 'due_epoch=%s\n' "$3"
    printf 'due_at=%s\n' "$4"
    printf 'tasks=%s\n' "$5"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$RECORD"
}

# --- footer item ------------------------------------------------------------

footer_set() {  # <due-iso-or-empty>
  local due=${1:-} src='' tmp
  if [ -f "$SCHEDULE_FILE" ] && [ ! -L "$SCHEDULE_FILE" ]; then
    src=$SCHEDULE_FILE
  elif [ -z "$due" ]; then
    # Nothing to retire and nothing to preserve.
    return 0
  fi
  require_node
  tmp=$(mktemp "$STATE/.fm-scheduled-commands.XXXXXX") || return 1
  node -e "$FOOTER_WRITE_JS" "$src" "$tmp" "$FOOTER_LABEL" "$due" 2>/dev/null \
    || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$SCHEDULE_FILE"
}

# --- watcher check ----------------------------------------------------------

shell_quote() {  # <text>
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

check_armed() {
  fm_custom_check_registered "$STATE" "$CHECK_ID"
}

check_arm() {
  local tmp self home
  self=$(shell_quote "$SCRIPT_DIR/fm-quota-resume.sh")
  home=$(shell_quote "$FM_HOME")
  tmp=$(mktemp "$STATE/.fm-quota-check.XXXXXX") || return 1
  {
    printf '#!/usr/bin/env bash\n'
    printf '# Generated by fm-quota-resume.sh; do not edit by hand.\n'
    printf '# Prints one line once the recorded quota resume is due, nothing before it.\n'
    printf 'set -u\n'
    printf 'FM_HOME=%s exec %s due\n' "$home" "$self"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0700 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$CHECK" || return 1
  "$SCRIPT_DIR/fm-check-register.sh" "$CHECK_ID" >/dev/null || return 1
}

plan_retire() {
  footer_set '' || return 1
  rm -f -- "$CHECK" "$TRUST"
  rm -f -- "$RECORD"
}

# --- task list helpers ------------------------------------------------------

# Union two space-separated id lists, preserving first-seen order so a repeated
# schedule produces a byte-identical record.
task_union() {  # <existing> <added>
  local id seen='' out=''
  # shellcheck disable=SC2086 # both arguments are deliberate id lists.
  for id in $1 $2; do
    case " $seen " in
      *" $id "*) continue ;;
    esac
    seen="$seen $id"
    out="${out:+$out }$id"
  done
  printf '%s' "$out"
}

task_count() {  # <list>
  local id n=0
  # shellcheck disable=SC2086 # deliberate id list.
  for id in $1; do
    [ -n "$id" ] && n=$((n + 1))
  done
  printf '%s' "$n"
}

# --- subcommands ------------------------------------------------------------

cmd_schedule() {
  local quota_json='' tasks='' id now merged had_record=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --task)
        [ "$#" -ge 2 ] || die "--task needs a task id" 2
        id=$2
        fm_task_id_path_safe "$id" && [ "${#id}" -le 64 ] || die "invalid task id" 2
        tasks=$(task_union "$tasks" "$id")
        shift 2
        ;;
      --quota-json)
        [ "$#" -ge 2 ] || die "--quota-json needs a path" 2
        quota_json=$2
        shift 2
        ;;
      *) die "unknown schedule option: $1" 2 ;;
    esac
  done

  [ -d "$STATE" ] && [ ! -L "$STATE" ] || die "state directory is unavailable"
  # The plan borrows one reserved task-id slot; a real task by that name owns its
  # own check artifacts, so refuse rather than fight it for them.
  [ ! -e "$STATE/$CHECK_ID.meta" ] \
    || die "a task named $CHECK_ID already owns this home's check slot"

  quota_read "$quota_json" \
    || die "current quota data is unavailable or malformed ($QUOTA_ERROR); nothing scheduled"

  now=$(now_epoch)

  if record_read; then
    had_record=1
    if [ "$REC_RESETS_AT" = "$QUOTA_RESETS_AT" ]; then
      merged=$(task_union "$REC_TASKS" "$tasks")
      if [ "$merged" != "$REC_TASKS" ]; then
        record_write "$REC_RESETS_AT" "$REC_RESET_EPOCH" "$REC_DUE_EPOCH" "$REC_DUE_AT" "$merged" \
          || die "the resume plan could not be updated"
      fi
      footer_set "$REC_DUE_AT" || die "the scheduled-command footer could not be updated"
      check_armed || check_arm || die "the resume wake could not be armed"
      printf 'already-scheduled: due %s tasks=%s\n' "$REC_DUE_AT" "$(task_count "$merged")"
      return 0
    fi
  fi

  if [ "$QUOTA_RESET_EPOCH" -le "$now" ]; then
    # Current data shows no future session reset left to wait on.
    if [ "$had_record" -eq 1 ]; then
      # An existing plan for an older window is already due, so resume owns it
      # and any newly named task joins it instead of being dropped.
      merged=$(task_union "$REC_TASKS" "$tasks")
      if [ "$merged" != "$REC_TASKS" ]; then
        record_write "$REC_RESETS_AT" "$REC_RESET_EPOCH" "$REC_DUE_EPOCH" "$REC_DUE_AT" "$merged" \
          || die "the resume plan could not be updated"
      fi
      footer_set "$REC_DUE_AT" || die "the scheduled-command footer could not be updated"
      check_armed || check_arm || die "the resume wake could not be armed"
      printf 'already-reset: %s; the recorded plan is due now, run resume (tasks=%s)\n' \
        "$QUOTA_RESETS_AT" "$(task_count "$merged")"
      return 0
    fi
    # Nothing usable is recorded, so retire any unreadable leftovers and say
    # plainly that there is no wait to schedule.
    if [ -e "$RECORD" ] || [ -e "$CHECK" ]; then
      plan_retire || die "a stale resume plan could not be retired"
    fi
    printf 'already-reset: %s; nothing to wait for%s\n' \
      "$QUOTA_RESETS_AT" "${tasks:+ - resume now: $tasks}"
    return 0
  fi

  # A plan for an older window that was never resumed still names paused work, so
  # it is carried into the new wait rather than discarded with the old record.
  merged=$(task_union "$REC_TASKS" "$tasks")
  record_write "$QUOTA_RESETS_AT" "$QUOTA_RESET_EPOCH" "$QUOTA_DUE_EPOCH" "$QUOTA_DUE_AT" "$merged" \
    || die "the resume plan could not be recorded"
  footer_set "$QUOTA_DUE_AT" || die "the scheduled-command footer could not be updated"
  check_arm || die "the resume wake could not be armed"
  printf 'scheduled: due %s tasks=%s\n' "$QUOTA_DUE_AT" "$(task_count "$merged")"
}

cmd_status() {
  record_read || { printf 'idle\n'; return 0; }
  printf 'scheduled: due %s reset %s tasks=%s\n' \
    "$REC_DUE_AT" "$REC_RESETS_AT" "$(task_count "$REC_TASKS")"
  [ -z "$REC_TASKS" ] || printf 'tasks: %s\n' "$REC_TASKS"
}

cmd_due() {
  local now
  record_read || return 0
  now=$(now_epoch)
  [ "$now" -ge "$REC_DUE_EPOCH" ] || return 0
  printf '%s\n' "$DUE_LINE"
}

cmd_resume() {
  local quota_json='' now recheck id
  local remaining='' failed='' resumed=0 retired=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --quota-json)
        [ "$#" -ge 2 ] || die "--quota-json needs a path" 2
        quota_json=$2
        shift 2
        ;;
      *) die "unknown resume option: $1" 2 ;;
    esac
  done

  record_read || { printf 'idle\n'; return 0; }
  now=$(now_epoch)
  [ "$now" -ge "$REC_DUE_EPOCH" ] \
    || die "not due until $REC_DUE_AT; refusing to resume before the verified reset"

  # Confirm against fresh data that the recorded window really rolled: its
  # replacement resets later than the one that was waited on. Unreadable quota
  # data does not block a resume the recorded verified reset already earned, but
  # it is reported so the caller knows the re-check did not run.
  if quota_read "$quota_json"; then
    if [ "$QUOTA_RESETS_AT" = "$REC_RESETS_AT" ] || [ "$QUOTA_RESET_EPOCH" -le "$REC_RESET_EPOCH" ]; then
      die "the Claude session window has not reset yet (still $REC_RESETS_AT); refusing to resume"
    fi
    recheck=confirmed
  else
    recheck="unconfirmed-$QUOTA_ERROR"
  fi

  # shellcheck disable=SC2086 # tasks is a deliberate space-separated id list.
  for id in $REC_TASKS; do
    if [ ! -f "$STATE/$id.meta" ]; then
      # No longer recorded work: it was torn down while the window was waiting.
      retired=$((retired + 1))
      continue
    fi
    if FM_HOME="$FM_HOME" "$FM_ROOT/bin/fm-send.sh" "$id" "$RESUME_TEXT" >/dev/null 2>&1; then
      resumed=$((resumed + 1))
    else
      failed="${failed:+$failed }$id"
      remaining=$(task_union "$remaining" "$id")
    fi
  done

  if [ -n "$remaining" ]; then
    record_write "$REC_RESETS_AT" "$REC_RESET_EPOCH" "$REC_DUE_EPOCH" "$REC_DUE_AT" "$remaining" \
      || die "the remaining resume plan could not be recorded"
    printf 'resumed: %s task(s); reset %s; retired %s; not resumed: %s\n' \
      "$resumed" "$recheck" "$retired" "$failed"
    return 1
  fi

  plan_retire || die "the resume plan could not be retired"
  printf 'resumed: %s task(s); reset %s; retired %s; plan retired\n' \
    "$resumed" "$recheck" "$retired"
}

cmd_clear() {
  if [ ! -e "$RECORD" ] && [ ! -e "$CHECK" ]; then
    printf 'idle\n'
    return 0
  fi
  plan_retire || die "the resume plan could not be retired"
  printf 'cleared\n'
}

# --- entry ------------------------------------------------------------------

[ "$#" -ge 1 ] || { usage >&2; exit 2; }
COMMAND=$1
shift
umask 077
mkdir -p "$STATE" 2>/dev/null || true

case "$COMMAND" in
  schedule) cmd_schedule "$@" ;;
  status)   [ "$#" -eq 0 ] || die "status takes no arguments" 2; cmd_status ;;
  due)      [ "$#" -eq 0 ] || die "due takes no arguments" 2; cmd_due ;;
  resume)   cmd_resume "$@" ;;
  clear)    [ "$#" -eq 0 ] || die "clear takes no arguments" 2; cmd_clear ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
