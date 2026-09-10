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
#      ancestry reaches it - unlike gemini's node bundle - and both the harness
#      arm and the tmux pane classifier must stay anchored so cortexd and
#      cortex-helper cannot claim the identity. The pane classifier needs its
#      own cortex arm: the neighbouring *codex* glob does not cover it, and
#      without one every fm-control verb refuses a live cortex worker.
#   4. The brief rides the launch command as a positional prompt, and the launch
#      must NOT carry --config: cortex's --config settings file is not a hook
#      source, and pointing at one without cortexAgentConnectionName reopens the
#      blocking first-run import dialog.
#   5. cortex's busy/turn-end hooks are WORKTREE-resident at
#      .cortex/settings.local.json (claude's shape, not gemini's), because
#      cortex's hook loader reads only a fixed path set.
#   6. cortex is a crewmate/scout adapter only: its control mechanics are
#      verified while a secondmate launch on it is refused.
#   7. herdr's installed build has no cortex integration, so its agent read
#      cannot see a cortex worker: agent_not_found is not evidence of absence
#      for cortex, and reading it as one would let exit, --relaunch and the
#      husk classifier act on a live worker. That scoping is NOT cortex-only and
#      must not be pinned to a harness name: the covered set is read from herdr's
#      own reported integration coverage, so rovo, muse, and gemini behave
#      identically today and a harness herdr adds later needs no firstmate change.
#   8. The steering doorbell reads that same agent state, and it is the one
#      consumer whose misread is SILENT rather than a refusal: unthreaded it
#      never types and reports the worker exited, so a cortex worker on herdr
#      is startable but unsteerable. Both it and fm_backend_agent_alive must
#      keep the harness-blind verdict for a caller that names no harness.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"

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

# make_fake_ps: a fakebin whose `ps` answers the ancestry walk from
# FAKE_PS_COMM/FAKE_PS_ARGS, so a test controls the ancestry instead of
# inheriting the real one.
make_fake_ps() {  # <dir> -> echoes fakebin dir
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '%s\n' "${FAKE_PS_COMM:?}"; exit 0 ;;
  *"args="*) printf '%s\n' "${FAKE_PS_ARGS:?}"; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  printf '%s\n' "$fakebin"
}

test_cortex_does_not_claim_configured_input_variables() {
  local out var fakebin
  # cortex is detected by ancestry as well as by its markers, and this suite now
  # routinely RUNS inside a cortex worker (the fleet default), whose real
  # ancestry genuinely is cortex. Clearing the markers alone would therefore let
  # the true ancestry answer and make these negatives fail for a reason that has
  # nothing to do with the variable under test, so ancestry is pinned to a plain
  # shell here: the env var is then the only thing that could claim the identity.
  fakebin=$(make_fake_ps "$TMP_ROOT/input-vars")
  # CORTEX_THINKING_EFFORT arrives from the operator's own settings.json `env`
  # block, and the CORTEX_AGENT_* family are read as inputs, so any of them can
  # be present in a process cortex never started. None may claim the identity.
  for var in CORTEX_THINKING_EFFORT CORTEX_AGENT_ENABLE_SUBAGENTS CORTEX_PROJECT_DIR; do
    out=$(env -u CLAUDECODE -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI \
          -u PI_CODING_AGENT -u GROK_AGENT -u CORTEX_SESSION_ID -u CORTEX_TASK_CONTEXT_ID \
          FAKE_PS_COMM=bash FAKE_PS_ARGS='-bash' PATH="$fakebin:$PATH" \
          "$var=high" "$HARNESS")
    [ "$out" != cortex ] || fail "$var must never claim the cortex identity, got '$out'"
  done
  # An empty marker is not the verified signal either.
  out=$(env -u CLAUDECODE -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI \
        -u PI_CODING_AGENT -u GROK_AGENT -u CORTEX_TASK_CONTEXT_ID \
        FAKE_PS_COMM=bash FAKE_PS_ARGS='-bash' PATH="$fakebin:$PATH" \
        CORTEX_SESSION_ID= "$HARNESS")
  [ "$out" != cortex ] || fail "an empty CORTEX_SESSION_ID must not claim cortex, got '$out'"
  # Divergence: with the SAME pinned-shell ancestry, a real marker must still be
  # detected, so the negatives above cannot pass merely because detection broke.
  out=$(env -u CLAUDECODE -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI \
        -u PI_CODING_AGENT -u GROK_AGENT -u CORTEX_TASK_CONTEXT_ID \
        FAKE_PS_COMM=bash FAKE_PS_ARGS='-bash' PATH="$fakebin:$PATH" \
        CORTEX_SESSION_ID=s1 "$HARNESS")
  [ "$out" = cortex ] || fail "a real CORTEX_SESSION_ID must still claim cortex, got '$out'"
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
  fakebin=$(make_fake_ps "$TMP_ROOT/anc")
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

# --- endpoint liveness -------------------------------------------------------

test_cortex_pane_process_classifies_as_a_live_agent() {
  local name
  # A live cortex pane's foreground process reports comm=cortex. Unattributed,
  # the composed verdict is `ambiguous`, and interrupt, exit and relaunch all
  # refuse the very worker the control mechanics above exist to supervise.
  for name in cortex /Users/u/.local/bin/cortex \
    /Users/u/.local/share/cortex/1.1.84+190213/cortex; do
    [ "$(fm_backend_tmux_classify_process_name "$name")" = agent ] \
      || fail "a cortex pane process ($name) must classify as a live agent"
  done
  # argv[0] carries the identity on its own, which is the name surface procps
  # reports on Linux when the command name says nothing.
  [ "$(fm_backend_tmux_classify_process_name '' cortex)" = agent ] \
    || fail "cortex named only in argv[0] must classify as a live agent"

  # Divergence: cortex has its OWN arm because the neighbouring *codex* glob
  # does not cover it, and that arm is anchored, so the near misses below must
  # stay unattributed rather than be swept in by a widened *cortex* glob.
  for name in cortexd cortex-helper mycortex cortex.bak /opt/cortexd/bin/run; do
    [ "$(fm_backend_tmux_classify_process_name "$name")" = other ] \
      || fail "'$name' merely resembles cortex and must not classify as a live agent"
  done

  # The neighbouring verdicts the cortex arm must leave exactly as they were.
  for name in codex claude opencode rovo omp pi; do
    [ "$(fm_backend_tmux_classify_process_name "$name")" = agent ] \
      || fail "'$name' must still classify as a live agent"
  done
  [ "$(fm_backend_tmux_classify_process_name ompd)" = other ] \
    || fail "ompd must still stay unattributed"
  [ "$(fm_backend_tmux_classify_process_name bash)" = shell ] \
    || fail "an idle shell must still classify as a shell"
  pass "backends/tmux.sh: a cortex pane process classifies as a live agent and its near misses do not"
}

# make_herdr_agentless_fakebin: a canned `herdr` CLI whose pane structurally
# exists while `agent get` answers agent_not_found for it. That is exactly what
# the installed herdr build answers for a LIVE pane running a harness it has no
# integration for, and it is indistinguishable from the same answer for a
# genuinely empty restored pane.
#
# It also serves the ONE coverage surface the adapter derives the covered set
# from. FM_TEST_HERDR_COVERAGE selects whether it answers:
#   both    - `integration status` answers (the normal case).
#   none    - it does not, so coverage is unreadable and every read must refuse.
#
# FM_TEST_HERDR_PROCESS_INFO, when set, is the JSON body `pane process-info`
# answers with, so a test can drive the process-attribution fallback with a real
# response shape instead of stubbing the function that parses it.
make_herdr_agentless_fakebin() {  # <dir> -> echoes fakebin dir
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
# Every invocation is recorded when FM_TEST_HERDR_LOG names a file, so a test
# can assert on what herdr was actually ASKED to do - in particular whether the
# doorbell was ever typed - and not only on a return code.
[ -z "${FM_TEST_HERDR_LOG:-}" ] || printf '%s\n' "$*" >> "$FM_TEST_HERDR_LOG"
# The integration names this fake build knows. cortex, rovo, muse, and gemini
# are absent exactly as they are absent from the real herdr 0.8.2 build.
FAKE_INTEGRATIONS="pi omp claude codex copilot kimi opencode cursor grok"
COVERAGE=${FM_TEST_HERDR_COVERAGE:-both}
case "${1:-} ${2:-}" in
  "integration status")
    [ "$COVERAGE" = both ] || exit 1
    for n in $FAKE_INTEGRATIONS; do
      printf '%s: not installed (/home/u/.%s/hooks/herdr-agent-state.sh)\n' "$n" "$n"
    done
    exit 0
    ;;
  "status --json") printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n' ;;
  "pane get") printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "${3:-}" ;;
  "pane process-info") printf '%s\n' "${FM_TEST_HERDR_PROCESS_INFO:-}" ;;
  "agent get") printf '{"error":{"code":"agent_not_found","message":"agent target %s not found"}}\n' "${3:-}" ;;
