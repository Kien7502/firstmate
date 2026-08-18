#!/usr/bin/env bash
# Opt-in credentialed live proof for bin/fm-pi-launch.sh, using the real
# tracked Pi extensions and the shared Pi auth store (no credentials copied),
# pinned to the same captain-approved openai-codex model used by
# tests/fm-pi-primary-live-e2e.test.sh. Confirms empirically, with a real pi
# process, the exact claims fm-pi-launch.sh's header makes:
#   1. explicit -e extension paths load even in a never-trusted directory
#      (the trust-free fallback);
#   2. they do not double-load, and pi does not error, when the SAME
#      directory is also trusted (so auto-discovery would find them too);
#   3. --resume threads through to pi's own --continue and actually resumes
#      the prior conversation, scoped to the launcher's own repo root
#      regardless of the caller's cwd.
set -u

if [ "${FM_PI_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_PI_LIVE_E2E=1 to run the isolated live Pi launcher regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
unset NO_MISTAKES_GATE

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}
pass() {
  printf 'ok - %s\n' "$1"
}

command -v pi >/dev/null 2>&1 || fail "pi not found"

MODEL=(--model openai-codex/gpt-5.6-sol --thinking low)
LAB="$ROOT/.pi-launch-live-e2e.$$"
cleanup() { rm -rf "$LAB"; }
trap cleanup EXIT

build_fixture() {  # <dir>
  local dir=$1
  mkdir -p "$dir/bin" "$dir/.pi/extensions"
  cp "$ROOT/bin/fm-pi-launch.sh" "$dir/bin/fm-pi-launch.sh"
  cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$dir/.pi/extensions/fm-primary-turnend-guard.ts"
  cp "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" "$dir/.pi/extensions/fm-primary-pi-watch.ts"
  cp -r "$ROOT/.pi/extensions/lib" "$dir/.pi/extensions/lib"
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-operational-input.sh" "$dir/bin/fm-operational-input.sh"
  chmod +x "$dir/bin/fm-pi-launch.sh" "$dir/bin/fm-operational-input.sh"
  printf '# Fixture\nReply exactly FIXTURE_AGENTS_LOADED if asked to confirm context.\n' > "$dir/AGENTS.md"
}

launch() {  # <dir> extra pi args...
  local dir=$1
  shift
  FM_HOME="$dir" timeout 40 "$dir/bin/fm-pi-launch.sh" --print "${MODEL[@]}" "$@"
}

test_trust_free_load_in_never_trusted_dir() {
  local fixture out
  fixture="$LAB/untrusted"
  build_fixture "$fixture"
  out=$(cd /tmp && launch "$fixture" --no-session "Reply exactly TRUST_FREE_OK") \
    || fail "trust-free launch failed: $out"
  printf '%s\n' "$out" | grep -Fq "TRUST_FREE_OK" || fail "trust-free launch did not complete a turn: $out"
  [ -f "$fixture/state/.pi-turnend-extension-loaded" ] || fail "turn-end guard extension did not load without trust"
  [ -f "$fixture/state/.pi-watch-extension-loaded" ] || fail "watcher extension did not load without trust"
  pass "explicit -e loads both required extensions in a never-trusted directory"
}

test_no_double_load_or_error_when_also_trusted() {
  local fixture out
  fixture="$LAB/trusted"
  build_fixture "$fixture"
  # Establish real, persisted trust for this exact path so ordinary
  # auto-discovery would ALSO find and load the same two extension files -
  # the scenario the launcher's explicit -e must not duplicate.
  (cd "$fixture" && timeout 40 pi --print --approve --no-session "${MODEL[@]}" "reply ok") >/dev/null 2>&1
  out=$(cd "$fixture" && launch "$fixture" --no-session "Reply exactly NO_DOUBLE_LOAD_OK") \
    || fail "launch in a trusted directory failed (possible duplicate-registration error): $out"
  printf '%s\n' "$out" | grep -Fq "NO_DOUBLE_LOAD_OK" || fail "trusted launch did not complete a turn: $out"
  [ -f "$fixture/state/.pi-turnend-extension-loaded" ] || fail "turn-end guard extension did not load when also trusted"
  [ -f "$fixture/state/.pi-watch-extension-loaded" ] || fail "watcher extension did not load when also trusted"
  pass "explicit -e does not double-load or error when the directory is also trusted"
}

test_resume_scoped_to_launcher_repo_root() {
  local fixture other out
  fixture="$LAB/resume-repo"
  other="$LAB/resume-elsewhere"
  build_fixture "$fixture"
  mkdir -p "$other"

  out=$(cd "$other" && launch "$fixture" "Remember this secret word: PELICAN42. Reply exactly STORED.") \
    || fail "first (memory-establishing) launch failed: $out"
  printf '%s\n' "$out" | grep -Fq "STORED" || fail "first launch did not store the secret word: $out"

  out=$(cd "$other" && launch "$fixture" --resume \
    "What was the secret word I told you? Reply with just the word.") \
    || fail "--resume launch failed: $out"
  printf '%s\n' "$out" | grep -Fq "PELICAN42" \
    || fail "--resume did not recall the prior conversation from an unrelated caller cwd: $out"

  pass "--resume resumes the launcher's own repo-root conversation regardless of the caller's cwd"
}

test_trust_free_load_in_never_trusted_dir
test_no_double_load_or_error_when_also_trusted
test_resume_scoped_to_launcher_repo_root
