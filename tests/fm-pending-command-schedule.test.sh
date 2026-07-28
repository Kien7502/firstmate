#!/usr/bin/env bash
# Focused parsing, next-item selection, and due/completed/idle checks for the pure
# schedule logic behind the Herdr pending-command footer. These tests exercise
# .pi/extensions/lib/fm-pending-command-schedule.ts directly - the module has no
# runtime dependency on the Pi extension host, so plain node (native TypeScript
# support) is enough; no pi-coding-agent install or version pin is required.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/.pi/extensions/lib/fm-pending-command-schedule.ts"

cleanup() {
  fm_test_cleanup
}
trap cleanup EXIT

test_static_contract() {
  local text
  assert_present "$LIB" "tracked pending-command schedule library is missing"
  text=$(cat "$LIB")
  assert_contains "$text" 'export function sanitizeLabel' "library does not export sanitizeLabel"
  assert_contains "$text" 'export function parseScheduleDocument' "library does not export parseScheduleDocument"
  assert_contains "$text" 'export function loadScheduleDocument' "library does not export loadScheduleDocument"
  assert_contains "$text" 'export function pickNextPendingItem' "library does not export pickNextPendingItem"
  assert_contains "$text" 'export function formatScheduledCommandsStatus' "library does not export formatScheduledCommandsStatus"
  assert_contains "$text" 'export const FOOTER_IDLE_TEXT' "library does not export the required explicit idle text"
  pass "pending-command schedule library exposes its documented parsing and formatting contract"
}

test_parsing_and_selection() {
  local out status
  if ! command -v node >/dev/null 2>&1; then
    echo "skip: node not found for pending-command schedule parsing test"
    return 0
  fi

  out=$(LIB="$LIB" node --input-type=module 2>&1 <<'JS'
const mod = await import(process.env.LIB);
const {
  sanitizeLabel,
  parseScheduleDocument,
  pickNextPendingItem,
  countPending,
  formatScheduledCommandsStatus,
  FOOTER_IDLE_TEXT,
} = mod;

function assertEqual(actual, expected, label) {
  if (actual !== expected) {
    throw new Error(label + ": expected " + JSON.stringify(expected) + ", got " + JSON.stringify(actual));
  }
}

// --- sanitizeLabel: the human-safe display label contract -------------------
assertEqual(sanitizeLabel("Resume Beepaws work"), "Resume Beepaws work", "plain label passes through");
assertEqual(sanitizeLabel("a\tb\nc  d"), "a b c d", "control characters and repeated whitespace collapse to single spaces");
assertEqual(sanitizeLabel("   "), undefined, "whitespace-only label is rejected");
assertEqual(sanitizeLabel(42), undefined, "non-string label is rejected");
assertEqual(sanitizeLabel(["rm", "-rf", "/"]), undefined, "non-string label (e.g. an array) is rejected, never coerced to shell-looking text");
const longLabel = sanitizeLabel("x".repeat(100));
assertEqual(longLabel.length, 60, "an overlong label is capped at 60 display characters");
assertEqual(longLabel.endsWith("…"), true, "a truncated label ends with an ellipsis marker");

// --- parseScheduleDocument: per-item graceful validation --------------------
const doc = JSON.stringify({
  version: 1,
  items: [
    { label: "Resume Beepaws work", due: "2026-07-28T16:10:00+07:00", state: "pending" },
    { label: "bad due", due: "not-a-date", state: "pending" },
    { label: "missing offset", due: "2026-07-28T16:10:00", state: "pending" },
    { label: 123, due: "2026-07-29T00:00:00Z", state: "pending" },
    { label: "done item", due: "2026-01-01T00:00:00Z", state: "completed" },
    { label: "bad state", due: "2026-01-01T00:00:00Z", state: "whatever" },
    "not-an-object",
  ],
});
const items = parseScheduleDocument(doc);
assertEqual(items.length, 2, "only the two well-formed entries survive parsing; malformed siblings are dropped individually");
assertEqual(items[0].label, "Resume Beepaws work", "the first surviving item keeps its label");
assertEqual(items[0].state, "pending", "the first surviving item keeps its pending state");
assertEqual(items[1].state, "completed", "a completed item survives parsing with its state intact");

// --- graceful missing/malformed document handling ---------------------------
assertEqual(JSON.stringify(parseScheduleDocument("{not json")), "[]", "malformed JSON yields an empty list, not a thrown error");
assertEqual(JSON.stringify(parseScheduleDocument(JSON.stringify({ items: "not-an-array" }))), "[]", "a wrong-shaped items field yields an empty list");
assertEqual(JSON.stringify(parseScheduleDocument(JSON.stringify({}))), "[]", "a document with no items field yields an empty list");
assertEqual(JSON.stringify(parseScheduleDocument("null")), "[]", "a top-level JSON null yields an empty list");
assertEqual(JSON.stringify(parseScheduleDocument("[]")), "[]", "a top-level JSON array (wrong shape) yields an empty list");

// --- next-item choice: earliest due among pending, ties keep file order -----
const tieBreak = parseScheduleDocument(JSON.stringify({
  items: [
    { label: "second in file, later due", due: "2026-07-29T00:00:00Z", state: "pending" },
    { label: "first in file, sooner due", due: "2026-07-28T00:00:00Z", state: "pending" },
  ],
}));
assertEqual(pickNextPendingItem(tieBreak).label, "first in file, sooner due", "next item is chosen by soonest due time, not file order");
assertEqual(pickNextPendingItem([]), undefined, "no pending items means no next item");
assertEqual(countPending(items), 1, "countPending counts only pending items, ignoring completed ones");

// --- due vs. completed vs. overdue footer text -------------------------------
assertEqual(formatScheduledCommandsStatus([], new Date("2026-07-28T00:00:00Z")), FOOTER_IDLE_TEXT, "the idle state is the explicit required text when nothing is pending");

const beforeDue = formatScheduledCommandsStatus(items, new Date("2026-07-28T00:00:00Z"));
if (!beforeDue.includes("1 scheduled") || !beforeDue.includes("Resume Beepaws work") || beforeDue.includes("overdue")) {
  throw new Error("footer text before the due time looked wrong: " + beforeDue);
}

const afterDue = formatScheduledCommandsStatus(items, new Date("2026-08-01T00:00:00Z"));
if (!afterDue.includes("(overdue)")) {
  throw new Error("footer text after the due time did not flag the item as overdue: " + afterDue);
}

const onlyCompleted = parseScheduleDocument(JSON.stringify({
  items: [{ label: "done", due: "2026-01-01T00:00:00Z", state: "completed" }],
}));
assertEqual(formatScheduledCommandsStatus(onlyCompleted, new Date()), FOOTER_IDLE_TEXT, "an all-completed schedule reports the idle state, not stale pending text");

console.log("PARSING_SELECTION_OK");
JS
)
  status=$?
  [ "$status" -eq 0 ] && [ "$out" = "PARSING_SELECTION_OK" ] \
    || fail "pending-command schedule parsing/selection contract failed: $out"
  pass "pending-command schedule library sanitizes labels, tolerates malformed entries, picks the soonest-due pending item, and flags overdue vs. idle correctly"
}