esac
exit 0
SH
  chmod +x "$fb/herdr"
  printf '%s\n' "$fb"
}

herdr_backend_eval() {  # <fakebin> <expression>
  PATH="$1:$PATH" bash -c ". \"\$0/bin/backends/herdr.sh\"; $2" "$ROOT"
}

# The inbox library in a subshell with its state root pinned, mirroring
# tests/fm-task-inbox.test.sh's own idiom. Sourced fresh per call so a ring
# never inherits this suite's backend state.
inbox_lib() {  # <state> <function> [args...]
  local state=$1
  shift
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    fn=$2
    shift 2
    "$fn" "$@"
  ' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$@"
}

test_cortex_herdr_agent_read_is_not_agent_free_proof() {
  local fb out h
  command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; return 0; }
  mkdir -p "$TMP_ROOT/herdr-blind"
  fb=$(make_herdr_agentless_fakebin "$TMP_ROOT/herdr-blind")

  # For EVERY harness this build ships no integration for, the read proves
  # nothing, so it must resolve to an unreadable endpoint rather than a
  # positively agent-free one. cortex is the harness the fleet runs on, but it is
  # not special: the rule is derived from herdr's own coverage, so rovo, muse,
  # and gemini - none of which herdr integrates with either - must behave
  # identically. Pinning only cortex here is exactly the bug this replaces.
  for h in cortex rovo muse gemini; do
    out=$(herdr_backend_eval "$fb" "fm_backend_herdr_agent_state fmtest:w1:p1 $h")
    [ "$out" = unreadable ] \
      || fail "a $h pane herdr cannot see must read unreadable, got '$out'"
    out=$(herdr_backend_eval "$fb" "fm_backend_herdr_pane_agent_state fmtest w1:p1 $h")
    [ "$out" = unknown ] \
      || fail "agent_not_found is not evidence of absence for $h, got '$out'"
    out=$(herdr_backend_eval "$fb" "fm_backend_herdr_tab_is_husk fmtest w1:p1 $h && echo husk || echo refused")
    [ "$out" = refused ] || fail "a $h tab must not be classified a husk, got '$out'"
  done

  # Divergence: the SAME read for a harness herdr DOES integrate with, and for a
  # caller that names no harness at all, must keep today's verdict exactly.
  # Without this the case above could pass vacuously by calling everything
  # unreadable.
  for h in claude codex pi opencode cursor grok kimi omp; do
    out=$(herdr_backend_eval "$fb" "fm_backend_herdr_agent_state fmtest:w1:p1 $h")
    [ "$out" = dead ] \
      || fail "an agent-free $h pane must still read dead, got '$out'"
  done
  # pi-signed is firstmate's signed launch of the same pi agent, so herdr's `pi`
  # integration covers it even though that exact name is not in herdr's list.
  out=$(herdr_backend_eval "$fb" 'fm_backend_herdr_agent_state fmtest:w1:p1 pi-signed')
  [ "$out" = dead ] \
    || fail "pi-signed must resolve through herdr's pi integration, got '$out'"
  out=$(herdr_backend_eval "$fb" 'fm_backend_herdr_agent_state fmtest:w1:p1')
  [ "$out" = dead ] \
    || fail "a harness-less caller must keep the existing verdict, got '$out'"
  out=$(herdr_backend_eval "$fb" 'fm_backend_herdr_tab_is_husk fmtest w1:p1 claude && echo husk || echo refused')
  [ "$out" = husk ] || fail "an agent-free claude tab must still classify as a husk, got '$out'"
  pass "backends/herdr.sh: an agent_not_found read is not agent-free proof for any harness herdr does not integrate with"
}

