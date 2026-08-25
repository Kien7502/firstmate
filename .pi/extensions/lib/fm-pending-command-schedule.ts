// Pure parsing/formatting logic for Firstmate's Pi footer indicator of queued and
// scheduled commands. This module never executes, reschedules, or dismisses anything -
// it only turns the private schedule file into a small human-safe display string.
// docs/configuration.md "Scheduled command footer" is the single owner of the file
// format contract; keep this module's parsing in sync with that document.
//
// The real wake mechanism that resumes queued captain work (the watcher, the wake
// queue, a future quota-reset scheduler, etc.) is authoritative and independent of this
// file. Nothing here is consulted to decide when work actually resumes.

export type ScheduledCommandState = "pending" | "completed";

/** One entry in the schedule file, already normalized by parseScheduleDocument. */
export interface ScheduledCommand {
  /** Human-safe display text. Never a shell command, secret, or arbitrary payload. */
  label: string;
  /** ISO-8601 due time, e.g. "2026-07-28T16:10:00+07:00". */
  due: string;
  state: ScheduledCommandState;
}

interface RawScheduledCommand {
  label?: unknown;
  due?: unknown;
  state?: unknown;
}

interface RawScheduleDocument {
  version?: unknown;
  items?: unknown;
}

const MAX_LABEL_LENGTH = 60;

// Requires an explicit "Z" or numeric offset so every due time is unambiguous - the
// source of truth for a home whose captain and operator may sit in different zones.
const ISO_8601_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:\d{2})$/;

/** True for ASCII control characters (C0 range and DEL) that must never reach the footer. */
function isControlCharCode(code: number): boolean {
  return code < 0x20 || code === 0x7f;
}

/**
 * Reduce arbitrary input to a single safe display line: drop control characters
 * (never let stray escape sequences or newlines reach the footer), collapse
 * whitespace, and cap length. Returns undefined for anything that is not a
 * non-empty string once cleaned, so a malformed or hostile label drops the entry
 * instead of reaching the terminal.
 */
export function sanitizeLabel(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;

  let cleaned = "";
  let pendingSpace = false;
  for (const char of value) {
    const code = char.codePointAt(0) ?? 0;
    const isSpaceLike = isControlCharCode(code) || char === " " || char === "\t" || char === "\n" || char === "\r";
    if (isSpaceLike) {
      if (cleaned.length > 0) pendingSpace = true;
      continue;
    }
    if (pendingSpace) {
      cleaned += " ";
      pendingSpace = false;
    }
    cleaned += char;
  }

  if (!cleaned) return undefined;
  return cleaned.length > MAX_LABEL_LENGTH
    ? `${cleaned.slice(0, MAX_LABEL_LENGTH - 1)}…`
    : cleaned;
}

function parseDue(value: unknown): string | undefined {
  if (typeof value !== "string" || !ISO_8601_RE.test(value)) return undefined;
  return Number.isFinite(Date.parse(value)) ? value : undefined;
}

function parseState(value: unknown): ScheduledCommandState | undefined {
  return value === "pending" || value === "completed" ? value : undefined;
}

/**
 * Parse the raw contents of the schedule file into a normalized item list.
 * Individual malformed entries are dropped rather than failing the whole document,
 * and a malformed, empty, or unexpected-shape document returns an empty list rather
 * than throwing - the footer must never crash the host session over bad local data.
 */
export function parseScheduleDocument(raw: string): ScheduledCommand[] {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return [];
  }
  if (!parsed || typeof parsed !== "object") return [];
  const items = (parsed as RawScheduleDocument).items;
  if (!Array.isArray(items)) return [];

  const result: ScheduledCommand[] = [];
  for (const entry of items) {
    if (!entry || typeof entry !== "object") continue;
    const rawEntry = entry as RawScheduledCommand;
    const label = sanitizeLabel(rawEntry.label);
    const due = parseDue(rawEntry.due);
    const state = parseState(rawEntry.state);
    if (!label || !due || !state) continue;
    result.push({ label, due, state });
  }
  return result;
}

/**
 * Read and parse the schedule file at `path` using the supplied `readFileSync`.
 * Any read failure - missing file, permission error, a directory instead of a file -
 * yields an empty list instead of throwing, so an absent or unreadable optional
 * schedule is harmless to the caller.
 */
export function loadScheduleDocument(
  path: string,
  readFileSync: (path: string) => string,
): ScheduledCommand[] {
  let raw: string;
  try {
    raw = readFileSync(path);
  } catch {
    return [];
  }
  return parseScheduleDocument(raw);
}

/** Count of items still awaiting resumption. */
export function countPending(items: readonly ScheduledCommand[]): number {
  return items.filter((item) => item.state === "pending").length;
}

/**
 * The pending item soonest due, regardless of whether that due time has already
 * passed - an overdue item is still the most relevant one to surface. Ties keep the
 * first matching item in file order. Returns undefined when nothing is pending.
 */
export function pickNextPendingItem(
  items: readonly ScheduledCommand[],
): ScheduledCommand | undefined {
  let next: { item: ScheduledCommand; at: number } | undefined;
  for (const item of items) {
    if (item.state !== "pending") continue;
    const at = Date.parse(item.due);
    if (!Number.isFinite(at)) continue;
    if (!next || at < next.at) next = { item, at };
  }
  return next?.item;
}

/** Format an ISO-8601 due time as a compact local wall-clock string for display. */
export function formatLocalDue(due: string, now: Date = new Date()): string {
  const date = new Date(due);
  const sameYear = date.getFullYear() === now.getFullYear();
  return new Intl.DateTimeFormat(undefined, {
    month: "short",
    day: "numeric",
    year: sameYear ? undefined : "numeric",
    hour: "numeric",
    minute: "2-digit",
  }).format(date);
}

/** Shown when no scheduled command is pending - the required explicit idle state. */
export const FOOTER_IDLE_TEXT = "No commands scheduled";

/**
 * Render the complete compact footer text: pending count, next command's label, and
 * its local due time, or the explicit idle text when nothing is pending. Pure and
 * deterministic given `items` and `now`, so it is the unit under test for every
 * display-format assertion; the extension only wires this to ctx.ui.setStatus().
 */
export function formatScheduledCommandsStatus(
  items: readonly ScheduledCommand[],
  now: Date = new Date(),
): string {
  const pending = countPending(items);
  if (pending === 0) return FOOTER_IDLE_TEXT;

  const next = pickNextPendingItem(items);
  if (!next) return FOOTER_IDLE_TEXT;

  const overdue = Date.parse(next.due) <= now.getTime();
  const when = formatLocalDue(next.due, now);
  return `${pending} scheduled · next: ${next.label} @ ${when}${overdue ? " (overdue)" : ""}`;
}
