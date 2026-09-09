#!/usr/bin/env bash
# Behavior tests for the verified Cortex Code crewmate/scout adapter.
#
# The facts pinned here are the ones a Cortex Code release could silently change
# and the ones a wrong guess would make dangerous:
#   1. CORTEX_SESSION_ID / CORTEX_TASK_CONTEXT_ID are cortex's own tool-process
#      markers, and they outrank an inherited CLAUDECODE, because cortex does
#      NOT clear one (verified live on Cortex Code v1.1.84 under a claude
#      session, where a cortex Bash tool process carried both together).
#   2. CORTEX_THINKING_EFFORT and the CORTEX_AGENT_* family are NOT identities:
#      cortex reads them from its own settings and environment, so an operator
#      can set them for a process cortex never started.
#   3. cortex ships as a compiled single binary reporting comm=cortex, so
#      ancestry reaches it - unlike gemini's node bundle - and the arm must stay
#      anchored so cortexd/cortex-helper cannot claim the identity.
#   4. The brief rides the launch command as a positional prompt, and the launch
#      must NOT carry --config: cortex's --config settings file is not a hook
#      source, and pointing at one without cortexAgentConnectionName reopens the
#      blocking first-run import dialog.
#   5. cortex's busy/turn-end hooks are WORKTREE-resident at
#      .cortex/settings.local.json (claude's shape, not gemini's), because
#      cortex's hook loader reads only a fixed path set.
#   6. cortex is a crewmate/scout adapter only: its control mechanics are
#      verified while a secondmate launch on it is refused.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"

# bin/fm-harness.sh checks verified ENV markers before ancestry. A suite run
# from inside Cursor, Claude, Pi, Grok, Rovo, or Gemini inherits those markers,
# which outrank the fake ancestry the detection cases set up. Drop the ambient
# markers so the asserted verdict does not depend on which harness launched the
# suite.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS \
  ATLASSIAN_AGENT_TYPE ROVODEV_CLI GEMINI_CLI CORTEX_SESSION_ID CORTEX_TASK_CONTEXT_ID

HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-cortex-harness)

# --- detection ---------------------------------------------------------------

test_cortex_marker_outranks_inherited_claudecode() {
  local out
  # The exact hazard: cortex does not clear an inherited CLAUDECODE, so a cortex
  # worker under a claude session carries both markers at once.
  out=$(CLAUDECODE=1 CORTEX_SESSION_ID=844e250a-a114-4bb6-825e-4def6facfbb2 "$HARNESS")
  [ "$out" = cortex ] || fail "CLAUDECODE + CORTEX_SESSION_ID must detect cortex, got '$out'"
  out=$(CLAUDECODE=1 CORTEX_TASK_CONTEXT_ID=844e250a-a114-4bb6-825e-4def6facfbb2 "$HARNESS")
  [ "$out" = cortex ] || fail "CLAUDECODE + CORTEX_TASK_CONTEXT_ID must detect cortex, got '$out'"
  # Drive the two signals apart so the cases above cannot go quietly vacuous:
  # each marker alone must still produce its own verdict.
  out=$(env -u CLAUDECODE CORTEX_SESSION_ID=s1 "$HARNESS")
  [ "$out" = cortex ] || fail "CORTEX_SESSION_ID alone must detect cortex, got '$out'"
  out=$(env -u CORTEX_SESSION_ID -u CORTEX_TASK_CONTEXT_ID CLAUDECODE=1 "$HARNESS")
  [ "$out" = claude ] || fail "CLAUDECODE alone must still detect claude, got '$out'"
  # Cursor's and gemini's markers still outrank cortex's, preserving the
  # documented order in bin/fm-harness.sh.
  out=$(CURSOR_AGENT=1 CORTEX_SESSION_ID=s1 "$HARNESS")
  [ "$out" = cursor ] || fail "CURSOR_AGENT must still outrank CORTEX_SESSION_ID, got '$out'"
  out=$(GEMINI_CLI=1 CORTEX_SESSION_ID=s1 "$HARNESS")
  [ "$out" = gemini ] || fail "GEMINI_CLI must still outrank CORTEX_SESSION_ID, got '$out'"
  pass "fm-harness.sh: cortex's markers outrank an inherited CLAUDECODE"
}