# make_herdr_alt_fakebin: a herdr executable at <path> that answers pane get and
# agent get exactly like the PATH fake, but reports <integration-status-body> as
# its own coverage. It is never placed on PATH, so it is reachable only through
# the client selection FM_BACKEND_HERDR_BIN/FM_BACKEND_HERDR_CLIENT_SESSION
# express - which is what makes it usable to tell the two apart.
make_herdr_alt_fakebin() {  # <path> <integration-status-body>
  local path=$1
  cat > "$path" <<SH
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  --version) printf 'herdr 9.9.9-selected\n'; exit 0 ;;
esac
case "\${1:-} \${2:-}" in
  "integration status") printf '%s' "$2"; exit 0 ;;
  "status --json") printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}\n' ;;
  "pane get") printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "\${3:-}" ;;
  "agent get") printf '{"error":{"code":"agent_not_found","message":"agent target %s not found"}}\n' "\${3:-}" ;;
esac
exit 0
SH
  chmod +x "$path"
}

test_herdr_coverage_is_derived_not_pinned() {
  local fb out dir noise covering cortex_pane
  command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; return 0; }
  dir="$TMP_ROOT/herdr-coverage"
  mkdir -p "$dir"
  fb=$(make_herdr_agentless_fakebin "$dir")

  # A herdr whose status surface is prose rather than integration rows.
  noise="$dir/noise-herdr"
  make_herdr_alt_fakebin "$noise" \
    'Error: could not reach the herdr server
Note: start one with herdr server
'
  # A herdr that DOES ship a cortex integration, so its coverage disagrees with
  # the PATH build's.
  covering="$dir/covering-herdr"
  make_herdr_alt_fakebin "$covering" \
    'claude: not installed (/home/u/.claude/hooks/herdr-agent-state.sh)
