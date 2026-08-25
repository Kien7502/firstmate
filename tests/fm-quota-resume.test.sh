#!/usr/bin/env bash
# Behavior tests for bin/fm-quota-resume.sh - the deterministic, idempotent plan
# that parks paused work on a Claude five-hour (session) usage limit and resumes
# it once that window has verifiably reset.
#
# Every case runs against captured quota-axi documents (--quota-json) and a fixed
# clock (FM_QUOTA_RESUME_NOW), so nothing here touches the network, the real
# quota tool, or a live crewmate endpoint. Steering is observed through a stub
# fm-send.sh reached via FM_ROOT_OVERRIDE.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$ROOT/bin/fm-quota-resume.sh"

cleanup() {
  fm_test_cleanup
}
trap cleanup EXIT

# Fixed points on the clock used by every case.
RESET_ISO='2026-07-31T04:49:59.084541+00:00'   # the session window under test
ROLLED_ISO='2026-07-31T09:49:59.084541+00:00'  # its replacement after the reset
WEEKLY_ISO='2026-08-06T17:59:59.084570+00:00'  # never a substitute for the above
BEFORE=1785470400   # 2026-07-31T04:00:00Z, before the reset
AFTER=1785474960    # 2026-07-31T04:56:00Z, past reset + five minutes
WAY_AFTER=1785481200  # 2026-07-31T06:20:00Z

# The contract the script hard-codes: reset rounded up to the second, plus five
# minutes. Recomputed here rather than copied so the test proves the arithmetic.
EXPECTED_DUE_EPOCH=1785473700   # ceil(2026-07-31T04:49:59.084541Z) + 300

require_node() {
  command -v node >/dev/null 2>&1
}

# --- fixture home -----------------------------------------------------------

# fm_qr_home: create an isolated firstmate home plus a fake code root whose
# fm-send.sh records every steer. Echoes the temp root; the caller exports the
# environment with fm_qr_env.
fm_qr_home() {
  local tmp
  tmp=$(fm_test_tmproot fm-quota-resume)
  mkdir -p "$tmp/home/state" "$tmp/fakeroot/bin"
  cat > "$tmp/fakeroot/bin/fm-send.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_SEND_LOG"
# FM_SEND_FAIL names one task id whose steer must fail, standing in for a pane
# that no longer accepts input.
[ "${FM_SEND_FAIL:-}" != "$1" ] || exit 1
exit 0
SH
  chmod +x "$tmp/fakeroot/bin/fm-send.sh"
  : > "$tmp/send.log"
  printf '%s\n' "$tmp"
}

fm_qr_env() {  # <tmp>
  export FM_HOME="$1/home"
  export FM_STATE_OVERRIDE="$1/home/state"
  export FM_ROOT_OVERRIDE="$1/fakeroot"
  export FM_SEND_LOG="$1/send.log"
}

# fm_qr_quota <path> <session-resets-at> [<extra-window-json>]: write a quota-axi
# shaped document carrying a Claude session window, its weekly sibling, and
# account detail that must never leak into any artifact.
fm_qr_quota() {  # <path> <session-resets-at>
  cat > "$1" <<JSON
{
  "schemaVersion": 3,
  "generatedAt": "2026-07-31T00:00:00.000Z",
  "providers": [
    {
      "provider": "codex",
      "windows": [
        { "id": "weekly", "kind": "weekly", "resetsAt": "$WEEKLY_ISO" }
      ]
    },
    {
      "provider": "claude",
      "plan": "some-plan-name",
      "oauthToken": "sk-secret-value",
      "windows": [
        {
          "id": "five_hour",
          "label": "session",
          "kind": "session",
          "percentUsed": 100,
          "resetsAt": "$2"
        },
        {
          "id": "seven_day",
          "label": "week",
          "kind": "weekly",
          "percentUsed": 11,
          "resetsAt": "$WEEKLY_ISO"
        }
      ]
    }
  ]
}
JSON
}