test_load_schedule_document_is_read_failure_safe() {
  local out status

  if ! command -v node >/dev/null 2>&1; then
    echo "skip: node not found for pending-command schedule read-failure test"
    return 0
  fi

  out=$(LIB="$LIB" node --input-type=module 2>&1 <<'JS'
const mod = await import(process.env.LIB);
const { loadScheduleDocument } = mod;

function throwingReadFileSync() {
  throw new Error("ENOENT: simulated missing file");
}

const missing = loadScheduleDocument("/nonexistent/scheduled-commands.json", throwingReadFileSync);
if (!Array.isArray(missing) || missing.length !== 0) {
  throw new Error("a read failure must yield an empty list, got " + JSON.stringify(missing));
}

const malformed = loadScheduleDocument("/whatever", () => "{ this is not valid json");
if (!Array.isArray(malformed) || malformed.length !== 0) {
  throw new Error("malformed file contents must yield an empty list, got " + JSON.stringify(malformed));
}

console.log("READ_FAILURE_SAFE_OK");
JS
)
  status=$?
  [ "$status" -eq 0 ] && [ "$out" = "READ_FAILURE_SAFE_OK" ] \
    || fail "loadScheduleDocument did not degrade harmlessly on a missing/malformed file: $out"
  pass "loadScheduleDocument treats a missing or malformed schedule file as harmless (empty list), never throwing"
}

test_static_contract
test_parsing_and_selection
test_load_schedule_document_is_read_failure_safe

echo "# fm-pending-command-schedule.test.sh: all assertions passed"