test_cortex_does_not_claim_configured_input_variables() {
  local out var
  # CORTEX_THINKING_EFFORT arrives from the operator's own settings.json `env`
  # block, and the CORTEX_AGENT_* family are read as inputs, so any of them can
  # be present in a process cortex never started. None may claim the identity.
  for var in CORTEX_THINKING_EFFORT CORTEX_AGENT_ENABLE_SUBAGENTS CORTEX_PROJECT_DIR; do
    out=$(env -u CLAUDECODE -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI \
          -u PI_CODING_AGENT -u GROK_AGENT -u CORTEX_SESSION_ID -u CORTEX_TASK_CONTEXT_ID \
          "$var=high" "$HARNESS")
    [ "$out" != cortex ] || fail "$var must never claim the cortex identity, got '$out'"
  done
  # An empty marker is not the verified signal either.
  out=$(env -u CLAUDECODE -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI \
        -u PI_CODING_AGENT -u GROK_AGENT -u CORTEX_TASK_CONTEXT_ID CORTEX_SESSION_ID= "$HARNESS")
  [ "$out" != cortex ] || fail "an empty CORTEX_SESSION_ID must not claim cortex, got '$out'"
  pass "fm-harness.sh: a configured CORTEX_* input never claims the cortex identity"
}

# run_fake_ancestry_detect <fakebin> <comm> <args>: bin/fm-harness.sh with every
# verified marker cleared, so ONLY the faked ancestry can produce a verdict.
run_fake_ancestry_detect() {
  local fakebin=$1 comm=$2 args=$3
  env -u CLAUDECODE -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI \
    -u PI_CODING_AGENT -u GROK_AGENT -u CORTEX_SESSION_ID -u CORTEX_TASK_CONTEXT_ID \
    FAKE_PS_COMM="$comm" FAKE_PS_ARGS="$args" PATH="$fakebin:$PATH" "$HARNESS"
}

test_cortex_ancestry_matches_only_the_anchored_command_name() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/anc")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' "${FAKE_PS_COMM:?}"; exit 0 ;;
  *"args="*) printf '%s\n' "${FAKE_PS_ARGS:?}"; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  # cortex is a compiled binary, so ancestry is a real detection path here even
  # with every marker cleared. The installed launcher is a symlink into a
  # versioned directory, so the resolved comm is a PATH whose basename is cortex.
  out=$(run_fake_ancestry_detect "$fakebin" /Users/u/.local/share/cortex/1.1.84+190213/cortex 'cortex --bypass')
  [ "$out" = cortex ] || fail "a versioned cortex binary path must be detected by ancestry, got '$out'"
  out=$(run_fake_ancestry_detect "$fakebin" cortex 'cortex --bypass')
  [ "$out" = cortex ] || fail "a bare cortex command name must be detected by ancestry, got '$out'"

  # Divergence: the negatives are what keep the positives from being vacuous.
  # The arm is anchored, never *cortex*, so neighbouring names must not match.
  out=$(run_fake_ancestry_detect "$fakebin" cortexd 'cortexd --serve')
  [ "$out" != cortex ] || fail "cortexd must not be misread as the cortex harness, got '$out'"
  out=$(run_fake_ancestry_detect "$fakebin" cortex-helper 'cortex-helper --serve')
  [ "$out" != cortex ] || fail "cortex-helper must not be misread as the cortex harness, got '$out'"
  # A later argument naming cortex proves nothing about the running harness.
  out=$(run_fake_ancestry_detect "$fakebin" node 'node /home/u/app/server.js --agent cortex')
  [ "$out" != cortex ] || fail "a later node argument naming cortex must not detect cortex, got '$out'"
  pass "fm-harness.sh: ancestry detects an anchored cortex command and rejects neighbours"
}