# fm_qr_task <state> <id>: give a recorded task the metadata resume looks for
# before it steers anything.
fm_qr_task() {
  fm_write_meta "$1/$2.meta" "window=fm:$2" "harness=claude" "kind=ship"
}

qr() {  # <args...>: run the script, capturing stdout+stderr, never aborting
  "$SCRIPT" "$@" 2>&1
}

footer_item_count() {  # <schedule-file>
  node -e '
    const fs = require("fs");
    let items = [];
    try { items = JSON.parse(fs.readFileSync(process.argv[1], "utf8")).items || []; } catch {}
    process.stdout.write(String(items.length));
  ' "$1"
}

# --- cases ------------------------------------------------------------------

test_usage_is_self_describing() {
  local out code
  out=$("$SCRIPT" --help 2>&1) || fail "--help must exit 0"
  assert_contains "$out" 'fm-quota-resume.sh schedule' "--help does not print the usage block"
  assert_contains "$out" 'seven-day / weekly window is never substituted' \
    "--help does not state the never-substitute-the-weekly-window contract"

  out=$("$SCRIPT" 2>&1) && code=0 || code=$?
  expect_code 2 "$code" "a bare invocation must be an invalid request"
  out=$("$SCRIPT" wat 2>&1) && code=0 || code=$?
  expect_code 2 "$code" "an unknown subcommand must be an invalid request"
  pass "fm-quota-resume documents itself and refuses invalid requests"
}

test_schedule_uses_the_session_window_never_the_weekly_one() {
  local tmp state out
  require_node || { echo "skip: node not found for quota-resume scheduling test"; return 0; }
  tmp=$(fm_qr_home)
  fm_qr_env "$tmp"
  state="$tmp/home/state"
  fm_qr_quota "$tmp/quota.json" "$RESET_ISO"

  out=$(FM_QUOTA_RESUME_NOW=$BEFORE qr schedule --task alpha --quota-json "$tmp/quota.json") \
    || fail "scheduling against a live session window must succeed: $out"
  assert_contains "$out" 'scheduled: due' "schedule did not report the plan"

  assert_grep "resets_at=$RESET_ISO" "$state/quota-resume.record" \
    "the plan did not record the session window's own reset"
  assert_no_grep "$WEEKLY_ISO" "$state/quota-resume.record" \
    "the plan recorded the seven-day reset instead of the five-hour one"
  assert_grep "due_epoch=$EXPECTED_DUE_EPOCH" "$state/quota-resume.record" \
    "the resume time is not the verified session reset plus exactly five minutes"

  # A Claude provider with only a weekly window has no session reset to wait on,
  # and the weekly one must never stand in for it.
  cat > "$tmp/weekly-only.json" <<JSON
{"providers":[{"provider":"claude","windows":[
  {"id":"seven_day","kind":"weekly","resetsAt":"$WEEKLY_ISO"}]}]}
JSON
  rm -f "$state/quota-resume.record"
  out=$(FM_QUOTA_RESUME_NOW=$BEFORE qr schedule --task alpha --quota-json "$tmp/weekly-only.json") \
    && fail "a weekly-only provider must not schedule anything: $out"
  assert_contains "$out" 'no-session-window' "the weekly-only refusal did not name the missing session window"
  assert_absent "$state/quota-resume.record" "a weekly-only provider still wrote a resume plan"
  pass "schedule waits on the Claude session reset plus five minutes and never on the seven-day window"
}

