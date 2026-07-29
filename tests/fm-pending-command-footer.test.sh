#!/usr/bin/env bash
# Extension-wiring checks for the Herdr/Pi pending-command footer: registration on
# ctx.ui.setFooter() (not ctx.ui.setStatus(), which Pi joins onto a single shared row
# with every other extension's own status - the captain wants scheduled-command status
# on its own distinct line beneath quota/usage rather than concatenated onto it), home
# resolution, periodic refresh as time/file state changes, the explicit idle state,
# graceful handling of a missing/malformed schedule file, and restoring the built-in
# footer on session shutdown. .pi/extensions/fm-pending-command-footer.ts and its
# ./lib/fm-footer-stats.ts helper have no runtime dependency on the installed
# pi-coding-agent package (only type-only imports, erased by Node's native TypeScript
# support), so these checks run against a small hand-built mock of the documented
# ExtensionAPI/ExtensionContext/FooterDataProvider shape rather than the real Pi
# runtime - no version pin required for this part.
#
# See test_real_pi_footer_smoke below for what is and is not covered against the real
# Pi binary, and why.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pending-command-footer)
EXT="$ROOT/.pi/extensions/fm-pending-command-footer.ts"
LIB="$ROOT/.pi/extensions/lib/fm-pending-command-schedule.ts"
STATS_LIB="$ROOT/.pi/extensions/lib/fm-footer-stats.ts"

cleanup() {
  if command -v tmux >/dev/null 2>&1; then
    tmux -L "fm-pending-footer-$$" kill-server 2>/dev/null || true
  fi
  fm_test_cleanup
}
trap cleanup EXIT

test_static_contract() {
  local text
  assert_present "$EXT" "tracked pending-command footer extension is missing"
  text=$(cat "$EXT")
  assert_contains "$text" 'ctx.ui.setFooter(' "extension does not use the supported ctx.ui.setFooter() footer hook"
  assert_not_contains "$text" 'ctx.ui.setStatus(STATUS_KEY' "extension must no longer set its own status via ctx.ui.setStatus() - Pi joins every setStatus() text onto one shared row, which is exactly the concatenation the captain asked to split apart"
  assert_contains "$text" 'pi.on("session_start"' "extension does not initialize the footer on session start"
  assert_contains "$text" 'pi.on("session_shutdown"' "extension does not restore the built-in footer on session shutdown"
  assert_contains "$text" 'setInterval' "extension does not refresh the footer as time elapses"
  assert_contains "$text" 'clearInterval' "extension does not clear its refresh timer, which would leak across session restarts"
  assert_contains "$text" 'ctx.ui.setFooter(undefined)' "extension does not restore Pi's built-in footer on shutdown"
  assert_contains "$text" 'loadScheduleDocument' "extension does not use the shared schedule-loading contract"
  assert_contains "$text" 'buildPwdLine' "extension does not reuse the shared pwd-line builder"
  assert_contains "$text" 'buildStatsLine' "extension does not reuse the shared stats-line builder"
  assert_contains "$text" 'buildExtensionStatusLine' "extension does not reuse the shared extension-status-line builder (this is where quota/usage keeps rendering)"
  assert_not_contains "$text" 'exec(' "footer extension must never execute a scheduled command; it is read-only display"
  assert_not_contains "$text" 'child_process' "footer extension must never shell out; it is read-only display"
  pass "pending-command footer extension is wired to the supported setFooter() hook, refreshes over time, and never executes anything"
}

test_state_path_contract() {
  local text
  text=$(cat "$EXT")
  assert_contains "$text" 'resolve(fmHome, "state")' "extension does not resolve its schedule file under the private state/ directory"
  assert_contains "$text" 'process.env.FM_STATE_OVERRIDE' "extension does not honor the FM_STATE_OVERRIDE test override used by the rest of the fleet's home-local state paths"
  assert_not_contains "$text" 'resolve(fmHome, "data")' "extension must not resolve its schedule file under the shared data/ directory"
  assert_not_contains "$text" 'FM_DATA_OVERRIDE' "extension must not read the FM_DATA_OVERRIDE test override; the schedule file is state, not data"
  pass "pending-command footer extension reads its schedule file from the authoritative private state/ directory, not data/"
}