# --- control mechanics -------------------------------------------------------

test_cortex_control_mechanics_are_the_verified_ones() {
  local out
  fm_control_harness_supported cortex || fail "cortex must be a supported control harness"
  out=$(fm_control_interrupt_key cortex)
  [ "$out" = Escape ] || fail "cortex interrupts on Escape, got '$out'"
  out=$(fm_control_interrupt_repeat cortex)
  [ "$out" = 1 ] || fail "cortex interrupts on a single press, got '$out'"
  out=$(fm_control_interrupt_clear_key cortex)
  [ -z "$out" ] || fail "cortex needs no composer clear key, got '$out'"
  out=$(fm_control_interrupt_ack_source cortex)
  [ "$out" = none ] || fail "cortex records no adapter-owned cancellation ack, got '$out'"
  # /exit is NOT a cortex command: typing it leaves the slash-command picker open
  # on a fuzzy `quit` match, so the exit command must be /quit.
  out=$(fm_control_exit_command cortex)
  [ "$out" = /quit ] || fail "cortex exits with /quit, got '$out'"
  pass "fm-control-lib.sh: cortex carries its verified interrupt and exit mechanics"
}

test_cortex_and_codex_families_do_not_swallow_each_other() {
  local out
  out=$(fm_control_harness_family cortex-1.1.84)
  [ "$out" = cortex ] || fail "a recorded cortex* harness must resolve to cortex, got '$out'"
  # Divergence: the two adapter names differ by one letter, so pin that neither
  # prefix arm claims the other's recorded value.
  out=$(fm_control_harness_family codex-0.9)
  [ "$out" = codex ] || fail "a recorded codex* harness must still resolve to codex, got '$out'"
  pass "fm-control-lib.sh: the cortex and codex prefix arms stay disjoint"
}

test_cortex_is_crewmate_and_scout_only() {
  fm_control_harness_supports_kind cortex ship \
    || fail "cortex must be verified for ship work"
  fm_control_harness_supports_kind cortex scout \
    || fail "cortex must be verified for scout work"
  ! fm_control_harness_supports_kind cortex secondmate \
    || fail "cortex has no primary supervision protocol and must be refused for secondmates"
  pass "fm-control-lib.sh: cortex is a crewmate/scout adapter only"
}

test_cortex_wiring_is_the_worktree_local_settings_file() {
  local out
  # This is the load-bearing difference from gemini: cortex's --config settings
  # file is NOT a hook source, so the wiring is worktree-resident like claude's.
  out=$(fm_control_harness_wiring_paths cortex /wt /state task-1)
  [ "$out" = "/wt/.cortex/settings.local.json" ] \
    || fail "cortex's per-task wiring is its worktree .cortex/settings.local.json, got '$out'"
  # And it must not be confused with claude's file in the same worktree, so a
  # relaunch between the two retires the right one.
  out=$(fm_control_harness_wiring_paths claude /wt /state task-1)
  [ "$out" = "/wt/.claude/settings.local.json" ] \
    || fail "claude's wiring path must be unchanged, got '$out'"
  pass "fm-control-lib.sh: cortex's wiring is its own worktree-local settings file"
}

test_cortex_trusts_only_its_own_semantic_source() {
  local out
  out=$(fm_busy_sources_for_harness cortex)
  case " $out " in
    *" cortex-hook "*) ;;
    *) fail "cortex must trust its cortex-hook source, got '$out'" ;;
  esac
  # Divergence: one adapter's writer must never classify another's task.
  fm_busy_source_trusted cortex cortex-hook || fail "cortex must trust cortex-hook"
  ! fm_busy_source_trusted cortex claude-hook \
    || fail "cortex must not trust claude's writer"
  ! fm_busy_source_trusted claude cortex-hook \
    || fail "claude must not trust cortex's writer"
  pass "fm-busy-lib.sh: cortex trusts only cortex-hook plus the firstmate-owned sources"
}

# --- spawn -------------------------------------------------------------------