test_missing_or_malformed_quota_data_schedules_nothing() {
  local tmp state out code fixture
  require_node || { echo "skip: node not found for quota-resume malformed-data test"; return 0; }
  tmp=$(fm_qr_home)
  fm_qr_env "$tmp"
  state="$tmp/home/state"

  printf '{not json\n' > "$tmp/malformed.json"
  printf '{"providers":[{"provider":"codex","windows":[]}]}\n' > "$tmp/no-claude.json"
  printf '{"providers":"nope"}\n' > "$tmp/wrong-shape.json"
  # A reset stamp with no Z and no offset is ambiguous: read in the local zone it
  # could place the resume hours early, so it must be refused outright.
  printf '{"providers":[{"provider":"claude","windows":[{"id":"five_hour","kind":"session","resetsAt":"2026-07-31T04:49:59"}]}]}\n' \
    > "$tmp/ambiguous.json"

  for fixture in absent malformed no-claude wrong-shape ambiguous; do
    out=$(FM_QUOTA_RESUME_NOW=$BEFORE qr schedule --task alpha --quota-json "$tmp/$fixture.json") \
      && code=0 || code=$?
    expect_code 1 "$code" "quota fixture '$fixture' must refuse to schedule"
    assert_contains "$out" 'nothing scheduled' "quota fixture '$fixture' did not report that nothing was scheduled"
    assert_absent "$state/quota-resume.record" "quota fixture '$fixture' still wrote a resume plan"
    assert_absent "$state/quota-resume.check.sh" "quota fixture '$fixture' still armed a resume wake"
    assert_absent "$state/scheduled-commands.json" "quota fixture '$fixture' still wrote a footer item"
  done

  # A record whose fields cannot be trusted is treated as absent rather than
  # acted on: due stays silent and resume refuses to steer from it.
  printf 'version=1\nresets_at=\ndue_epoch=not-a-number\n' > "$state/quota-resume.record"
  out=$(FM_QUOTA_RESUME_NOW=$WAY_AFTER qr due)
  [ -z "$out" ] || fail "a corrupt plan must never announce a resume: $out"
  out=$(FM_QUOTA_RESUME_NOW=$WAY_AFTER qr resume --quota-json "$tmp/no-claude.json")
  assert_contains "$out" 'idle' "a corrupt plan must read as idle, not as work to resume"
  pass "missing, malformed, ambiguous, and corrupt data schedule and resume nothing"
}

test_duplicate_scheduling_is_idempotent() {
  local tmp state out first second
  require_node || { echo "skip: node not found for quota-resume idempotence test"; return 0; }
  tmp=$(fm_qr_home)
  fm_qr_env "$tmp"
  state="$tmp/home/state"
  fm_qr_quota "$tmp/quota.json" "$RESET_ISO"

  FM_QUOTA_RESUME_NOW=$BEFORE qr schedule --task alpha --task beta --quota-json "$tmp/quota.json" >/dev/null \
    || fail "the first schedule failed"
  first=$(cat "$state/quota-resume.record" "$state/scheduled-commands.json")

  out=$(FM_QUOTA_RESUME_NOW=$BEFORE qr schedule --task alpha --task beta --quota-json "$tmp/quota.json") \
    || fail "re-scheduling the same window must succeed: $out"
  assert_contains "$out" 'already-scheduled: due' "a repeat schedule did not report the existing plan"
  second=$(cat "$state/quota-resume.record" "$state/scheduled-commands.json")
  [ "$first" = "$second" ] || fail "re-scheduling the same window changed the plan or the footer"
  [ "$(footer_item_count "$state/scheduled-commands.json")" = 1 ] \
    || fail "re-scheduling duplicated the footer item"

  # Repeating with the same ids in a different order must still be a no-op.
  FM_QUOTA_RESUME_NOW=$BEFORE qr schedule --task beta --task alpha --quota-json "$tmp/quota.json" >/dev/null \
    || fail "re-scheduling with reordered ids failed"
  [ "$(cat "$state/quota-resume.record" "$state/scheduled-commands.json")" = "$first" ] \
    || fail "re-scheduling with reordered ids rewrote the plan"

  # A second worker hitting the same limit joins the existing plan.
  out=$(FM_QUOTA_RESUME_NOW=$BEFORE qr schedule --task gamma --quota-json "$tmp/quota.json") \
    || fail "adding a task to the existing plan failed: $out"
  assert_contains "$out" 'tasks=3' "the added task was not folded into the existing plan"
  assert_grep 'tasks=alpha beta gamma' "$state/quota-resume.record" "the task union lost or reordered ids"
  assert_grep "due_epoch=$EXPECTED_DUE_EPOCH" "$state/quota-resume.record" \
    "adding a task moved the resume time"
  [ "$(footer_item_count "$state/scheduled-commands.json")" = 1 ] \
    || fail "adding a task duplicated the footer item"
  pass "scheduling twice keeps one plan, one footer item, and one wake while unioning tasks"
}