# Builds the mock ExtensionAPI/ExtensionContext/FooterDataProvider harness shared by the
# node snippets below, then leaves the caller to drive session_start/agent_settled/
# session_shutdown and inspect the rendered footer lines.
mock_harness_prelude() {
  cat <<'JS'
const handlers = new Map();
const pi = { on(event, handler) { const l = handlers.get(event) ?? []; l.push(handler); handlers.set(event, l); } };

function makeCtx(mode) {
  let footerFactory;
  const theme = { fg: (_c, t) => t };
  const tui = { requestRender: () => {} };
  const footerData = {
    getGitBranch: () => "main",
    getAvailableProviderCount: () => 1,
    getExtensionStatuses: () => new Map([["quota-limits", "[claude] 5h 80%"]]),
    onBranchChange: () => () => {},
  };
  const ctx = {
    mode,
    ui: { setFooter: (factory) => { footerFactory = factory; }, setStatus: () => { throw new Error("must not call setStatus"); } },
    sessionManager: { getEntries: () => [], getCwd: () => "/home/kiene/project", getSessionName: () => undefined },
    getContextUsage: () => undefined,
    model: { id: "claude-sonnet-5", provider: "anthropic", contextWindow: 200000 },
    thinkingLevel: "off",
    modelRegistry: { isUsingOAuth: () => false },
  };
  return { ctx, theme, tui, footerData, getFactory: () => footerFactory };
}

function renderLines(harness) {
  const factory = harness.getFactory();
  if (!factory) throw new Error("session_start did not register a custom footer via ctx.ui.setFooter()");
  return factory(harness.tui, harness.theme, harness.footerData).render(80);
}
JS
}