make_cortex_case() {  # <name> <id>
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" cortex)
  fm_test_spawn_home "$home" cortex
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  printf '%s|%s|%s|%s|%s\n' "$case_dir" "$home" "$proj" "$wt" "$fakebin"
}

read_cortex_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_cortex_spawn() {  # <home> <wt> <fakebin> <spawn-args...>
  local home=$1 wt=$2 fakebin=$3
  shift 3
  fm_test_run_spawn "$home" "$wt" "$fakebin" "$@" --mode no-mistakes --yolo off
}

test_cortex_launch_carries_the_brief_positionally() {
  local rec id=cx-launch out launch_log launch
  rec=$(make_cortex_case launch "$id")
  read_cortex_case "$rec"
  launch_log="$CASE_DIR/launch.log"
  out=$(FM_FAKE_LAUNCH_LOG="$launch_log" \
    run_cortex_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "cortex spawn should succeed: $out"
  assert_contains "$out" "spawned $id harness=cortex" "cortex spawn did not complete normally"
  launch=$(cat "$launch_log")
  # The positional brief is the whole point of item 1: cortex takes the brief at
  # launch, so there is no readiness gate and no typed pointer.
  assert_contains "$launch" 'encode launch-brief' "cortex launch must carry the brief at launch"
  assert_contains "$launch" '--bypass' "cortex launch must auto-approve tool calls"
  assert_contains "$launch" '--auto-accept-plans' "cortex launch must clear the plan-mode gate"
  assert_contains "$launch" '--no-auto-update' "cortex launch must pin the installed version"
  # cortex does not scrub an inherited CLAUDECODE, so the launch boundary must.
  assert_contains "$launch" '-u CLAUDECODE' "cortex launch must clear the foreign claude marker"
  assert_contains "$launch" '-u GEMINI_CLI' "cortex launch must clear the foreign gemini marker"
  assert_contains "$launch" '-u CURSOR_AGENT' "cortex launch must clear the foreign cursor marker"
  # --config would carry no hooks AND would reopen the blocking first-run import
  # dialog when the file lacks cortexAgentConnectionName. It must never appear.
  case "$launch" in
    *--config*) fail "cortex launch must not pass --config: it carries no hooks and reopens onboarding" ;;
  esac
  pass "fm-spawn.sh: a cortex launch delivers the brief positionally with no --config"
}