test_already_reset_quota_arms_no_wake() {
  local tmp state out
  require_node || { echo "skip: node not found for quota-resume already-reset test"; return 0; }
  tmp=$(fm_qr_home)
  fm_qr_env "$tmp"
  state="$tmp/home/state"
  fm_qr_quota "$tmp/quota.json" "$RESET_ISO"

  out=$(FM_QUOTA_RESUME_NOW=$WAY_AFTER qr schedule --task alpha --quota-json "$tmp/quota.json") \
    || fail "an already-reset window must not be an error: $out"
  assert_contains "$out" "already-reset: $RESET_ISO" "an already-reset window was not reported as such"
  assert_contains "$out" 'resume now: alpha' "an already-reset window did not name the work to resume now"
  assert_absent "$state/quota-resume.record" "an already-reset window still wrote a resume plan"
  assert_absent "$state/quota-resume.check.sh" "an already-reset window still armed a resume wake"

  # An unreadable leftover is retired: it can never announce or resume anything.
  printf 'version=1\ndue_epoch=not-a-number\n' > "$state/quota-resume.record"
  out=$(FM_QUOTA_RESUME_NOW=$WAY_AFTER qr schedule --quota-json "$tmp/quota.json") \
    || fail "retiring an unreadable leftover must not be an error: $out"
  assert_absent "$state/quota-resume.record" "an unreadable leftover survived an already-reset schedule"

  # A real plan for an older window that was never resumed still names paused
  # work, so an already-reset schedule keeps it and folds the new task in rather
  # than dropping work on the floor.
  FM_QUOTA_RESUME_NOW=$BEFORE qr schedule --task alpha --quota-json "$tmp/quota.json" >/dev/null \
    || fail "seeding a plan for the pending window failed"
  assert_present "$state/quota-resume.check.sh" "the seeded plan armed no wake"
  fm_qr_quota "$tmp/stale.json" '2026-07-31T03:00:00.000000+00:00'
  out=$(FM_QUOTA_RESUME_NOW=$WAY_AFTER qr schedule --task delta --quota-json "$tmp/stale.json") \
    || fail "an already-reset schedule over an existing plan must not be an error: $out"
  assert_contains "$out" 'the recorded plan is due now, run resume' \
    "the existing plan was not reported as due now"
  assert_grep 'tasks=alpha delta' "$state/quota-resume.record" \
    "an already-reset schedule dropped or failed to fold in recorded paused work"
  assert_present "$state/quota-resume.check.sh" "an already-reset schedule disarmed a plan that is due now"
  pass "quota that has already reset arms no wake, names the work to resume, and never drops a pending plan"
}

