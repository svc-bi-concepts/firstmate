# Cortex Code

Snowflake's `cortex` TUI, verified end to end on 2026-09-09 with Cortex Code v1.1.84 on macOS (arm64).
Launch shape: `cortex --bypass --auto-accept-plans --no-auto-update "$(<brief>)"`.
Verified as a CREWMATE and SCOUT adapter only; `../../../../../bin/fm-spawn.sh` refuses a secondmate launch on it because `../../../../../docs/supervision-protocols/` carries no cortex wake protocol.

## Operating facts

| Fact | Value |
|---|---|
| Binary | `resolve_cortex_binary` in `../../../../../bin/fm-spawn.sh` resolves `PATH`, then falls back to `$HOME/.local/bin/cortex`; spawning refuses if neither is executable. The installed launcher is a symlink into a versioned `~/.local/share/cortex/<version>/cortex` directory. |
| Launch | A positional message is the session's initial prompt and auto-submits, so the brief rides the launch command exactly as it does for claude, grok, and gemini. The kimi/rovo launch-then-send shape is NOT needed here; see "Launch: the positional brief works" below. |
| Busy state | Semantic `cortex-hook`: `UserPromptSubmit` opens a turn, `Stop` and `SessionEnd` close it. There is no `StopFailure` event, and a manual interrupt fires no hook at all, so a cancelled turn stays busy exactly as Claude's does. |
| Rendered tail | Not a state source, but the footer is the one ASCII busy token: `esc to interrupt` (with `Type to queue next message`) while a turn runs, replaced by `? for help` at rest. The `⠏ <phase>...` spinner text is model-generated and never a signal. |
| Turn end | `Stop` fires once per turn after the final response and keeps the `state/<id>.turn-ended` touch as the watcher NOTIFICATION. |
| Exit | `/quit`, one Enter, process exits (confirmed by PTY EOF within a second of the Enter). `/exit` is NOT a command: typing it leaves the slash-command picker open on a fuzzy `quit` match, so the exit command must be `/quit`. |
| Interrupt | Single `Escape`, which prints `■ Interrupted - tell Cortex Code what to do next.` (cortex renders an em dash there; reproduced with a plain dash to keep this file to the repo style rule) and leaves the agent running. The composer does not repollute; it returns to its placeholder. |
| Skill invocation | `/<skill>`, the Claude form. Cortex discovers `~/.claude/skills` as GLOBAL skills, so `/no-mistakes` is available to a cortex worker (`cortex skill list` reports it by path). |
| Autonomy | `--bypass` (alias `--dangerously-allow-all-tool-calls`) auto-approves every tool call, and `--auto-accept-plans` clears the plan-mode confirmation. Both were verified unattended on real file writes and bash calls with no approval gate. |
| Marker | `CORTEX_SESSION_ID` and `CORTEX_TASK_CONTEXT_ID` on child and tool processes, both carrying the session uuid. `CORTEX_THINKING_EFFORT` and the `CORTEX_AGENT_*`/`COCO_*` variables are NOT identities - see Detection below. |
| Process name | `comm=cortex` exactly, because cortex ships as a compiled single binary rather than an interpreter bundle. |
| Resume | `cortex resume [session_id]`, `--continue` (most recent), `-r/--resume <id>` and `--fork-session`. Not used: `references/common/control-and-recovery.md` prefers deterministic relaunch from the brief on disk. |
| Model | `-m` / `--model <model>`; the operator's `~/.snowflake/cortex/settings.json` supplies the default, and the in-session `/model` dialog is the discovery surface. |
| Effort | `--effort minimal\|low\|medium\|high\|max`. There is no `xhigh`, so `references/common/model-and-effort.md`'s cap rule applies and `xhigh` maps onto `high`. `minimal` sits below firstmate's shared vocabulary and is deliberately unreachable. |
| Connection | Firstmate passes NO `-c`/`--connection`: the operator's own `cortexAgentConnectionName` in `~/.snowflake/cortex/settings.json` is the credential surface, and a cortex worker cannot reach Snowflake without it. |

## Launch: the positional brief works

`cortex [options] [message]` treats the positional argument as the session's initial prompt, and the resolution order it applies is `--print`, then `--goal`, then the joined positionals, then `CORTEX_INITIAL_PROMPT_FILE`.
A single quoted multi-line brief therefore arrives intact as one prompt.
Confirmed live three times over a raw PTY: the brief submitted itself with no extra Enter, the worker ran a real bash tool call, and the file it was asked to write appeared on disk.
`CORTEX_INITIAL_PROMPT_FILE` exists as an alternative but is deliberately unused - it is only the last fallback, and cortex DELETES the file it reads.

`--no-auto-update` is passed because cortex auto-updates on launch by default.
Leaving that on would let a spawn silently swap the harness version this reference's evidence is bound to, mid-flight.

## Hooks do not ride `--config`, and that is the whole design constraint

`cortex --config <settings.json>` reads a full replacement for the user settings layer, and it is NOT a hook source.
Verified live: a `--config` file carrying `UserPromptSubmit`/`Stop`/`SessionEnd` hooks produced no hook execution at all, while cortex's own log recorded `Loaded hooks from user settings at ~/.claude/settings.json` for the same run.

The hook loader reads a fixed path set instead: `<cortex-config-dir>/hooks.json`, then `settings.json` under `~/.claude` and `~/.cortex`, then `settings.json` and `settings.local.json` under the working directory's `.claude` and `.cortex`, in that priority order.
`../../../../../bin/fm-spawn.sh` therefore writes the busy-state and turn-end hooks into the WORKTREE at `.cortex/settings.local.json` - the highest-priority tier, and the direct analogue of the `.claude/settings.local.json` it already writes for claude.
Hook arrays merge across those tiers, so a project's own hooks still run alongside firstmate's.
The file is git-excluded by the spawn and retired with the disposable worktree, so nothing survives into a pooled one and nothing global is installed.