test_mock_lifecycle() {
  local out status
  if ! command -v node >/dev/null 2>&1; then
    echo "skip: node not found for pending-command footer mock lifecycle test"
    return 0
  fi

  local fixture_home="$TMP_ROOT/home"
  mkdir -p "$fixture_home/state"
  cat > "$fixture_home/state/scheduled-commands.json" <<'DATA'
{
  "version": 1,
  "items": [
    { "label": "Resume Beepaws work", "due": "2026-07-28T16:10:00+07:00", "state": "pending" }
  ]
}
DATA

  out=$(EXT="$EXT" FM_HOME="$fixture_home" FM_PENDING_FOOTER_REFRESH_MS=40 \
    node --input-type=module 2>&1 <<JS
const path = await import("node:path");
const fs = await import("node:fs");
$(mock_harness_prelude)
const extension = await import(process.env.EXT);
extension.default(pi);

if (!handlers.has("session_start") || !handlers.has("session_shutdown") || !handlers.has("agent_settled")) {
  throw new Error("extension did not register session_start, agent_settled, and session_shutdown handlers");
}

const harness = makeCtx("tui");
await handlers.get("session_start")[0]({ reason: "startup" }, harness.ctx);
let lines = renderLines(harness);
const initial = lines[lines.length - 1];
if (!initial.includes("Resume Beepaws work") || !initial.includes("1 scheduled")) {
  throw new Error("initial footer's last line did not reflect the pending Beepaws item: " + initial);
}
const quotaLine = lines.find((l) => l.includes("[claude] 5h 80%"));
if (!quotaLine) throw new Error("quota/usage status did not render on its own footer line: " + JSON.stringify(lines));
if (quotaLine === initial) throw new Error("quota/usage and the scheduled-command text ended up concatenated on the same line");
if (lines.indexOf(quotaLine) >= lines.indexOf(initial)) {
  throw new Error("scheduled-command line must come after (beneath) the quota/usage line: " + JSON.stringify(lines));
}

// Mark the item completed and let the refresh timer pick it up without any explicit
// re-init - this is the "refreshes as time elapses" contract, not a one-shot read.
const stateFile = path.resolve(process.env.FM_HOME, "state", "scheduled-commands.json");
fs.writeFileSync(stateFile, JSON.stringify({
  version: 1,
  items: [{ label: "Resume Beepaws work", due: "2026-07-28T16:10:00+07:00", state: "completed" }],
}));
await new Promise((resolve) => setTimeout(resolve, 300));
lines = renderLines(harness);
if (lines[lines.length - 1] !== "No commands scheduled") {
  throw new Error("periodic refresh did not pick up the completed item and show the idle state: " + lines[lines.length - 1]);
}

// Missing file after having had data must degrade harmlessly to idle, not throw.
fs.rmSync(stateFile);
await new Promise((resolve) => setTimeout(resolve, 300));
lines = renderLines(harness);
if (lines[lines.length - 1] !== "No commands scheduled") {
  throw new Error("removing the schedule file did not degrade harmlessly to the idle state: " + lines[lines.length - 1]);
}

// Malformed file content must also degrade harmlessly rather than throwing/crashing.
fs.writeFileSync(stateFile, "{ not valid json");
await new Promise((resolve) => setTimeout(resolve, 300));
lines = renderLines(harness);
if (lines[lines.length - 1] !== "No commands scheduled") {
  throw new Error("malformed schedule file content did not degrade harmlessly: " + lines[lines.length - 1]);
}

let restoredFooter = "not-called";
harness.ctx.ui.setFooter = (factory) => { restoredFooter = factory; };
await handlers.get("session_shutdown")[0]({ reason: "quit" }, harness.ctx);
if (restoredFooter !== undefined) {
  throw new Error("session_shutdown did not restore Pi's built-in footer via ctx.ui.setFooter(undefined)");
}

// A non-tui mode (print/rpc) must never touch ctx.ui.setFooter() at all.
const printHarness = makeCtx("print");
await handlers.get("session_start")[0]({ reason: "startup" }, printHarness.ctx);
if (printHarness.getFactory() !== undefined) {
  throw new Error("non-tui mode must never call ctx.ui.setFooter()");
}

console.log("MOCK_LIFECYCLE_OK");
JS
)
  status=$?
  [ "$status" -eq 0 ] && [ "$out" = "MOCK_LIFECYCLE_OK" ] \
    || fail "pending-command footer mock lifecycle contract failed: $out"
  pass "pending-command footer renders on a distinct line beneath quota/usage, refreshes on a timer as items complete/disappear/malform, and restores the built-in footer on shutdown"
}

test_home_resolution() {
  local out status
  if ! command -v node >/dev/null 2>&1; then
    echo "skip: node not found for pending-command footer home-resolution test"
    return 0
  fi

  local override="$TMP_ROOT/override-home"
  mkdir -p "$override/state"
  cat > "$override/state/scheduled-commands.json" <<'DATA'
{ "version": 1, "items": [ { "label": "Override home item", "due": "2026-07-28T16:10:00+07:00", "state": "pending" } ] }
DATA

  out=$(EXT="$EXT" OVERRIDE_HOME="$override" node --input-type=module 2>&1 <<JS
$(mock_harness_prelude)
delete process.env.FM_HOME;
process.env.FM_ROOT_OVERRIDE = process.env.OVERRIDE_HOME;
const extension = await import(process.env.EXT);
extension.default(pi);

const harness = makeCtx("tui");
await handlers.get("session_start")[0]({ reason: "startup" }, harness.ctx);
const lines = renderLines(harness);
const text = lines[lines.length - 1];
if (!text || !text.includes("Override home item")) {
  throw new Error("footer did not resolve its home from FM_ROOT_OVERRIDE when FM_HOME was unset: " + text);
}
console.log("HOME_RESOLUTION_OK");
JS
)
  status=$?
  [ "$status" -eq 0 ] && [ "$out" = "HOME_RESOLUTION_OK" ] \
    || fail "pending-command footer home resolution failed: $out"
  pass "pending-command footer resolves its private schedule file from FM_HOME/FM_ROOT_OVERRIDE like the rest of the fleet's home-local extensions"
}