test_replacing_a_plan_carries_unresumed_work_forward() {
  local tmp state out
  require_node || { echo "skip: node not found for quota-resume carry-forward test"; return 0; }
  tmp=$(fm_qr_home)
  fm_qr_env "$tmp"
  state="$tmp/home/state"
  fm_qr_quota "$tmp/quota.json" "$RESET_ISO"
  fm_qr_quota "$tmp/rolled.json" "$ROLLED_ISO"

  FM_QUOTA_RESUME_NOW=$BEFORE qr schedule --task alpha --quota-json "$tmp/quota.json" >/dev/null \
    || fail "seeding the first plan failed"
  # The first window rolled without the plan ever being resumed, and a second
  # limit lands in the new window.
  out=$(FM_QUOTA_RESUME_NOW=$AFTER qr schedule --task beta --quota-json "$tmp/rolled.json") \
    || fail "scheduling against the replacement window failed: $out"
  assert_contains "$out" 'scheduled: due' "the replacement window did not produce a new plan"
  assert_grep "resets_at=$ROLLED_ISO" "$state/quota-resume.record" \
    "the new plan did not wait on the replacement window"
  assert_grep 'tasks=alpha beta' "$state/quota-resume.record" \
    "replacing the plan discarded paused work that was never resumed"
  pass "replacing a plan carries never-resumed paused work into the new wait"
}

test_the_armed_wake_is_silent_until_due() {
  local tmp state out
  require_node || { echo "skip: node not found for quota-resume wake test"; return 0; }
  tmp=$(fm_qr_home)
  fm_qr_env "$tmp"
  state="$tmp/home/state"
  fm_qr_quota "$tmp/quota.json" "$RESET_ISO"
  FM_QUOTA_RESUME_NOW=$BEFORE qr schedule --task alpha --quota-json "$tmp/quota.json" >/dev/null \
    || fail "scheduling failed"

  # The watcher only runs a check whose current bytes are bound to its trust
  # record; an unbound check is refused without execution.
  bash -c '
    . "$1/bin/fm-pr-lib.sh"
    . "$1/bin/fm-check-lib.sh"
    fm_custom_check_registered "$2" quota-resume
  ' fm-quota-resume-trust "$ROOT" "$state" \
    || fail "the armed wake is not bound to its trust record and the watcher would refuse it"
  [ "$(stat -c %a "$state/quota-resume.check.sh" 2>/dev/null || stat -f %Lp "$state/quota-resume.check.sh")" = 700 ] \
    || fail "the armed wake is not a private 0700 file"

  out=$(FM_QUOTA_RESUME_NOW=$BEFORE bash "$state/quota-resume.check.sh")
  [ -z "$out" ] || fail "the wake spoke before the resume was due: $out"
  out=$(FM_QUOTA_RESUME_NOW=$((EXPECTED_DUE_EPOCH - 1)) bash "$state/quota-resume.check.sh")
  [ -z "$out" ] || fail "the wake spoke one second before the resume was due: $out"

  out=$(FM_QUOTA_RESUME_NOW=$EXPECTED_DUE_EPOCH bash "$state/quota-resume.check.sh")
  assert_contains "$out" 'quota-resume due' "the wake stayed silent at the due time"
  [ "$(printf '%s' "$out" | wc -l)" -eq 0 ] || fail "the wake printed more than one line: $out"
  pass "the armed wake is bound, private, silent before the due time, and speaks once at it"
}

test_resume_refuses_before_the_verified_reset() {
  local tmp state out code
  require_node || { echo "skip: node not found for quota-resume refusal test"; return 0; }
  tmp=$(fm_qr_home)
  fm_qr_env "$tmp"
  state="$tmp/home/state"
  fm_qr_quota "$tmp/quota.json" "$RESET_ISO"
  fm_qr_task "$state" alpha
  FM_QUOTA_RESUME_NOW=$BEFORE qr schedule --task alpha --quota-json "$tmp/quota.json" >/dev/null \
    || fail "scheduling failed"

  out=$(FM_QUOTA_RESUME_NOW=$((EXPECTED_DUE_EPOCH - 1)) qr resume --quota-json "$tmp/quota.json") \
    && code=0 || code=$?
  expect_code 1 "$code" "resuming one second early must be refused"
  assert_contains "$out" 'not due until' "the early refusal did not name the due time"
  [ ! -s "$FM_SEND_LOG" ] || fail "an early resume steered a task anyway: $(cat "$FM_SEND_LOG")"

  # Past the due time, but current data still reports the very window that was
  # waited on: the reset has not actually happened, so nothing is steered.
  out=$(FM_QUOTA_RESUME_NOW=$AFTER qr resume --quota-json "$tmp/quota.json") && code=0 || code=$?
  expect_code 1 "$code" "a window that has not rolled must refuse to resume"
  assert_contains "$out" 'has not reset yet' "the not-yet-reset refusal did not say so"
  [ ! -s "$FM_SEND_LOG" ] || fail "an unreset window steered a task anyway: $(cat "$FM_SEND_LOG")"
  assert_present "$state/quota-resume.record" "a refused resume discarded the plan"
  assert_present "$state/quota-resume.check.sh" "a refused resume disarmed the wake"
  pass "resume refuses before the due time and before the session window has actually rolled"
}

