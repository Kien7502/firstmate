#!/usr/bin/env bash
# Tests for bin/fm-pi-launch.sh: the canonical captain-facing Pi primary
# launch/restart entry point. Pure logic only - flag parsing, cwd
# independence, and refusal on a corrupt/incomplete checkout - via
# --print-command, so no real pi process is ever started here.
# tests/fm-pi-launch-live-e2e.test.sh covers the credentialed live proof that
# the printed command shape actually loads deterministically.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pi-launch)

# build_fixture <dir> [with_turnend=1] [with_watch=1]: a minimal standalone
# checkout shape (bin/fm-pi-launch.sh plus .pi/extensions/*.ts) so the script
# resolves FM_ROOT from ITS OWN location, exactly like a real captain
# invocation, with no FM_ROOT_OVERRIDE test seam required.
build_fixture() {
  local dir=$1 with_turnend=${2:-1} with_watch=${3:-1}
  mkdir -p "$dir/bin" "$dir/.pi/extensions"
  cp "$ROOT/bin/fm-pi-launch.sh" "$dir/bin/fm-pi-launch.sh"
  chmod +x "$dir/bin/fm-pi-launch.sh"
  [ "$with_turnend" -eq 1 ] && printf 'export default function (pi) {}\n' > "$dir/.pi/extensions/fm-primary-turnend-guard.ts"
  [ "$with_watch" -eq 1 ] && printf 'export default function (pi) {}\n' > "$dir/.pi/extensions/fm-primary-pi-watch.ts"
  printf '%s\n' "$dir"
}

test_fresh_default_loads_both_extensions_no_continue() {
  local fixture out elsewhere
  fixture=$(build_fixture "$TMP_ROOT/fresh")
  elsewhere=$(mktemp -d "$TMP_ROOT/elsewhere.XXXXXX")
  out=$(cd "$elsewhere" && "$fixture/bin/fm-pi-launch.sh" --print-command) \
    || fail "default launch should succeed from an unrelated cwd: $out"
  assert_contains "$out" "FM_PI_HARNESS=pi " "default launch did not export FM_PI_HARNESS=pi"
  assert_contains "$out" "$fixture/.pi/extensions/fm-primary-turnend-guard.ts" "default launch omitted the turn-end guard extension"
  assert_contains "$out" "$fixture/.pi/extensions/fm-primary-pi-watch.ts" "default launch omitted the watcher extension"
  assert_not_contains "$out" "--continue" "default (fresh) launch should not resume a prior conversation"
  case "$out" in
    "FM_PI_HARNESS=pi pi -e "*) : ;;
    *) fail "default launch did not select the plain pi executable: $out" ;;
  esac
  pass "default launch resolves both required extensions by absolute path from any cwd, with no resume flag"
}

test_resume_flag_adds_continue() {
  local fixture out
  fixture=$(build_fixture "$TMP_ROOT/resume")
  out=$("$fixture/bin/fm-pi-launch.sh" --print-command --resume) || fail "--resume launch should succeed: $out"
  assert_contains "$out" "--continue" "--resume did not translate to pi's own --continue flag"
  pass "--resume adds pi's --continue so the existing conversation resumes"
}

test_continue_alias_matches_resume() {
  local fixture out
  fixture=$(build_fixture "$TMP_ROOT/continue-alias")
  out=$("$fixture/bin/fm-pi-launch.sh" --print-command --continue) || fail "--continue alias should succeed: $out"
  assert_contains "$out" "--continue" "--continue alias did not add pi's own --continue flag"
  pass "--continue is accepted as an alias for --resume"
}

test_missing_turnend_extension_refuses() {
  local fixture out status
  fixture=$(build_fixture "$TMP_ROOT/missing-turnend" 0 1)
  out=$("$fixture/bin/fm-pi-launch.sh" --print-command 2>&1) && status=0 || status=$?
  [ "$status" -ne 0 ] || fail "launch should refuse when the turn-end guard extension is missing"
  assert_contains "$out" "required primary extension missing" "refusal did not explain the missing extension"
  assert_contains "$out" "fm-primary-turnend-guard.ts" "refusal did not name the missing turn-end guard extension"
  pass "launch refuses loudly on a checkout missing the turn-end guard extension"
}

test_missing_watch_extension_refuses() {
  local fixture out status
  fixture=$(build_fixture "$TMP_ROOT/missing-watch" 1 0)
  out=$("$fixture/bin/fm-pi-launch.sh" --print-command 2>&1) && status=0 || status=$?
  [ "$status" -ne 0 ] || fail "launch should refuse when the watcher extension is missing"
  assert_contains "$out" "required primary extension missing" "refusal did not explain the missing extension"
  assert_contains "$out" "fm-primary-pi-watch.ts" "refusal did not name the missing watcher extension"
  pass "launch refuses loudly on a checkout missing the watcher extension"
}