test_real_pi_footer_smoke() {
  local project pane version out
  if ! command -v pi >/dev/null 2>&1 || ! command -v tmux >/dev/null 2>&1; then
    echo "skip: pi or tmux not found for the real Pi footer smoke check"
    return 0
  fi

  # This extension has no dependency on pi-coding-agent internals (type-only imports,
  # erased at runtime), so unlike fm-calm-pi-extension.test.sh this smoke check is not
  # version-pinned: it only asserts the documented, stable ctx.ui.setFooter() footer
  # contract. If a future Pi drops or renames setFooter()/the footer row entirely, this
  # check fails loudly rather than silently passing.
  version=$(pi --version 2>/dev/null || true)
  if [ -z "$version" ]; then
    echo "skip: could not determine installed pi version for the real Pi footer smoke check"
    return 0
  fi

  project="$TMP_ROOT/real-pi-project"
  mkdir -p "$project/.pi/extensions/lib" "$project/state"
  fm_git_init_commit "$project"
  cp "$EXT" "$project/.pi/extensions/fm-pending-command-footer.ts"
  cp "$LIB" "$project/.pi/extensions/lib/fm-pending-command-schedule.ts"
  cp "$STATS_LIB" "$project/.pi/extensions/lib/fm-footer-stats.ts"
  cat > "$project/state/scheduled-commands.json" <<'DATA'
{
  "version": 1,
  "items": [
    { "label": "Resume Beepaws work", "due": "2026-07-28T16:10:00+07:00", "state": "pending" }
  ]
}
DATA

  pane="fm-pending-footer-smoke"
  if ! FM_HOME="$project" tmux -L "fm-pending-footer-$$" new-session -d -s "$pane" -x 220 -y 50 \
    "cd '$project' && FM_HOME='$project' pi 2>&1; sleep 2"; then
    echo "skip: could not start a real Pi session in tmux for the footer smoke check"
    return 0
  fi

  local i=0 found=0 trusted=0
  while [ "$i" -lt 100 ]; do
    out=$(tmux -L "fm-pending-footer-$$" capture-pane -p -t "$pane" -S - 2>/dev/null || true)
    if [ "$trusted" -eq 0 ] && printf '%s' "$out" | grep -Fq "Trust project folder?"; then
      tmux -L "fm-pending-footer-$$" send-keys -t "$pane" Enter 2>/dev/null || true
      trusted=1
    fi
    if printf '%s' "$out" | grep -Fq "Resume Beepaws work"; then
      found=1
      break
    fi
    sleep 0.1
    i=$((i + 1))
  done

  if [ "$found" -ne 1 ]; then
    tmux -L "fm-pending-footer-$$" kill-server 2>/dev/null || true
    fail "real Pi ($version) footer never showed the scheduled item's label; last captured pane:"$'\n'"$out"
  fi

  # The scheduled-command text and the pwd/stats line above it must land on distinct
  # rows, not be concatenated onto the same row - capture the pane once more and check
  # the scheduled line does not share a row with the pwd (~) line.
  local pwd_row schedule_row
  pwd_row=$(printf '%s\n' "$out" | grep -n '~' | tail -1 | cut -d: -f1 || true)
  schedule_row=$(printf '%s\n' "$out" | grep -n "Resume Beepaws work" | tail -1 | cut -d: -f1 || true)
  tmux -L "fm-pending-footer-$$" kill-server 2>/dev/null || true
  if [ -n "$pwd_row" ] && [ -n "$schedule_row" ] && [ "$pwd_row" = "$schedule_row" ]; then
    fail "real Pi ($version) rendered the scheduled-command text on the same row as the pwd/stats line instead of a distinct line beneath it"
  fi

  pass "real Pi ($version) renders the pending-command footer text on its own distinct footer line"
}

test_static_contract
test_state_path_contract
test_mock_lifecycle
test_home_resolution
test_real_pi_footer_smoke

echo "# fm-pending-command-footer.test.sh: all assertions passed"
