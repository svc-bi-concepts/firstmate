#!/usr/bin/env bash
# Opt-in live guard: the agent lifecycle verbs against a REAL Cortex Code worker
# on a REAL Herdr server.
#
# Why this cannot be a fixture. Herdr's installed build ships no cortex
# integration, so `agent get` answers agent_not_found for a live cortex worker
# exactly as it does for an empty pane. Two separate things follow, and only a
# real worker can prove either:
#
#   1. The registry read must not be believed. That half is pinned hermetically
#      in tests/fm-cortex-harness.test.sh and against the real binary's coverage
#      report in tests/fm-herdr-integration-coverage-live-e2e.test.sh.
#   2. Lifecycle control must still WORK. Honesty alone leaves every verb
#      refusing a worker nobody can attribute, which is a different failure with
#      the same cause. The adapter therefore attributes the pane from its
#      foreground process (`pane process-info`), and THAT is what this guard
#      exercises end to end: liveness, interrupt, exit, and the relaunch gate.
#
# A fake cannot establish it because the whole question is what a real Cortex
# Code process looks like to Herdr, and a stub can only echo the assumption
# already written into the stub.
#
# This guard submits a real prompt to a real model, so the shared live gate keeps
# it opt-in. Run it after a Cortex Code or Herdr upgrade and before trusting a
# refreshed docs/verification/cortex.md lifecycle claim.
#
# HERDR ISOLATION. Every Herdr call here goes through bin/fm-herdr-lab.sh against
# a generated non-default `fm-lab-` session: the helper appends the required
# trailing --session, owns provisioning, records the live default session as a
# fleet-state tripwire, and is the only path to stop or delete. No lifecycle verb
# in this file is ever aimed at the captain's default session or at any live
# fleet worker - the worker it drives is one this guard launched itself.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

fm_live_gate opt-in FM_CORTEX_HERDR_LIFECYCLE_LIVE_E2E herdr jq cortex git

[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }

# This suite runs against its own isolated lab session, so a Herdr pane inherited
# from the terminal it was launched in must not follow a spawn into it as a
# cross-session parent identity (tests/herdr-test-safety.sh).
# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name cortex-lifecycle) \
  || fail "could not generate an isolated lab session name"
SCRATCH=

cleanup_all() {
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || true
  [ -z "$SCRATCH" ] || rm -rf "$SCRATCH"
}
trap cleanup_all EXIT

"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" \
  || fail "could not provision the isolated Herdr lab session"

lab_run() { "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-cortex-herdr-lifecycle.XXXXXX")
SCRATCH=$(cd "$SCRATCH" && pwd -P)
HOME_DIR="$SCRATCH/home"
PROJ="$SCRATCH/proj"
WT="$SCRATCH/wt"
ID=cxlife
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/$ID" "$PROJ"

git -C "$PROJ" init -q
printf '# proj\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
  commit -qm initial
git -C "$PROJ" worktree add --quiet -b "$ID" "$WT"

# A trivial brief: this guard measures lifecycle control, not model output, so the
# worker only has to be genuinely running and genuinely reachable.
printf 'Reply with exactly READY and then wait. Do not edit any file.\n' \
  > "$HOME_DIR/data/$ID/brief.md"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"
export HERDR_SESSION="$HERDR_LAB_SESSION"

fm_backend_herdr_version_check || fail "version_check failed against the real installed herdr"

CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$WT") || fail "container_ensure failed"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}
WORKSPACE_ID=${CONTAINER#*:}
TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-$ID" "$WT" "$SEEDED_TAB_ID" cortex) \
  || fail "create_task failed"
read -r TAB_ID PANE_ID <<EOF
$TASK_IDS
EOF
[ -n "$TAB_ID" ] && [ -n "$PANE_ID" ] || fail "create_task did not return tab/pane ids"
TARGET="$HERDR_LAB_SESSION:$PANE_ID"

{
  echo "window=$TARGET"
  echo "endpoint_task_id=$ID"
  echo "worktree=$WT"
  echo "project=$PROJ"
  echo "harness=cortex"
  echo "kind=ship"
  echo "mode=no-mistakes"
  echo "yolo=off"
  echo "model=default"
  echo "effort=default"
  echo "backend=herdr"
  echo "herdr_session=$HERDR_LAB_SESSION"
  echo "herdr_workspace_id=$WORKSPACE_ID"
  echo "herdr_tab_id=$TAB_ID"
  echo "herdr_pane_id=$PANE_ID"
} > "$HOME_DIR/state/$ID.meta"

run_control() {
  env FM_HOME="$HOME_DIR" HERDR_SESSION="$HERDR_LAB_SESSION" \
    FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT="${CONTROL_EXIT_WAIT:-90}" \
    "$ROOT/bin/fm-control.sh" "$@" 2>&1
}

# settle_to_composer: wait until the worker is back at an empty composer, so a
# lifecycle verb is measured against a ready worker rather than one still mid-turn.
# A harness that is busy legitimately defers its own quit command, which would
# otherwise be indistinguishable from a quit that does not work.
settle_to_composer() {  # <seconds>
  local deadline=$(( $(date +%s) + ${1:-60} )) state
  while [ "$(date +%s)" -lt "$deadline" ]; do
    state=$(fm_backend_herdr_composer_state "$TARGET" cortex 2>/dev/null) || state=
    [ "$state" = empty ] && return 0
    sleep 1
  done
  return 1
}

# --- before the worker exists: the pane holds a bare shell ------------------
# This is the divergence that keeps every later assertion from being vacuous. The
# SAME pane, same session, same recorded harness, differing only in whether a
# cortex process is running, must classify differently. Without this a guard that
# always answered `alive` would pass.
#
# Polled rather than asserted once: a freshly created pane's foreground group is
# briefly unreadable, which the adapter correctly reports as `unknown` (refuse)
# rather than guessing. That transient is expected, not the property under test.
BEFORE=
DEADLINE=$(( $(date +%s) + 30 ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  BEFORE=$(fm_backend_agent_state herdr "$TARGET" cortex)
  [ "$BEFORE" = dead ] && break
  sleep 1
done
[ "$BEFORE" = dead ] \
  || fail "an empty lab pane must settle to positively agent-free, got '$BEFORE'"
pass "real herdr: an empty pane recorded as cortex reads agent-free from its shell process"

# --- launch a real cortex worker --------------------------------------------
CORTEX_BIN=$(command -v cortex) || fail "cortex not found on PATH"
LAUNCH="cd $(printf '%q' "$WT") && env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS $(printf '%q' "$CORTEX_BIN") --bypass --auto-accept-plans $(printf '%q' "$(cat "$HOME_DIR/data/$ID/brief.md")")"
fm_backend_herdr_send_text_submit "$TARGET" "$LAUNCH" 3 0.4 0.8 cortex >/dev/null 2>&1 || true

# Wait for the real process to own the pane's foreground group.
DEADLINE=$(( $(date +%s) + 120 ))
PROCESS_STATE=
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  PROCESS_STATE=$(fm_backend_herdr_pane_process_state "$HERDR_LAB_SESSION" "$PANE_ID" 2>/dev/null) || PROCESS_STATE=
  [ "$PROCESS_STATE" = agent ] && break
  sleep 1
done
[ "$PROCESS_STATE" = agent ] \
  || fail "a real cortex worker never took over the lab pane's foreground group (got '${PROCESS_STATE:-unreadable}')"
pass "real herdr + real cortex: the pane's foreground process attributes the worker"

# --- 1. liveness reads correctly -------------------------------------------
# herdr's own registry still cannot see this worker; that is the premise, and it
# is asserted rather than assumed so the fallback cannot be silently untested.
AGENT_GET=$(lab_run agent get "$PANE_ID" 2>&1 || true)
case "$AGENT_GET" in
  *agent_not_found*) : ;;
  *) fail "herdr unexpectedly registered the cortex agent; this guard's premise no longer holds: $AGENT_GET" ;;
esac
STATE=$(fm_backend_agent_state herdr "$TARGET" cortex)
[ "$STATE" = alive ] \
  || fail "a live cortex worker must classify alive, got '$STATE'"
[ "$(fm_backend_agent_alive herdr "$TARGET" cortex)" = alive ] \
  || fail "the three-state view must agree that a live cortex worker is alive"
pass "real herdr: a live cortex worker reads alive even though agent get cannot see it"

# --- 2. interrupt works ----------------------------------------------------
settle_to_composer 90 || true
OUT=$(run_control "$ID" interrupt) \
  || fail "interrupt against a live cortex worker must succeed: $OUT"
case "$OUT" in
  *interrupt-delivered*) : ;;
  *) fail "interrupt must report delivery for a live cortex worker, got: $OUT" ;;