test_signed_without_executable_refuses() {
  local fixture out status
  fixture=$(build_fixture "$TMP_ROOT/signed-missing")
  command -v pi-signed >/dev/null 2>&1 && fail "test host unexpectedly has pi-signed on PATH; this refusal case cannot be exercised"
  out=$("$fixture/bin/fm-pi-launch.sh" --print-command --signed 2>&1) && status=0 || status=$?
  [ "$status" -ne 0 ] || fail "launch should refuse --signed when pi-signed is not on PATH"
  assert_contains "$out" "pi-signed executable not found on PATH" "refusal did not explain the missing signed executable"
  pass "--signed refuses rather than silently falling back to plain pi"
}

test_signed_flag_selects_signed_executable() {
  local fixture out fakebin
  fixture=$(build_fixture "$TMP_ROOT/signed-present")
  fakebin=$(fm_fakebin "$TMP_ROOT/signed-present-bin")
  fm_fake_exit0 "$fakebin" pi-signed
  out=$(PATH="$fakebin:$PATH" "$fixture/bin/fm-pi-launch.sh" --print-command --signed) \
    || fail "--signed launch should succeed once pi-signed is on PATH: $out"
  assert_contains "$out" "FM_PI_HARNESS=pi-signed " "--signed did not export FM_PI_HARNESS=pi-signed"
  case "$out" in
    "FM_PI_HARNESS=pi-signed pi-signed -e "*) : ;;
    *) fail "--signed did not select the pi-signed executable: $out" ;;
  esac
  pass "--signed selects the pi-signed executable and its FM_PI_HARNESS marker"
}

test_ambient_fm_pi_harness_selects_signed_without_flag() {
  local fixture out fakebin
  fixture=$(build_fixture "$TMP_ROOT/signed-ambient")
  fakebin=$(fm_fakebin "$TMP_ROOT/signed-ambient-bin")
  fm_fake_exit0 "$fakebin" pi-signed
  out=$(PATH="$fakebin:$PATH" FM_PI_HARNESS=pi-signed "$fixture/bin/fm-pi-launch.sh" --print-command) \
    || fail "ambient FM_PI_HARNESS=pi-signed launch should succeed: $out"
  assert_contains "$out" "FM_PI_HARNESS=pi-signed " "ambient FM_PI_HARNESS=pi-signed was not honored without --signed"
  pass "an ambient FM_PI_HARNESS=pi-signed selects the signed identity without requiring --signed"
}

test_extra_args_pass_through_after_extensions() {
  local fixture out
  fixture=$(build_fixture "$TMP_ROOT/extra-args")
  out=$("$fixture/bin/fm-pi-launch.sh" --print-command --model foo --thinking high) \
    || fail "extra-args launch should succeed: $out"
  assert_contains "$out" "--model foo --thinking high" "extra passthrough args were not preserved in order"
  pass "unrecognized arguments pass through to pi unchanged, after the extension flags"
}

test_double_dash_disables_own_flag_parsing() {
  local fixture out
  fixture=$(build_fixture "$TMP_ROOT/double-dash")
  out=$("$fixture/bin/fm-pi-launch.sh" --print-command -- --resume "a prompt") \
    || fail "-- launch should succeed: $out"
  assert_not_contains "$out" "--continue" "-- should stop this script's own flag parsing, so a literal --resume must not add --continue"
  assert_contains "$out" '--resume a\ prompt' "literal arguments after -- were not passed through verbatim"
  pass "-- stops this script's own flag parsing and passes the remainder through literally"
}

test_help_documents_resume_signed_and_dry_run() {
  local out
  out=$("$ROOT/bin/fm-pi-launch.sh" --help)
  assert_contains "$out" "--resume" "help text omits --resume"
  assert_contains "$out" "--signed" "help text omits --signed"
  assert_contains "$out" "--print-command" "help text omits --print-command"
  assert_contains "$out" "fresh Firstmate session" "help text does not clearly expose the fresh-session default"
  pass "--help documents resume, signed, and the dry-run test seam"
}

test_fresh_default_loads_both_extensions_no_continue
test_resume_flag_adds_continue
test_continue_alias_matches_resume
test_missing_turnend_extension_refuses
test_missing_watch_extension_refuses
test_signed_without_executable_refuses
test_signed_flag_selects_signed_executable
test_ambient_fm_pi_harness_selects_signed_without_flag
test_extra_args_pass_through_after_extensions
test_double_dash_disables_own_flag_parsing
test_help_documents_resume_signed_and_dry_run
