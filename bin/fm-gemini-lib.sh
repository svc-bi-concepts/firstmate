#!/usr/bin/env bash
# Gemini process identity.
# Sourced by bin/backends/tmux.sh. This file is sourced by scripts and has no
# side effects on source.
#
# Why one owner: the Gemini CLI ships as a node bundle, so a live gemini pane
# presents as an interpreter and nothing about its command NAME says gemini.
# Measured on gemini-cli 0.58.0 with Node v24.20.0 on Linux, one worker's
# foreground process group read:
#
#   comm  : MainThread
#   argv0 : /home/<user>/.local/node/bin/node
#   args  : node /home/<user>/.local/bin/gemini -y
#
# `comm` is MainThread because modern Node renames its main thread, and argv[0]
# is the interpreter. Only argv[1] - the script path - carries the identity, so
# the liveness classifier has to read the arguments rather than the name. This
# is the same hazard bin/fm-cursor-lib.sh exists to close for cursor-agent, and
# the rule here is deliberately the same shape: structural only, no subprocess,
# because probing a stranger's binary during a liveness poll is exactly what
# must not happen.
#
# Detection of firstmate's OWN harness uses these structural rules for the
# ancestry fallback. The GEMINI_CLI=1 environment marker in bin/fm-harness.sh
# remains the load-bearing path for the installed bundle shape on modern Node.

# True when path $1 carries Gemini's own structural evidence: the file is named
# gemini, or it sits inside the published @google/gemini-cli package tree. A
# directory component merely named `gemini` is never enough on its own, and a
# bare interpreter is always rejected.
fm_gemini_path_is_gemini() {  # <path>
  local path=$1
  [ -n "$path" ] || return 1
  case "$path" in
    -*) return 1 ;;
  esac
  case "${path##*/}" in
    gemini) return 0 ;;
  esac
  case "$path" in
    */@google/gemini-cli/*) return 0 ;;
  esac
  return 1
}

# True when the argv FIELDS $1.. are a Gemini process. This is the single owner
# of the structural rule; every other entry point below is a feeder that turns
# its own input shape into these fields.
#
# Accepted: a command whose own argv[0] is gemini (a future natively-named
# binary), and an interpreter whose first non-flag argument is Gemini's script
# or package path. Node's own options are skipped so
# `node --max-old-space-size=10000 <script>` - the exact shape the installed
# launcher execs - still resolves.
#
# Rejected: a bare interpreter with no gemini argument, and any command line
# whose only mention of gemini is a later flag value, a working directory, or a
# prompt string - only argv[0] and the script argument are ever consulted, so
# an unrelated command that merely TALKS about gemini never matches.
fm_gemini_argv_is_gemini() {  # <argv0> [argv1...]
  local argv0=${1-} token
  [ -n "$argv0" ] || return 1
  fm_gemini_path_is_gemini "$argv0" && return 0
  case "${argv0##*/}" in
    node|node-*|node[0-9]*|MainThread) ;;
    *) return 1 ;;
  esac
  shift
  for token in "$@"; do
    case "$token" in
      -*) continue ;;
    esac
    fm_gemini_path_is_gemini "$token" && return 0
    return 1
  done
  return 1
}

# True when process $1 has Gemini's structural argv evidence. Linux exposes
# argv as NUL-delimited fields, which preserves a script path containing spaces
# that `ps -o args=` necessarily flattens into an ambiguous string.
fm_gemini_pid_is_gemini() {  # <pid>
  local token
  local -a argv=()
  [ -r "/proc/$1/cmdline" ] || return 1
  while IFS= read -r -d '' token; do
    argv+=("$token")
  done < "/proc/$1/cmdline"
  [ "${#argv[@]}" -gt 0 ] || return 1
  fm_gemini_argv_is_gemini "${argv[@]}"
}

# True when the whitespace-separated command line $1 is a Gemini process.
#
# This is the LOSSY feeder, for platforms that expose only a flattened command
# line: splitting it back on whitespace cannot recover a script path that
# contains a space. Callers holding real argv fields must use
# fm_gemini_argv_is_gemini directly rather than joining them first.
fm_gemini_args_are_gemini() {  # <args>
  local args=$1
  local -a fields=()
  [ -n "$args" ] || return 1
  read -ra fields <<< "$args"
  [ "${#fields[@]}" -gt 0 ] || return 1
  fm_gemini_argv_is_gemini "${fields[@]}"
}