test_resume_steers_only_recorded_work_then_cleans_up() {
  local tmp state out sends
  require_node || { echo "skip: node not found for quota-resume cleanup test"; return 0; }
  tmp=$(fm_qr_home)
  fm_qr_env "$tmp"
  state="$tmp/home/state"
  fm_qr_quota "$tmp/quota.json" "$RESET_ISO"
  fm_qr_quota "$tmp/rolled.json" "$ROLLED_ISO"
  fm_qr_task "$state" alpha
  fm_qr_task "$state" beta
  # Recorded but torn down while the window was waiting, plus a live task that
  # was never part of the plan: neither may be steered.
  fm_qr_task "$state" bystander
  cat > "$state/scheduled-commands.json" <<'JSON'
{"version":1,"items":[{"label":"Some other queued thing","due":"2026-09-01T00:00:00Z","state":"pending"}]}
JSON

  FM_QUOTA_RESUME_NOW=$BEFORE qr schedule --task alpha --task beta --task gone --quota-json "$tmp/quota.json" >/dev/null \
    || fail "scheduling failed"
  [ "$(footer_item_count "$state/scheduled-commands.json")" = 2 ] \
    || fail "scheduling did not preserve the unrelated footer item"

  out=$(FM_QUOTA_RESUME_NOW=$AFTER qr resume --quota-json "$tmp/rolled.json") \
    || fail "resuming after a verified reset failed: $out"
  assert_contains "$out" 'resumed: 2 task(s)' "resume did not report the two steered tasks"
  assert_contains "$out" 'retired 1' "resume did not account for the torn-down task"
  assert_contains "$out" 'plan retired' "resume did not report the cleanup"

  sends=$(cat "$FM_SEND_LOG")
  assert_contains "$sends" 'alpha Claude session quota has reset' "alpha was not resumed"
  assert_contains "$sends" 'beta Claude session quota has reset' "beta was not resumed"
  assert_not_contains "$sends" 'bystander' "resume steered a task the plan never recorded"
  assert_not_contains "$sends" 'gone ' "resume steered a task whose work no longer exists"

  assert_absent "$state/quota-resume.record" "the plan survived a successful resume"
  assert_absent "$state/quota-resume.check.sh" "the wake survived a successful resume"
  assert_absent "$state/quota-resume.check-trust" "the wake binding survived a successful resume"
  [ "$(footer_item_count "$state/scheduled-commands.json")" = 1 ] \
    || fail "cleanup did not retire exactly its own footer item"
  assert_grep 'Some other queued thing' "$state/scheduled-commands.json" \
    "cleanup discarded an unrelated footer item"

  out=$(FM_QUOTA_RESUME_NOW=$AFTER qr resume --quota-json "$tmp/rolled.json") \
    || fail "resuming a retired plan must not be an error: $out"
  assert_contains "$out" 'idle' "a retired plan did not read as idle"
  out=$(FM_QUOTA_RESUME_NOW=$AFTER qr clear)
  assert_contains "$out" 'idle' "clearing a retired plan did not read as idle"
  pass "resume steers only the recorded paused work, then retires the plan, wake, and its own footer item"
}