test_cortex_spawn_writes_worktree_hooks_and_excludes_them() {
  local rec id=cx-hooks out settings excl ev
  rec=$(make_cortex_case hooks "$id")
  read_cortex_case "$rec"
  out=$(run_cortex_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "cortex spawn should succeed: $out"
  settings="$WT_DIR/.cortex/settings.local.json"
  assert_present "$settings" "cortex spawn did not write its hook settings"
  jq -e . "$settings" >/dev/null || fail "cortex hook settings are not valid JSON"
  for ev in UserPromptSubmit Stop SessionEnd; do
    jq -e ".hooks[\"$ev\"]" "$settings" >/dev/null || fail "cortex hook settings lack $ev"
  done
  # SubagentStop must stay unwired: cortex runs subagents, so closing the turn on
  # one would clear the worker's busy record while its own turn is still running.
  if jq -e '.hooks["SubagentStop"]' "$settings" >/dev/null 2>&1; then
    fail "cortex must not wire SubagentStop; a subagent's stop is not the worker's turn end"
  fi
  # The firstmate-owned file must not land in the project's index.
  excl=$(git -C "$WT_DIR" rev-parse --git-path info/exclude)
  grep -qxF '.cortex/settings.local.json' "$excl" \
    || fail "cortex hook settings must be git-excluded from the worktree"
  # And nothing may be written into a firstmate-owned state file, because cortex
  # has no settings-path environment variable to reach one.
  assert_absent "$HOME_DIR/state/$id.cortex-settings.json" \
    "cortex must not claim a state-resident settings file it cannot reach"
  pass "fm-spawn.sh: cortex hooks land in the git-excluded worktree settings file"
}

run_cortex_hook() {  # <settings.json> <hook-event>
  local cmd
  cmd=$(jq -r ".hooks[\"$2\"][0].hooks[0].command" "$1")
  [ -n "$cmd" ] && [ "$cmd" != null ] || fail "no $2 hook command in $1"
  sh -c "$cmd" >/dev/null
}

test_cortex_hooks_drive_the_semantic_busy_lifecycle() {
  local rec id=cx-life out state settings
  rec=$(make_cortex_case lifecycle "$id")
  read_cortex_case "$rec"
  out=$(run_cortex_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "cortex spawn should succeed: $out"
  state="$HOME_DIR/state"
  settings="$WT_DIR/.cortex/settings.local.json"

  out=$(fm_busy_classify tmux fake:w cortex "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "seed after spawn must be 'busy fm-spawn', got '$out'"

  # This is item 2's acceptance test: bin/fm-crew-state.sh reads a cortex worker
  # through this classifier, so a real state here is a real state there.
  # The delete uses the fail-on-unset form so an empty fixture variable aborts
  # instead of resolving to a path nobody intended (AGENTS.md section 7).
  rm -f "${state:?}/${id:?}.turn-ended"
  run_cortex_hook "$settings" Stop || fail "Stop hook command failed"
  [ -f "$state/$id.turn-ended" ] || fail "Stop must touch the turn-ended notification marker"
  out=$(fm_busy_classify tmux fake:w cortex "$id" "$state")
  [ "$out" = "idle cortex-hook" ] || fail "Stop must classify 'idle cortex-hook', got '$out'"

  run_cortex_hook "$settings" UserPromptSubmit || fail "UserPromptSubmit hook command failed"
  out=$(fm_busy_classify tmux fake:w cortex "$id" "$state")
  [ "$out" = "busy cortex-hook" ] || fail "UserPromptSubmit must classify 'busy cortex-hook', got '$out'"

  # SessionEnd exists so an abnormal end - including an interrupted turn that is
  # then quit, the shape observed live - can never strand a busy record.
  run_cortex_hook "$settings" SessionEnd || fail "SessionEnd hook command failed"
  out=$(fm_busy_classify tmux fake:w cortex "$id" "$state")
  [ "$out" = "idle cortex-hook" ] || fail "SessionEnd must classify idle, got '$out'"
  pass "fm-spawn.sh: cortex hooks open on UserPromptSubmit and close on Stop and SessionEnd"
}

test_cortex_stale_incarnation_hook_is_harmless() {
  local rec id=cx-stale out state settings
  rec=$(make_cortex_case stale "$id")
  read_cortex_case "$rec"
  out=$(run_cortex_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "cortex spawn should succeed: $out"
  state="$HOME_DIR/state"
  settings="$WT_DIR/.cortex/settings.local.json"
  "$ROOT/bin/fm-busy-event.sh" arm "$state" "$id" >/dev/null
  run_cortex_hook "$settings" UserPromptSubmit \
    || fail "a stale-gen hook must still exit 0 so cortex's own lifecycle is never broken"
  out=$(fm_busy_classify tmux fake:w cortex "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "a stale-gen hook event must not change state, got '$out'"
  pass "fm-spawn.sh: cortex hook events from a superseded incarnation are rejected safely"
}

test_cortex_effort_caps_xhigh_and_omits_minimal() {
  local rec out launch_log launch
  # Cortex Code v1.1.84 --effort accepts minimal|low|medium|high|max and has no
  # xhigh, so model-and-effort.md's cap rule applies rather than record-and-omit.
  rec=$(make_cortex_case effort-xhigh cx-eff-1)
  read_cortex_case "$rec"
  launch_log="$CASE_DIR/launch.log"
  out=$(FM_FAKE_LAUNCH_LOG="$launch_log" run_cortex_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
        cx-eff-1 "$PROJ_DIR" --effort xhigh)
  expect_code 0 $? "cortex spawn with xhigh should succeed: $out"
  launch=$(cat "$launch_log")
  # The rendered flag is shell-quoted by fm-spawn, so match that exact form.
  assert_contains "$launch" "--effort 'high'" "xhigh must be capped onto cortex's highest non-max level"
  case "$launch" in
    # Anchored on the rendered flag, not a bare xhigh: the fixture's own tmp
    # path carries the word and would otherwise satisfy this negative.
    *"--effort 'xhigh'"*) fail "cortex has no xhigh; passing it would be a known-bad value" ;;
  esac

  # Divergence: a supported level must pass straight through, so the cap case
  # above cannot be satisfied by an adapter that rewrites every effort to high.
  rec=$(make_cortex_case effort-low cx-eff-2)
  read_cortex_case "$rec"
  launch_log="$CASE_DIR/launch.log"
  out=$(FM_FAKE_LAUNCH_LOG="$launch_log" run_cortex_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
        cx-eff-2 "$PROJ_DIR" --effort low)
  expect_code 0 $? "cortex spawn with low should succeed: $out"
  assert_contains "$(cat "$launch_log")" "--effort 'low'" "a supported effort must pass straight through"
  pass "fm-spawn.sh: cortex caps xhigh onto high and passes supported levels through"
}

test_cortex_secondmate_launch_is_refused() {
  local rec out
  rec=$(make_cortex_case secondmate cx-sm-1)
  read_cortex_case "$rec"
  out=$(fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
        --secondmate cx-sm-1 "$CASE_DIR/sm-home" cortex 2>&1)
  expect_code 1 $? "a cortex secondmate spawn must be refused: $out"
  assert_contains "$out" 'crewmate/scout adapter only' \
    "the cortex secondmate refusal must name the crewmate/scout boundary"
  pass "fm-spawn.sh: a cortex secondmate launch is refused before anything is stood up"
}

test_cortex_spawn_refuses_a_missing_executable() {
  local rec id=cx-nobin out status launch_log
  rec=$(make_cortex_case nobin "$id")
  read_cortex_case "$rec"
  launch_log="$CASE_DIR/launch.log"
  : > "$launch_log"
  # Both resolution paths must miss: the fakebin's cortex stub is removed and
  # PATH is pinned to system directories, so `command -v cortex` cannot reach a
  # developer's real install, and HOME is an empty directory so the
  # ~/.local/bin/cortex fallback cannot resolve either. The refusal must land
  # before any endpoint, metadata, or typed launch command exists.
  rm -f "${FAKEBIN_DIR:?}/cortex"
  mkdir -p "$CASE_DIR/empty-home"
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" HOME="$CASE_DIR/empty-home" \
    CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$launch_log" PATH="$FAKEBIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 1 "$status" "a cortex spawn with no executable must be refused: $out"
  assert_contains "$out" 'cortex executable not found' "the refusal must name the missing executable"
  assert_absent "$HOME_DIR/state/$id.meta" "a refused cortex spawn must leave no task metadata"
  [ ! -s "$launch_log" ] || fail "a refused cortex spawn must not type a launch command"
  pass "fm-spawn.sh: a cortex spawn refuses before endpoint creation when the binary is absent"
}

test_cortex_marker_outranks_inherited_claudecode
test_cortex_does_not_claim_configured_input_variables
test_cortex_ancestry_matches_only_the_anchored_command_name
test_cortex_control_mechanics_are_the_verified_ones
test_cortex_and_codex_families_do_not_swallow_each_other
test_cortex_is_crewmate_and_scout_only
test_cortex_wiring_is_the_worktree_local_settings_file
test_cortex_trusts_only_its_own_semantic_source
test_cortex_launch_carries_the_brief_positionally
test_cortex_spawn_writes_worktree_hooks_and_excludes_them
test_cortex_hooks_drive_the_semantic_busy_lifecycle
test_cortex_stale_incarnation_hook_is_harmless
test_cortex_effort_caps_xhigh_and_omits_minimal
test_cortex_secondmate_launch_is_refused
test_cortex_spawn_refuses_a_missing_executable
