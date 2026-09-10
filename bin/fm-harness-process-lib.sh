#!/usr/bin/env bash
# Harness process-name classification, shared by every session-provider adapter
# that can read a pane's foreground process.
# Sourced by bin/backends/tmux.sh and bin/backends/herdr.sh. This file is
# sourced by scripts and has no side effects on source.
#
# Why one owner: two backends now answer "is a verified harness agent running in
# this pane?" from a process name, and tmux reached that question first. A second
# copy of the name vocabulary in the Herdr adapter would drift the moment either
# is edited - a harness added to one and not the other silently classifies a live
# worker as an agent-free pane on that backend alone, which is the exact class of
# defect this vocabulary exists to prevent. The classifier therefore lives here,
# and each adapter keeps only a thin named wrapper.
#
# fm_harness_path_name comes from bin/fm-session-lock-lib.sh, which in turn owns
# the delegation to bin/fm-cursor-lib.sh for Cursor's non-name-expressible
# identity. Both are documented side-effect-free on source, so an adapter that
# already sources them is unaffected by sourcing them again here.
# shellcheck source=bin/fm-session-lock-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-session-lock-lib.sh"

# fm_harness_process_state_from_records: fold a whole foreground process group
# into one verdict, given one `<name><TAB><argv0>` record per process, newline
# separated. Either field may be empty. Prints agent|shell|other.
#
# One record per process, never two parallel lists: a process that reports a
# name but no argv0 would shift every later argv0 onto the wrong process, so a
# name would be classified against a stranger's argv0 - silently, and in both
# directions (a bystander inheriting a harness argv0 reads `agent`, and the real
# harness stripped of its own argv0 reads `other`).
#
# `agent` wins over everything: a harness that shells out to a child keeps the
# harness in the same foreground group, so any entry naming a verified harness
# means an agent is running there. `shell` requires every readable entry to be a
# shell, so a group holding one shell plus one unattributable stranger reports
# `other` and the callers refuse rather than treating it as agent-free. That
# asymmetry is deliberate: a wrong `agent` costs a refused verb, while a wrong
# `shell` licenses closing or relaunching over a live worker.
fm_harness_process_state_from_records() {  # <records> -> agent|shell|other
  local records=${1-} record name argv0 state saw_shell=0 saw_other=0
  while IFS= read -r record; do
    name=${record%%$'\t'*}
    if [ "$name" = "$record" ]; then
      argv0=
    else
      argv0=${record#*$'\t'}
    fi
    [ -n "$name" ] || [ -n "$argv0" ] || continue
    state=$(fm_harness_classify_process_name "$name" "$argv0")
    case "$state" in
      agent) printf 'agent'; return 0 ;;
      shell) saw_shell=1 ;;
      *) saw_other=1 ;;
    esac
  done <<< "$records"
  if [ "$saw_other" -eq 0 ] && [ "$saw_shell" -eq 1 ]; then
    printf 'shell'
  else
    printf 'other'
  fi
}

# fm_harness_classify_process_name: the single owner of the process-name
# vocabulary shared by every liveness signal - `agent` for a verified harness,
# `shell` for an idle login/interactive shell, `other` for anything else.
# Keeping one classifier means independent name sources can never drift into
# disagreeing about what a given name means.
fm_harness_classify_process_name() {  # <path> [argv0] -> agent|shell|other
  local path=$1 argv0=${2:-} base
  base=${path##*/}
  base=${base#-}
  case "$base" in
    # muse is anchored rather than globbed like its neighbours: its installed
    # binary is muse-bin-<version> (the launcher execs it, so the version is the
    # live process name and changes on every auto-update), and unlike `claude` or
    # `codex` the substring `muse` is a common English fragment - a *muse* glob
    # would classify musescore or amuse as a live agent pane. The install path
    # cannot carry it either: ~/.local/bin/muse-bin-<version> has no `muse` path
    # COMPONENT, so the fm_harness_path_name fallback below never fires for it.
    muse|muse-bin-*) printf 'agent' ;;
    # omp (Oh My Pi) is anchored for the same reason as muse: its live process
    # name is the bare word `omp` (verified, omp 18.1.11) and a glob would claim
    # unrelated commands such as ompd or comp.
    #
    # cortex needs its own arm because the neighbouring `*codex*` glob does NOT
    # cover it - the two names differ by one letter - and it is anchored because
    # its live process name is the bare word `cortex` (verified, Cortex Code
    # v1.1.84, which reports comm=cortex) while a *cortex* glob would claim
    # cortexd or cortex-helper. Without the arm a live cortex pane classifies
    # `other`, the composed verdict is `ambiguous`, and every fm-control verb
    # refuses the worker it can no longer see.
    *claude*|*codex*|*opencode*|*grok*|*kimi*|*rovo*|pi|pi-signed|pi-launcher|Pi|omp|cortex) printf 'agent' ;;
    zsh|bash|sh|dash|ash|ksh|mksh|tcsh|csh|fish) printf 'shell' ;;
    *)
      if fm_harness_path_name "$path" >/dev/null || fm_harness_path_name "$argv0" >/dev/null; then
        printf 'agent'
      # cursor-agent runs as a bundled node script, so tmux reports the pane
      # command as a bare `node` that no name pattern above can own, and its
      # other installed name is the far-too-generic `agent` (verified live on
      # cursor-agent 2026.08.11-e8db854: #{pane_current_command} is `node` while
      # `ps -o comm=` carries the cursor-agent install path). Identity therefore
      # comes from the narrowed structural rule in bin/fm-cursor-lib.sh, which
      # demands Cursor's own name or install tree in the path or argv[0]. An
      # unrelated `node` or `agent` matches nothing here and stays `other`,
      # which the callers fold into `ambiguous` rather than `dead`, so a
      # stranger's node pane is never reported as an agent-free pane.
      elif fm_cursor_process_matches "${path:-$argv0}" '' "$argv0"; then
        printf 'agent'
      else
        printf 'other'
      fi
      ;;
  esac
}