This is NOT gemini's shape, and the difference is worth stating because the two look alike from the outside.
Gemini exposes a settings PATH environment variable, so its hooks live in a firstmate-owned file under `state/`, outside the worktree.
Cortex exposes no such variable: `CORTEX_HOME` relocates the entire cortex config directory - settings, the project-trust store, the credential cache, conversations, and the operator's skills - so using it to place one hooks file would cost the worker its credentials and its `/no-mistakes` skill.
The worktree tier is the only per-task hook location cortex offers that does not mutate the operator's global configuration.

`SubagentStop` is deliberately unwired even though cortex fires it and runs subagents (`CORTEX_AGENT_ENABLE_SUBAGENTS=1`): closing the turn on a subagent's stop would clear the worker's busy record while its own turn is still running.

## Trust, and why no dialog appears

Cortex keeps a project-trust store at `~/.snowflake/cortex/cortex.json` under `projects.<path>.hasTrustDialogAccepted`, and its trust test walks ANCESTOR directories, so trusting `$HOME` once covers every task worktree beneath it.
That ancestor walk is why a treehouse pool worktree under a trusted home is never gated.
Independently of the store, three live launches in a directory the store had never seen (`/private/tmp/...`) showed no trust dialog at all and left the store untouched, so `--bypass` is what actually keeps the gate off a fresh worktree.
Unlike claude, firstmate therefore pre-registers nothing and the spawn cannot wedge on a trust dialog.

## Onboarding wizard: only reachable through `--config`

A settings file with no `cortexAgentConnectionName` sends cortex into first-run onboarding, whose first screen is `We found your Claude Code configuration / Import these settings into Cortex Code?` - a blocking dialog that would park an unattended worker.
It is reachable only by pointing `--config` at a file that lacks that key.
Firstmate passes no `--config` at all, so the operator's real settings are used and the wizard cannot appear.
Do not add a `--config` file to this adapter to carry hooks; it would not carry them and it would reintroduce this dialog.

## Detection

`../../../../../bin/fm-harness.sh` checks `CORTEX_SESSION_ID` and `CORTEX_TASK_CONTEXT_ID` before the `CLAUDECODE` line, then falls back to ancestry (`cortex)` case, beside `rovo)`).
Cortex does NOT scrub an inherited `CLAUDECODE`: a cortex tool process launched from a claude session carried `CORTEX_SESSION_ID` and `CLAUDECODE=1` together, the same ordering hazard cursor, gemini, and rovo already document.
`../../../../../bin/fm-spawn.sh` additionally clears the foreign markers at cortex's launch boundary.

Unlike gemini's, the marker is a fast path rather than the only detection path: cortex is a compiled binary whose live process reports `comm=cortex`, so the anchored ancestry arm covers a session a human started by hand.
The arm is anchored, never `*cortex*`, so an unrelated command cannot claim the identity.
`../../../../../tests/fm-cortex-harness.test.sh` pins the marker precedence, the anchored ancestry arm, the control mechanics, and the launch and hook shapes; `../../../../../tests/fm-crew-state.test.sh` pins that a cortex worker now reads a real state instead of `unknown - harness state unavailable`.

`CORTEX_THINKING_EFFORT`, `CORTEX_AGENT_*`, and the `COCO_*` family must never be promoted to markers.
Cortex READS all of them from its own settings and environment, so an operator can set them for a non-cortex process - exactly the precedence hazard this layer creates.
`CORTEX_THINKING_EFFORT` in particular arrives from the operator's `settings.json` `env` block and appears in every process that settings file touches.

## Composer: a known, unfixed gap

Cortex draws a bordered composer (`╭─╮ │ › │ ╰─╯`) whose empty state renders a DIM placeholder, and under firstmate's launch flags that placeholder is `Plans will be auto accepted (/auto-accept-plan-off to disable)`.
Its other placeholders are `Type your message...` at rest without those flags and `Type to queue message...` while busy.
None is in `FM_COMPOSER_IDLE_RE_DEFAULT`, and the terminal draws the cell under its cursor in reverse video, so `../../../../../bin/fm-composer-lib.sh` strips the dim run and is left with a one-character remnant it cannot match against a known placeholder.
An idle cortex composer therefore classifies `pending-unproven` rather than `empty`.

This is left unfixed deliberately: it is a change to the fleet-wide shared classifier, and it could not be verified here against a faithful pane capture, since neither tmux nor a non-Herdr session provider was available on the verification host.
The consequence is bounded to composer-emptiness consumers and matches rovo's already-accepted gap.
Steering still lands - `../../../../../bin/fm-task-inbox-lib.sh` rings on every verdict except a proven `pending` - it just spends its Enter retry budget first.
The launch is unaffected because the positional brief needs no readiness gate.
A fix belongs with a real backend capture and its own regression, not inside this adapter.

## Primary integration

Unsupported and unverified.
`../../../../../docs/supervision-protocols/` carries no cortex protocol, no turn-end guard adapter exists for it, and no session-start nudge or pre-tool arm guard has been built.
`references/common/primary-hooks.md`'s unsupported-boundary rule applies: never invent a wake protocol from a similar TUI.
The Claude-shaped hook set makes a future primary integration plausible - cortex fires `SessionStart`, `PreToolUse`, and `Stop` - but a primary also needs a watcher-continuity owner equivalent to `../../../../../bin/fm-claude-stop-autoarm.sh`, which is unbuilt work rather than a fact to rely on.