esac
lab_run pane get "$PANE_ID" >/dev/null 2>&1 \
  || fail "interrupt must never remove the endpoint it operated on"
[ -d "$WT" ] || fail "interrupt must never remove the task's local copy"
pass "real herdr: interrupt delivers to a live cortex worker and leaves the endpoint intact"

# --- 3. exit works ---------------------------------------------------------
settle_to_composer 90 || true
OUT=$(run_control "$ID" exit) || {
  printf 'pane tail after the exit attempt:\n%s\n' \
    "$(fm_backend_herdr_capture "$TARGET" 25 2>/dev/null | tail -20)" >&2
  fail "exit against a live cortex worker must succeed: $OUT"
}
case "$OUT" in
  *stopped*) : ;;
  *) fail "exit must report a stop for a live cortex worker, got: $OUT" ;;
esac
[ -d "$WT" ] || fail "exit must never remove the task's local copy"

# The stop has to be real, and the endpoint has to become POSITIVELY agent-free
# again - that is the state the relaunch gate requires, and the state the old
# blind read could never reach honestly.
DEADLINE=$(( $(date +%s) + 60 ))
AFTER=
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  AFTER=$(fm_backend_agent_state herdr "$TARGET" cortex)
  [ "$AFTER" = dead ] && break
  sleep 1
done
[ "$AFTER" = dead ] \
  || fail "after exit the endpoint must read positively agent-free, got '$AFTER'"
pass "real herdr: exit actually stops the cortex worker and the pane returns to agent-free"

# --- 4. the relaunch gate now passes ---------------------------------------
# This is the highest-severity symptom's mirror image. The verifier previously
# read a LIVE worker as dead (and would have relaunched over it); it must now
# read a live worker as alive and REFUSE, and read a genuinely stopped one as
# dead and ALLOW. Both directions are asserted against the same live endpoint.
RELAUNCH_GATE=$(fm_backend_agent_state herdr "$TARGET" cortex)
[ "$RELAUNCH_GATE" = dead ] \
  || fail "the relaunch gate must accept a genuinely stopped cortex endpoint, got '$RELAUNCH_GATE'"

OUT=$(run_control "$ID" relaunch --note 'lifecycle guard: relaunch after a proven exit' 2>&1) \
  || RELAUNCH_RC=$?
if [ "${RELAUNCH_RC:-0}" -ne 0 ]; then
  case "$OUT" in
    *"positively agent-free"*)
      fail "relaunch was refused at the endpoint gate it should now pass: $OUT"
      ;;
    *)
      # A relaunch can legitimately fail further down this synthetic home (it
      # drives the full spawn path, including worktree acquisition this guard
      # does not provision). Only the endpoint gate is this guard's subject, and
      # it was proven above; report the rest rather than claiming it.
      printf 'ok - real herdr: relaunch cleared the endpoint gate; the spawn path then reported: %s\n' \
        "$(printf '%s' "$OUT" | tr -d '\r' | tr '\n' ' ' | cut -c1-160)"
      ;;
  esac
else
  pass "real herdr: relaunch succeeded end to end against the stopped cortex endpoint"
fi

# The gate is not simply always-allow: section 1 above asserts `alive` for the
# live worker, which is the reading that refuses it. All that remains here is
# that no verb in this sequence destroyed the endpoint it operated on.
lab_run pane get "$PANE_ID" >/dev/null 2>&1 \
  || fail "no control verb may remove the endpoint"
pass "real herdr: the cortex lifecycle verbs are available and the endpoint survived every one"
