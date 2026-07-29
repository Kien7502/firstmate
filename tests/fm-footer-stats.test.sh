#!/usr/bin/env bash
# Focused checks for the pure pwd/stats/extension-status line builders behind the
# pending-command footer's ctx.ui.setFooter() takeover.
# .pi/extensions/lib/fm-footer-stats.ts has no runtime dependency on the installed Pi
# package (only type-only imports, erased by Node's native TypeScript support), so
# these checks run directly against it with plain node - no version pin required.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/.pi/extensions/lib/fm-footer-stats.ts"

cleanup() {
  fm_test_cleanup
}
trap cleanup EXIT

test_static_contract() {
  local text
  assert_present "$LIB" "tracked footer-stats library is missing"
  text=$(cat "$LIB")
  assert_contains "$text" 'export function buildPwdLine' "library does not export buildPwdLine"
  assert_contains "$text" 'export function buildStatsLine' "library does not export buildStatsLine"
  assert_contains "$text" 'export function buildExtensionStatusLine' "library does not export buildExtensionStatusLine"
  assert_contains "$text" 'export function collectUsageTotals' "library does not export collectUsageTotals"
  assert_not_contains "$text" 'from "@earendil-works/pi-tui"' "library must not import runtime code from pi-tui; that would break the mock-testable design this extension relies on"
  assert_not_contains "$text" 'import { FooterComponent' "library must not reuse Pi's internal FooterComponent; it stays a hand-rolled, dependency-free reimplementation"
  pass "footer-stats library exposes its documented pure-formatting contract and stays free of runtime Pi dependencies"
}

test_pwd_and_stats_lines() {
  local out status
  if ! command -v node >/dev/null 2>&1; then
    echo "skip: node not found for footer-stats formatting test"
    return 0
  fi

  out=$(LIB="$LIB" node --input-type=module 2>&1 <<'JS'
const mod = await import(process.env.LIB);
const { buildPwdLine, buildStatsLine, buildExtensionStatusLine, collectUsageTotals, formatTokens, clampToWidth } = mod;

function assertEqual(actual, expected, label) {
  if (actual !== expected) {
    throw new Error(label + ": expected " + JSON.stringify(expected) + ", got " + JSON.stringify(actual));
  }
}

const theme = { fg: (_c, t) => t };

// --- pwd line: home abbreviation, branch, session name ----------------------
assertEqual(
  buildPwdLine({ cwd: "/home/kiene/project", home: "/home/kiene", gitBranch: "main", sessionName: undefined }, 80, theme),
  "~/project (main)",
  "pwd line abbreviates home and appends the git branch",
);
assertEqual(
  buildPwdLine({ cwd: "/elsewhere", home: "/home/kiene", gitBranch: null, sessionName: "my-session" }, 80, theme),
  "/elsewhere • my-session",
  "pwd line appends the session name and leaves an out-of-home cwd untouched",
);

// --- formatTokens: compact magnitude suffixes --------------------------------
assertEqual(formatTokens(999), "999", "sub-1000 token counts are shown verbatim");
assertEqual(formatTokens(1500), "1.5k", "thousands get a one-decimal k suffix");
assertEqual(formatTokens(15000), "15k", "ten-thousands round to a whole k suffix");
assertEqual(formatTokens(2_500_000), "2.5M", "millions get a one-decimal M suffix");

// --- stats line: tokens, cost, context percentage, model name ---------------
const statsInput = {
  usage: { input: 1000, output: 2000, cacheRead: 0, cacheWrite: 0, cost: 0.125, cacheHitRate: undefined },
  contextUsage: { contextWindow: 200000, percent: 12.3 },
  model: { id: "claude-sonnet-5", provider: "anthropic", contextWindow: 200000, reasoning: false },
  thinkingLevel: "off",
  usingSubscription: false,
  availableProviderCount: 1,
};
const statsLine = buildStatsLine(statsInput, 80, theme);
if (!statsLine.includes("↑1.0k") || !statsLine.includes("↓2.0k") || !statsLine.includes("$0.125") || !statsLine.includes("12.3%/200k") || !statsLine.includes("claude-sonnet-5")) {
  throw new Error("stats line missing expected tokens/cost/context/model content: " + statsLine);
}

// Unknown context usage falls back to the "?" display, not a thrown error or NaN.
const unknownContext = buildStatsLine({ ...statsInput, contextUsage: undefined, model: { id: "m", provider: "p", contextWindow: 0 } }, 80, theme);
if (!unknownContext.includes("?/0")) {
  throw new Error("unknown context usage should render as '?', got: " + unknownContext);
}

// --- extension-status line: unchanged "join every other extension's setStatus() text" behavior
const statuses = new Map([
  ["quota-limits", "[claude]  5h 80%"],
  ["some-other-extension", "extra"],
]);
const statusLine = buildExtensionStatusLine(statuses, 80);
assertEqual(statusLine, "[claude] 5h 80% extra", "extension statuses are sorted by key and joined on one line, exactly as Pi's built-in footer already does");
assertEqual(buildExtensionStatusLine(new Map(), 80), undefined, "no extension statuses means no status line at all, matching Pi's built-in footer's own conditional row");
assertEqual(buildExtensionStatusLine(new Map([["k", "line1\nline2\ttabbed"]]), 80), "line1 line2 tabbed", "control characters in a status text are sanitized to spaces before joining");

// --- collectUsageTotals: sums message/toolResult/branch_summary/compaction usage --
const usage = (n) => ({ input: n, output: n, cacheRead: 0, cacheWrite: 0, cost: { total: n / 100 } });
const entries = [
  { type: "message", message: { role: "assistant", usage: usage(10) } },
  { type: "message", message: { role: "toolResult", usage: usage(5) } },
  { type: "message", message: { role: "user" } },
  { type: "branch_summary", usage: usage(3) },
  { type: "compaction", usage: usage(2) },
];
const totals = collectUsageTotals(entries);
assertEqual(totals.input, 20, "collectUsageTotals sums input tokens across every usage-bearing entry type");
assertEqual(totals.cost, 0.2, "collectUsageTotals sums cost across every usage-bearing entry type");

// --- clampToWidth: truncation with ellipsis ----------------------------------
assertEqual(clampToWidth("short", 80), "short", "text within width is returned unchanged");
assertEqual(clampToWidth("0123456789", 5), "01...", "overlong text is truncated with a trailing ellipsis");

console.log("FOOTER_STATS_OK");
JS
)
  status=$?
  [ "$status" -eq 0 ] && [ "$out" = "FOOTER_STATS_OK" ] \
    || fail "footer-stats formatting contract failed: $out"
  pass "footer-stats library formats the pwd, stats, and extension-status lines correctly and sums usage across entry types"
}

test_static_contract
test_pwd_and_stats_lines

echo "# fm-footer-stats.test.sh: all assertions passed"