test_partial_resume_keeps_only_the_remainder() {
  local tmp state out code
  require_node || { echo "skip: node not found for quota-resume partial-failure test"; return 0; }
  tmp=$(fm_qr_home)
  fm_qr_env "$tmp"
  state="$tmp/home/state"
  fm_qr_quota "$tmp/quota.json" "$RESET_ISO"
  fm_qr_quota "$tmp/rolled.json" "$ROLLED_ISO"
  fm_qr_task "$state" alpha
  fm_qr_task "$state" beta
  FM_QUOTA_RESUME_NOW=$BEFORE qr schedule --task alpha --task beta --quota-json "$tmp/quota.json" >/dev/null \
    || fail "scheduling failed"

  out=$(FM_SEND_FAIL=beta FM_QUOTA_RESUME_NOW=$AFTER qr resume --quota-json "$tmp/rolled.json") \
    && code=0 || code=$?
  expect_code 1 "$code" "a partly failed resume must report failure"
  assert_contains "$out" 'not resumed: beta' "the unsteered task was not named"
  assert_grep 'tasks=beta' "$state/quota-resume.record" "the plan did not narrow to the remaining task"
  assert_present "$state/quota-resume.check.sh" "a partly failed resume disarmed the wake"

  : > "$FM_SEND_LOG"
  out=$(FM_QUOTA_RESUME_NOW=$AFTER qr resume --quota-json "$tmp/rolled.json") \
    || fail "retrying the remainder failed: $out"
  assert_contains "$out" 'plan retired' "the retry did not clean up"
  assert_not_contains "$(cat "$FM_SEND_LOG")" 'alpha' "the retry steered an already-resumed task again"
  assert_grep 'beta Claude session quota has reset' "$FM_SEND_LOG" "the retry did not steer the remainder"
  pass "a partly failed resume keeps only the unsteered work and the retry finishes it"
}

test_no_account_detail_reaches_the_recorded_plan() {
  local tmp state artifacts
  require_node || { echo "skip: node not found for quota-resume privacy test"; return 0; }
  tmp=$(fm_qr_home)
  fm_qr_env "$tmp"
  state="$tmp/home/state"
  fm_qr_quota "$tmp/quota.json" "$RESET_ISO"
  FM_QUOTA_RESUME_NOW=$BEFORE qr schedule --task alpha --quota-json "$tmp/quota.json" >/dev/null \
    || fail "scheduling failed"

  artifacts=$(cat "$state/quota-resume.record" "$state/scheduled-commands.json" "$state/quota-resume.check.sh")
  assert_not_contains "$artifacts" 'sk-secret-value' "a credential from the quota document reached a durable artifact"
  assert_not_contains "$artifacts" 'oauthToken' "a credential field from the quota document reached a durable artifact"
  assert_not_contains "$artifacts" 'some-plan-name' "the account plan reached a durable artifact"
  assert_not_contains "$artifacts" 'percentUsed' "a live account balance reached a durable artifact"

  # The wake line the watcher turns into a supervisor notification is likewise
  # free of account detail.
  assert_not_contains "$(FM_QUOTA_RESUME_NOW=$WAY_AFTER bash "$state/quota-resume.check.sh")" 'some-plan-name' \
    "the wake line carried account detail"
  pass "the plan, footer item, wake, and wake line carry no credentials, plan name, or balances"
}

test_usage_is_self_describing
test_schedule_uses_the_session_window_never_the_weekly_one
test_missing_or_malformed_quota_data_schedules_nothing
test_duplicate_scheduling_is_idempotent
test_already_reset_quota_arms_no_wake
test_replacing_a_plan_carries_unresumed_work_forward
test_the_armed_wake_is_silent_until_due
test_resume_refuses_before_the_verified_reset
test_resume_steers_only_recorded_work_then_cleans_up
test_partial_resume_keeps_only_the_remainder
test_no_account_detail_reaches_the_recorded_plan

echo "# fm-quota-resume.test.sh: all assertions passed"