cortex: not installed (/home/u/.cortex/hooks/herdr-agent-state.sh)
'

  # The covered set comes from herdr, so a build that DOES integrate with a
  # harness must make that harness's read informative again with no firstmate
  # change. This is the property a hardcoded harness name cannot have.
  out=$(PATH="$fb:$PATH" FM_TEST_HERDR_COVERAGE=both bash -c '
    . "$0/bin/backends/herdr.sh"
    # Same fake build, except this one also ships a cortex integration.
    fm_backend_herdr_integration_names() { printf "claude\ncortex\n"; }
    fm_backend_herdr_agent_state fmtest:w1:p1 cortex' "$ROOT")
  [ "$out" = dead ] \
    || fail "a build that integrates with cortex must make its read informative, got '$out'"

  # Coverage must come from the client that ANSWERED the agent read it
  # justifies. The client selection is scoped to one session, so a selection
  # made for another session must not reach this one: `agent get` for fmtest
  # goes to the PATH build (no cortex integration, so its agent_not_found proves
  # nothing), and reading coverage from the selected build instead would declare
  # cortex covered and classify a live worker agent-free.
  out=$(PATH="$fb:$PATH" FM_BACKEND_HERDR_BIN="$covering" \
    FM_BACKEND_HERDR_CLIENT_SESSION=another-session bash -c '
    . "$0/bin/backends/herdr.sh"; fm_backend_herdr_agent_state fmtest:w1:p1 cortex' "$ROOT" 2>/dev/null)
  [ "$out" = unreadable ] \
    || fail "coverage from a client selected for a DIFFERENT session must not justify this session's read, got '$out'"

  # The same selection made FOR this session is the one that counts: then both
  # the agent read and its coverage come from that build, which does ship cortex.
  out=$(PATH="$fb:$PATH" FM_BACKEND_HERDR_BIN="$covering" \
    FM_BACKEND_HERDR_CLIENT_SESSION=fmtest bash -c '
    . "$0/bin/backends/herdr.sh"; fm_backend_herdr_agent_state fmtest:w1:p1 cortex' "$ROOT" 2>/dev/null)
  [ "$out" = dead ] \
    || fail "the client selected for this session must supply both the agent read and its coverage, got '$out'"

  # Only rows carrying an integration's own hook path are names. A line of any
  # other `Word: text` shape must not be captured, because a captured stranger
  # makes an otherwise unreadable surface look readable - and a readable surface
  # resolves an uncovered harness to "provably no integration", the one unsafe
  # direction.
  out=$(PATH="$fb:$PATH" FM_BACKEND_HERDR_BIN="$noise" \
    FM_BACKEND_HERDR_CLIENT_SESSION=fmtest bash -c '
    . "$0/bin/backends/herdr.sh"; fm_backend_herdr_integration_names fmtest' "$ROOT")
  [ -z "$out" ] \
    || fail "a status surface carrying no integration rows must yield no names, got '$out'"
  out=$(PATH="$fb:$PATH" FM_BACKEND_HERDR_BIN="$noise" \
    FM_BACKEND_HERDR_CLIENT_SESSION=fmtest bash -c '
    . "$0/bin/backends/herdr.sh"; fm_backend_herdr_agent_state fmtest:w1:p1 cortex' "$ROOT" 2>/dev/null)
  [ "$out" = unreadable ] \
    || fail "a status surface of prose must refuse rather than claim cortex uncovered-and-agent-free, got '$out'"

  # The coverage read has THREE outcomes and each must stay distinct at the
  # branch point. Every case below runs with a foreground process the fallback
  # WOULD attribute as a live agent, so a branch that consults it when it must
  # not shows up as a wrong verdict instead of passing vacuously on an empty
  # process-info body.
  cortex_pane='{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p1","foreground_processes":[{"pid":99,"name":"cortex","argv0":"cortex"}]}}}'

  # 1. COVERED: herdr's own registry is authoritative, so agent_not_found is
  # real proof and the fallback never runs - even though a cortex process is
  # sitting right there in the pane.
  out=$(PATH="$fb:$PATH" FM_TEST_HERDR_COVERAGE=both FM_TEST_HERDR_PROCESS_INFO="$cortex_pane" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_agent_state fmtest:w1:p1 claude' "$ROOT" 2>/dev/null)
  [ "$out" = dead ] \
    || fail "a covered harness must keep herdr's registry verdict and never consult the process, got '$out'"

  # 2. PROVABLY UNCOVERED: agent_not_found carries no information, so the
  # fallback is justified and answers on its own evidence. This is the only
  # outcome it may run for.
  out=$(PATH="$fb:$PATH" FM_TEST_HERDR_COVERAGE=both FM_TEST_HERDR_PROCESS_INFO="$cortex_pane" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_agent_state fmtest:w1:p1 cortex' "$ROOT" 2>/dev/null)
  [ "$out" = alive ] \
    || fail "a provably uncovered harness must be attributed by its process, got '$out'"

  # 3. UNREADABLE: which of the two above applies is itself unknown, so the
  # process is NOT consulted and every harness refuses. Asked about claude, a
  # pane running cortex must not answer `alive` - that is a confidently wrong
  # attribution, worse than the blind read this change replaced, because
  # nothing about it looks broken.
  out=$(PATH="$fb:$PATH" FM_TEST_HERDR_COVERAGE=none FM_TEST_HERDR_PROCESS_INFO="$cortex_pane" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_agent_state fmtest:w1:p1 claude' "$ROOT" 2>/dev/null)
  [ "$out" = unreadable ] \
    || fail "an unreadable coverage read must not attribute claude from a cortex process, got '$out'"
  out=$(PATH="$fb:$PATH" FM_TEST_HERDR_COVERAGE=none FM_TEST_HERDR_PROCESS_INFO="$cortex_pane" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_agent_state fmtest:w1:p1 cortex' "$ROOT" 2>/dev/null)
  [ "$out" = unreadable ] \
    || fail "an unreadable coverage read must refuse rather than fall back, got '$out'"

  # A harness-less caller keeps its documented behavior even then: it never had
  # a coverage question to ask.
  out=$(PATH="$fb:$PATH" FM_TEST_HERDR_COVERAGE=none FM_TEST_HERDR_PROCESS_INFO="$cortex_pane" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_agent_state fmtest:w1:p1' "$ROOT" 2>/dev/null)
  [ "$out" = dead ] \
    || fail "a harness-less caller must not be changed by a coverage read, got '$out'"
  pass "backends/herdr.sh: the three coverage outcomes stay distinct, and only a proven-uncovered harness reaches the process fallback"
}

test_herdr_blind_pane_is_attributed_by_its_process() {
  local fb out
  command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; return 0; }
  mkdir -p "$TMP_ROOT/herdr-process"
  fb=$(make_herdr_agentless_fakebin "$TMP_ROOT/herdr-process")

  # On the blind path the registry read is not the last word: refusing every verb
  # for an unattributable worker leaves lifecycle control unavailable rather than
  # merely honest. The pane's foreground process is the source that can attribute
  # it, and only its two POSITIVE verdicts may be trusted.
  herdr_process_eval() {  # <process-state> <harness> [idle-shell-proof=yes|no]
    PATH="$fb:$PATH" bash -c '
      . "$0/bin/backends/herdr.sh"
      fm_backend_herdr_pane_process_state() { printf "%s" "'"$1"'"; }
      fm_backend_herdr_pane_idle_shell_sample() { [ "'"${3:-yes}"'" = yes ] && printf "4242\n"; }
      fm_backend_herdr_agent_state fmtest:w1:p1 "'"$2"'"' "$ROOT"
  }
  out=$(herdr_process_eval agent cortex)
  [ "$out" = alive ] \
    || fail "a cortex pane running a verified harness process must read alive, got '$out'"
  out=$(herdr_process_eval shell cortex yes)
  [ "$out" = dead ] \
    || fail "a cortex pane proven to hold only an idle shell is positively agent-free, got '$out'"
  # The agent-free verdict is the one that licenses closing the tab and clears
  # the relaunch gate, so a shell-looking NAME alone must never carry it: a
  # worker suspended with Ctrl+Z, or still inside its launch line, presents
  # exactly one foreground shell. Without the childless-idle-shell proof the
  # pane must stay unreadable.
  out=$(herdr_process_eval shell cortex no)
  [ "$out" = unreadable ] \
    || fail "a shell-named cortex pane that fails the idle-shell proof must not read agent-free, got '$out'"
  out=$(herdr_process_eval other cortex)
  [ "$out" = unreadable ] \
    || fail "an unattributable cortex pane must stay unreadable so no verb fires, got '$out'"
  out=$(herdr_process_eval '' cortex)
  [ "$out" = unreadable ] \
    || fail "an unreadable process read must stay unreadable, got '$out'"

  # The agent-free proof has to be CHEAP, because this read is polled:
  # bin/fm-control.sh's wait_agent_state runs it every FM_CONTROL_POLL for the
  # whole exit wait, and bin/fm-watch.sh runs it unattended per sweep. Taking
  # the retrying idle-shell wrapper here spends up to
  # FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS process-info calls with sleeps
  # between them for a pane that never settles - a worker suspended with Ctrl+Z
  # holds exactly that shape indefinitely. Count the herdr invocations one state
  # read actually costs: the answer must stay bounded, not scale with the retry
  # budget.
  local log shell_pane calls
  log="$TMP_ROOT/herdr-process/cost.log"
  : > "$log"
  # A lone foreground shell whose pid is not in the OS process table, so the
  # childless-idle-shell proof fails every sample - the never-settles case.
  shell_pane='{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p1","shell_pid":4194303,"foreground_process_group_id":4194303,"foreground_processes":[{"pid":4194303,"name":"bash","argv0":"-bash"}]}}}'
  out=$(PATH="$fb:$PATH" FM_TEST_HERDR_LOG="$log" FM_TEST_HERDR_PROCESS_INFO="$shell_pane" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_agent_state fmtest:w1:p1 cortex' "$ROOT" 2>/dev/null)
  [ "$out" = unreadable ] \
    || fail "a shell that cannot pass the idle proof must stay unreadable, got '$out'"
  calls=$(grep -c 'pane process-info' "$log" || true)
  [ "$calls" -le 2 ] \
    || fail "one polled state read must cost a bounded number of process-info calls, got $calls"

  # Divergence: the fallback must NOT reach a covered harness, whose registry
  # answer is authoritative, nor a caller that named no harness.
  out=$(herdr_process_eval agent claude)
  [ "$out" = dead ] \
    || fail "a covered harness must keep herdr's own registry verdict, got '$out'"
  out=$(herdr_process_eval agent '')
  [ "$out" = dead ] \
    || fail "a harness-less caller must keep the harness-blind verdict, got '$out'"
  pass "backends/herdr.sh: a blind pane is attributed by its foreground process, and only positively"
}

# fold_records: run the shared fold over `<name>|<argv0>` pairs, one per
# argument, so a case reads as a process GROUP rather than as two lists.
fold_records() {  # <name>|<argv0> ...
  local records='' pair
  for pair in "$@"; do
    records="${records}${pair%%|*}"$'\t'"${pair#*|}"$'\n'
  done
  bash -c '. "$0/bin/fm-harness-process-lib.sh"
    fm_harness_process_state_from_records "$1"' "$ROOT" "$records"
}

test_harness_process_group_folds_to_the_safe_verdict() {
  local out
  # The shared fold is what turns a whole foreground process group into one
  # verdict. `agent` must win, because a harness that shells out keeps the harness
  # in the same group; `shell` requires EVERY readable entry to be a shell, so a
  # group holding a stranger stays `other` and its callers refuse. A wrong `agent`
  # costs a refused verb; a wrong `shell` licenses closing over a live worker.
  out=$(fold_records 'bash|' 'cortex|')
  [ "$out" = agent ] || fail "a harness anywhere in the group must win, got '$out'"
  out=$(fold_records 'bash|')
  [ "$out" = shell ] || fail "a lone idle shell must read shell, got '$out'"
  out=$(fold_records 'bash|' 'some-stranger|')
  [ "$out" = other ] || fail "a shell beside an unattributable stranger must read other, got '$out'"
  out=$(fold_records)
  [ "$out" = other ] || fail "no readable name is not a shell, got '$out'"
  # The vocabulary itself is still the tmux adapter's, so the two cannot drift.
  out=$(fold_records 'cortexd|')
  [ "$out" = other ] || fail "cortexd must not claim the harness identity, got '$out'"

  # Each process carries its OWN argv0. A process reporting a name but no argv0
  # must not shift a later process's argv0 onto itself: that pairs a name with a
  # stranger's argv0 and misclassifies in both directions - here it would make an
  # ordinary `git` inherit a claude install path and read as a live agent.
  out=$(fold_records 'git|' 'bash|/opt/claude/bin/bash')
  [ "$out" = other ] \
    || fail "a process with no argv0 must not inherit a later process's argv0, got '$out'"
  # And the other direction: the process that OWNS the harness argv0 must keep it.
  out=$(fold_records 'git|' 'node|/opt/claude/bin/node')
  [ "$out" = agent ] \
    || fail "a process must be classified against its own argv0, got '$out'"
  pass "fm-harness-process-lib.sh: a process group folds toward refusal, never toward agent-free"
}

# The real `pane process-info` response is the input the fallback actually
# parses, so these cases drive it end to end through the adapter rather than
# stubbing the parse away. FM_TEST_HERDR_PROCESS_INFO is the canned body.
test_herdr_process_info_is_parsed_per_process() {
  local fb out
  command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; return 0; }
  mkdir -p "$TMP_ROOT/herdr-procinfo"
  fb=$(make_herdr_agentless_fakebin "$TMP_ROOT/herdr-procinfo")

  process_state() {  # <foreground_processes JSON array>
    PATH="$fb:$PATH" FM_TEST_HERDR_PROCESS_INFO="{\"result\":{\"type\":\"pane_process_info\",\"process_info\":{\"pane_id\":\"w1:p1\",\"foreground_processes\":$1}}}" \
      bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_pane_process_state fmtest w1:p1' "$ROOT"
  }

  # The shape verified live on herdr 0.8.2 against a real Cortex Code worker.
  out=$(process_state '[{"pid":4983,"name":"cortex","argv0":"cortex"}]')
  [ "$out" = agent ] || fail "a live cortex foreground process must attribute the pane, got '$out'"
  out=$(process_state '[{"pid":3073,"name":"bash","argv0":"-bash"}]')
  [ "$out" = shell ] || fail "a lone foreground shell must read shell, got '$out'"

  # A process that reports a name but no argv0 must not shift the NEXT process's
  # argv0 onto itself. Parsed as two independent lists, `git` would inherit the
  # claude install path below and the pane would read as a live agent.
  out=$(process_state '[{"pid":1,"name":"git"},{"pid":2,"name":"bash","argv0":"/opt/claude/bin/bash"}]')
  [ "$out" = other ] \
    || fail "an argv0-less process must not inherit its neighbour's argv0, got '$out'"

  # Gemini is the one uncovered harness no process NAME can attribute: the CLI is
  # a node bundle, so a live worker reports MainThread and the interpreter path
  # and only the script argument carries the identity.
  out=$(process_state '[{"pid":11,"name":"MainThread","argv0":"/home/u/.local/node/bin/node","argv":["/home/u/.local/node/bin/node","/home/u/.local/bin/gemini","-y"]}]')
  [ "$out" = agent ] || fail "a live gemini node bundle must attribute the pane, got '$out'"
  # And the same interpreter without Gemini's script argument must NOT: a bare
  # node is a stranger, and claiming it would be the widening this rule exists
  # to prevent.
  out=$(process_state '[{"pid":12,"name":"MainThread","argv0":"/home/u/.local/node/bin/node","argv":["/home/u/.local/node/bin/node","/home/u/src/server.js"]}]')
  [ "$out" = other ] || fail "a bare node interpreter must stay unattributed, got '$out'"

  # herdr hands over argv as an ARRAY, and it must be consumed as one. Joining
  # it into a command line first cannot be split back apart when the script path
  # contains a space, so a live worker installed under such a path would go
  # unattributed and every lifecycle verb would refuse it.
  out=$(process_state '[{"pid":13,"name":"MainThread","argv0":"/usr/bin/node","argv":["/usr/bin/node","/Users/a b/.local/bin/gemini","-y"],"cmdline":"/usr/bin/node /Users/a b/.local/bin/gemini -y"}]')
  [ "$out" = agent ] \
    || fail "a gemini script path containing a space must still attribute, got '$out'"
  # The array is authoritative over any flattened rendering beside it: a cmdline
  # that reads like gemini cannot attribute a process whose argv is not.
  out=$(process_state '[{"pid":14,"name":"MainThread","argv0":"/usr/bin/node","argv":["/usr/bin/node","/home/u/src/server.js"],"cmdline":"/usr/bin/node /home/u/.local/bin/gemini -y"}]')
  [ "$out" = other ] \
    || fail "a flattened cmdline must not outrank the argv array, got '$out'"

  # A body that is not this pane's process info is no evidence at all.
  out=$(PATH="$fb:$PATH" FM_TEST_HERDR_PROCESS_INFO='{"result":{"type":"pane_process_info","process_info":{"pane_id":"w9:p9","foreground_processes":[{"name":"bash"}]}}}' \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_pane_process_state fmtest w1:p1 || printf refused' "$ROOT")
  [ "$out" = refused ] || fail "a response for another pane must carry no verdict, got '$out'"
  pass "backends/herdr.sh: pane process-info is attributed per process, including gemini's argv-only identity"
}

test_cortex_herdr_exit_refuses_instead_of_claiming_already_stopped() {
  local fb dir home proj wt id=cx-herdr out status harness
  command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; return 0; }
  dir="$TMP_ROOT/herdr-exit"
  home="$dir/home"
  proj="$dir/project"
  wt="$dir/wt"
  mkdir -p "$dir"
  fb=$(make_herdr_agentless_fakebin "$dir")
  fm_test_spawn_home "$home" cortex
  fm_git_worktree "$proj" "$wt" "wt-herdr-exit"

  write_herdr_meta() {  # <harness>
    {
      echo "window=fmtest:w1:p1"
      echo "endpoint_task_id=$id"
      echo "worktree=$wt"
      echo "project=$proj"
      echo "harness=$1"
      echo "kind=ship"
      echo "mode=no-mistakes"
      echo "yolo=off"
      echo "backend=herdr"
      echo "herdr_session=fmtest"
      echo "herdr_workspace_id=w1"
      echo "herdr_tab_id=w1:t1"
      echo "herdr_pane_id=w1:p1"
    } > "$home/state/$id.meta"
  }

  # The whole consumer path: the recorded harness decides whether the Herdr read
  # is trusted as proof that the worker already stopped.
  for harness in cortex claude; do
    write_herdr_meta "$harness"
    out=$(PATH="$fb:$PATH" FM_HOME="$home" FM_CONTROL_POLL=0.1 FM_CONTROL_EXIT_WAIT=1 \
      "$ROOT/bin/fm-control.sh" "$id" exit 2>&1)
    status=$?
    if [ "$harness" = cortex ]; then
      expect_code 1 "$status" "exit must refuse for a cortex task herdr cannot read: $out"
      case "$out" in
        *already-stopped*) fail "exit must never report already-stopped for a cortex worker herdr cannot see: $out" ;;
      esac
      assert_contains "$out" "unreadable" "the refusal must name the unattributed endpoint reading"
    else
      expect_code 0 "$status" "exit must still be idempotent success for an agent-free claude task: $out"
      assert_contains "$out" "already-stopped" "an agent-free claude endpoint must still report already-stopped"
    fi
  done
  pass "fm-control.sh: exit refuses a cortex herdr task instead of reporting a false already-stopped"

  # The relaunch guard is the same read with the worse consequence: passing it
  # starts a SECOND agent in the pane and worktree the first one is still in.
  # Only a threaded harness can produce this refusal - untied, the read is
  # `dead`, the guard passes silently, and there is no error to assert at all.
  write_herdr_meta cortex
  out=$(PATH="$fb:$PATH" FM_HOME="$home" "$ROOT/bin/fm-spawn.sh" --relaunch "$id" 2>&1)
  status=$?
  expect_code 1 "$status" "a cortex relaunch must refuse on an endpoint herdr cannot read: $out"
  assert_contains "$out" "positively agent-free endpoint" \
    "the relaunch refusal must be the agent-free guard"
  assert_contains "$out" "unreadable" \
    "the relaunch guard must refuse on the unreadable cortex reading, not pass on a false dead"
  pass "fm-spawn.sh: --relaunch refuses a cortex herdr endpoint rather than adding a second agent"

  # A coverage read that fails entirely is the degraded state the adapter is
  # built to tolerate, and the adapter answers it SILENTLY because it sits under
  # a predicate every verb polls. Silence there is only acceptable while the
  # commands a human actually runs still say the endpoint could not be
  # attributed - so assert it at the surface a human reads, not at the
  # predicate. This would fail if a caller went quiet about the condition.
  write_herdr_meta cortex
  out=$(PATH="$fb:$PATH" FM_HOME="$home" FM_TEST_HERDR_COVERAGE=none \
    FM_CONTROL_POLL=0.1 FM_CONTROL_EXIT_WAIT=1 \
    "$ROOT/bin/fm-control.sh" "$id" exit 2>&1)
  status=$?
  expect_code 1 "$status" "exit must refuse when herdr's coverage cannot be read: $out"
  assert_contains "$out" "unreadable" \
    "exit must tell the operator the endpoint could not be attributed"
  out=$(PATH="$fb:$PATH" FM_HOME="$home" FM_TEST_HERDR_COVERAGE=none \
    "$ROOT/bin/fm-spawn.sh" --relaunch "$id" 2>&1)
  status=$?
  expect_code 1 "$status" "relaunch must refuse when herdr's coverage cannot be read: $out"
  assert_contains "$out" "unreadable" \
    "relaunch must tell the operator the endpoint could not be attributed"
  # And the same for a harness herdr DOES integrate with: an unreadable coverage
  # read means nobody knows whether the registry answer is proof, so a claude
  # task must refuse here too rather than act on it.
  write_herdr_meta claude
  out=$(PATH="$fb:$PATH" FM_HOME="$home" FM_TEST_HERDR_COVERAGE=none \
    FM_CONTROL_POLL=0.1 FM_CONTROL_EXIT_WAIT=1 \
    "$ROOT/bin/fm-control.sh" "$id" exit 2>&1)
  status=$?
  expect_code 1 "$status" "exit must refuse for a covered harness when coverage is unreadable: $out"
  assert_contains "$out" "unreadable" \
    "a covered harness must also learn its endpoint could not be attributed"
  pass "fm-control.sh/fm-spawn.sh: an unreadable herdr coverage read reaches the operator as an unattributed endpoint"
}

# The steering doorbell is the FOURTH consumer of the same blind Herdr read,
# and the only one whose failure is silent: the lifecycle guards all refuse out
# loud, while an unthreaded ring simply never types and reports the worker
# "exited". Both the defect and its fix were observed against a real Herdr
# server with a live cortex worker; docs/verification/cortex.md under "Backend
# liveness: Herdr" records that evidence. Before the fix a live cortex worker
# read `dead`, fm_task_inbox_ring returned 3, the doorbell was never typed, and
# the watcher escalated the worker as unavailable instead of re-ringing it -
# leaving a cortex worker on Herdr startable but permanently unsteerable.
test_cortex_herdr_steering_rings_instead_of_reporting_a_dead_pane() {
  local fb dir state rec log rc
  command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; return 0; }
  dir="$TMP_ROOT/herdr-steer"
  state="$dir/state"
  mkdir -p "$state"
  fb=$(make_herdr_agentless_fakebin "$dir")
  rec=$(inbox_lib "$state" fm_task_inbox_write "$state" ctx1 "please continue")

  # cortex: herdr cannot see the agent, so the read proves nothing and the
  # doorbell must still be typed rather than skipped as a positively dead pane.
  log="$dir/cortex.log"; : > "$log"
  rc=0
  PATH="$fb:$PATH" FM_TEST_HERDR_LOG="$log" \
    inbox_lib "$state" fm_task_inbox_ring herdr fmtest:w1:p1 "$rec" fm-ctx1 cortex || rc=$?
  [ "$rc" != 3 ] \
    || fail "a live cortex worker herdr cannot see must not be skipped as a dead pane (rc=$rc)"
  grep -qF 'pane send-text' "$log" \
    || fail "the cortex doorbell was never typed:"$'\n'"$(cat "$log")"
  grep -qF 'Firstmate instruction waiting' "$log" \
    || fail "the cortex doorbell carried no instruction pointer:"$'\n'"$(cat "$log")"

  # claude: herdr DOES integrate with it, so agent_not_found is real evidence of
  # an agent-free pane and the existing skip must survive this change untouched.
  log="$dir/claude.log"; : > "$log"
  rc=0
  PATH="$fb:$PATH" FM_TEST_HERDR_LOG="$log" \
    inbox_lib "$state" fm_task_inbox_ring herdr fmtest:w1:p1 "$rec" fm-cla1 claude || rc=$?
  [ "$rc" = 3 ] || fail "an agent-free claude pane must still skip the ring with 3, got $rc"
  if grep -qF 'pane send-text' "$log"; then
    fail "an agent-free claude pane was typed into:"$'\n'"$(cat "$log")"
  fi

  # A caller that names no harness keeps today's harness-blind verdict exactly,
  # so this argument only ever adds knowledge and never changes an old caller.
  log="$dir/blind.log"; : > "$log"
  rc=0
  PATH="$fb:$PATH" FM_TEST_HERDR_LOG="$log" \
    inbox_lib "$state" fm_task_inbox_ring herdr fmtest:w1:p1 "$rec" fm-x1 || rc=$?
  [ "$rc" = 3 ] || fail "a harness-less ring must keep the existing skip, got $rc"

  [ -f "$rec" ] || fail "ringing must leave the durable record in place for acknowledgement"
  pass "fm-task-inbox-lib.sh: the doorbell rings a cortex herdr worker instead of calling it dead"
}

# The same argument on the three-state compatibility view. `dead` is the one
# value this view licenses action on, so collapsing a live cortex worker onto it
# is what made the watcher's paused-classification gates and fm-spawn's
# duplicate-launch guard read a running worker as gone.
test_cortex_herdr_agent_alive_is_not_dead_for_a_live_worker() {
  local fb out
  command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; return 0; }
  mkdir -p "$TMP_ROOT/herdr-alive"
  fb=$(make_herdr_agentless_fakebin "$TMP_ROOT/herdr-alive")
  alive_eval() { PATH="$fb:$PATH" bash -c ". \"\$0/bin/fm-backend.sh\"; $1" "$ROOT"; }

  out=$(alive_eval 'fm_backend_agent_alive herdr fmtest:w1:p1 cortex')
  [ "$out" = unknown ] \
    || fail "a cortex worker herdr cannot see must not read dead, got '$out'"
  out=$(alive_eval 'fm_backend_agent_alive herdr fmtest:w1:p1 claude')
  [ "$out" = dead ] || fail "an agent-free claude endpoint must still read dead, got '$out'"
  out=$(alive_eval 'fm_backend_agent_alive herdr fmtest:w1:p1')
  [ "$out" = dead ] || fail "a harness-less caller must keep the existing verdict, got '$out'"
  pass "fm-backend.sh: fm_backend_agent_alive forwards the harness that makes the read honest"
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
  # --no-auto-update was removed deliberately (docs/verification/cortex.md):
  # it cannot stop a mid-session swap, and its only durable effect is workers
  # permanently declining upstream fixes. Pinned so it cannot drift back in.
  case "$launch" in
    *--no-auto-update*) fail "cortex launch must not pass --no-auto-update" ;;
  esac
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

test_cortex_effort_caps_xhigh_and_refuses_minimal() {
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

  # minimal is cortex's own sub-low level. It sits below firstmate's shared
  # effort vocabulary, so it never reaches the cortex adapter arm at all -
  # fm-spawn refuses it up front, before any endpoint, metadata, or typed launch
  # exists. That refusal is what makes "deliberately unreachable" true, so it is
  # what this pins: a dropped-but-accepted minimal would be the silent failure
  # this adapter exists to eliminate.
  rec=$(make_cortex_case effort-minimal cx-eff-3)
  read_cortex_case "$rec"
  launch_log="$CASE_DIR/launch.log"
  : > "$launch_log"
  out=$(FM_FAKE_LAUNCH_LOG="$launch_log" run_cortex_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
        cx-eff-3 "$PROJ_DIR" --effort minimal 2>&1)
  expect_code 1 $? "cortex spawn with minimal must be refused: $out"
  assert_contains "$out" '--effort must be one of low, medium, high, xhigh, max, ultra' \
    "the refusal must name the shared effort vocabulary"
  assert_absent "$HOME_DIR/state/cx-eff-3.meta" "a refused effort must leave no task metadata"
  [ ! -s "$launch_log" ] || fail "a refused effort must not type a launch command"
  pass "fm-spawn.sh: cortex caps xhigh onto high, passes supported levels, and refuses minimal"
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
test_cortex_pane_process_classifies_as_a_live_agent
test_cortex_herdr_agent_read_is_not_agent_free_proof
test_herdr_coverage_is_derived_not_pinned
test_herdr_blind_pane_is_attributed_by_its_process
test_harness_process_group_folds_to_the_safe_verdict
test_herdr_process_info_is_parsed_per_process
test_cortex_herdr_exit_refuses_instead_of_claiming_already_stopped
test_cortex_herdr_steering_rings_instead_of_reporting_a_dead_pane
test_cortex_herdr_agent_alive_is_not_dead_for_a_live_worker
test_cortex_control_mechanics_are_the_verified_ones
test_cortex_and_codex_families_do_not_swallow_each_other
test_cortex_is_crewmate_and_scout_only
test_cortex_wiring_is_the_worktree_local_settings_file
test_cortex_trusts_only_its_own_semantic_source
test_cortex_launch_carries_the_brief_positionally
test_cortex_spawn_writes_worktree_hooks_and_excludes_them
test_cortex_hooks_drive_the_semantic_busy_lifecycle
test_cortex_stale_incarnation_hook_is_harmless
test_cortex_effort_caps_xhigh_and_refuses_minimal
test_cortex_secondmate_launch_is_refused
test_cortex_spawn_refuses_a_missing_executable
