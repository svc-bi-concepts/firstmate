# Verification: the cortex (Snowflake Cortex Code) crewmate/scout adapter

Active empirical evidence for firstmate's cortex adapter.
The skill tree rooted at [`.agents/skills/harness-adapters/SKILL.md`](../../.agents/skills/harness-adapters/references/harness/cortex.md) owns the operating facts; this record owns how they were established and what is still unproven.

## Subject

| Field | Value |
|---|---|
| Version | `Cortex Code v1.1.84` (`1.1.84+190213.c06a9c29d351`) |
| Verified | 2026-09-09 |
| Binary | `~/.local/bin/cortex`, a symlink to a Mach-O arm64 single binary under `~/.local/share/cortex/<version>/cortex` |
| Platform | macOS arm64 (Darwin 25.3.0) |

Every check below ran unsandboxed against the real binary on a live Snowflake connection.
The tmux and Herdr session providers were both unavailable on the verification host, so the interactive checks were driven through a raw PTY rather than a firstmate backend.
That bounds one finding only, recorded under "Composer" below.

## Detection

```
$ cortex --version
Cortex Code v1.1.84
```

A Bash tool subprocess inside a live cortex session, started from a Claude session, reported both identities at once:

```
CLAUDECODE=1
CORTEX_SESSION_ID=844e250a-a114-4bb6-825e-4def6facfbb2
CORTEX_TASK_CONTEXT_ID=844e250a-a114-4bb6-825e-4def6facfbb2
```

Neither `CORTEX_*` variable was present in the launching environment, and cortex does not scrub the inherited `CLAUDECODE`, so `bin/fm-harness.sh` tests both markers before the `CLAUDECODE` line.
`CORTEX_THINKING_EFFORT=high` was present in the same process but originates from the operator's own `~/.snowflake/cortex/settings.json` `env` block, so it is an input cortex reads rather than an identity it publishes; the same applies to the `CORTEX_AGENT_*` family and `CORTEX_PROJECT_DIR`.

Ancestry is a real second layer here, unlike gemini's node bundle:

```
$ ps -o comm= -p <live cortex pid>
cortex
```

`tests/fm-cortex-harness.test.sh` pins the marker-precedence order, the input-variable exclusion, and the anchored ancestry arm with faked `ps` output.

## Launch: a positional brief, the claude shape

The brief rides the launch command.
Three independent PTY runs with a positional prompt launched cleanly, submitted the prompt with no extra Enter, ran a real `Bash` tool call, and left the requested file on disk.
The kimi/rovo launch-then-send shape was considered and is not needed.

Cortex resolves its initial prompt as `--print`, then `--goal`, then the joined positionals, then `CORTEX_INITIAL_PROMPT_FILE`, so a single quoted multi-line brief arrives intact as one prompt.
`CORTEX_INITIAL_PROMPT_FILE` is deliberately unused: it is only the last fallback, and cortex deletes the file it reads.

### End-to-end run of the shipped artifacts

The final check ran the launch command `bin/fm-spawn.sh` itself rendered, with only the fake test binary path swapped for the real one, in the worktree that same spawn created, against the hook file that same spawn wrote:

```
env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI \
  env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS \
  '/Users/<user>/.local/bin/cortex' --bypass --auto-accept-plans --no-auto-update \
  "$('<root>/bin/fm-operational-input.sh' encode launch-brief < '<home>/data/cx-e2e/launch-brief.md')"
```

Result: the worker completed the brief (`PROOF.txt` written), the `Stop` hook touched `state/cx-e2e.turn-ended`, `/quit` plus one Enter exited to the session-summary card, and the busy record ended at

```
v1 gen=g1788944371.26589.30621 seq=4 state=idle source=cortex-hook event=session-end ts=1788944501
```

with `fm_busy_classify` reporting `idle cortex-hook`.
`seq=4` is the four applied events: the spawn seed, `UserPromptSubmit`, `Stop`, and `SessionEnd`.

## Hooks: `--config` is not a hook source

This is the load-bearing negative finding, and it is why cortex's wiring does not follow gemini's.

A `--config` settings file carrying `UserPromptSubmit`, `Stop`, and `SessionEnd` hooks produced no hook execution at all.
Cortex's own log for that same run recorded where it did look:

```
{"logger":"coco.main","msg":"Config: <the --config path>"}
{"logger":"sdk.hooks.configLoader","msg":"Loaded hooks from user settings at /Users/<user>/.claude/settings.json"}
{"logger":"sdk.hooks.configLoader","msg":"Loaded hooks (deduplicated): {\"SessionStart\":3}"}
```

The loader's sources are `<cortex-config-dir>/hooks.json` (priority 1), then for each of `.claude` and `.cortex`: `~/<dir>/settings.json` (2), `<cwd>/<dir>/settings.json` (3), and `<cwd>/<dir>/settings.local.json` (4).
Moving the same hooks into the worktree's `.cortex/settings.local.json` made all of `SessionStart`, `UserPromptSubmit`, `Stop`, and `SessionEnd` fire.
`CORTEX_HOME` would relocate the whole cortex config directory - settings, the project-trust store, the credential cache, conversations, and the operator's skills - so it is not a way to place one hooks file outside the worktree.

The hook event set is Claude's minus `StopFailure`: `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Notification`, `PreCompact`, `SubagentStop`, `Stop`, `SessionEnd`.
An interrupted turn fired no `Stop` at all, so a cancelled cortex turn stays busy exactly as a cancelled claude turn does.

## Onboarding: reachable only through `--config`

A settings file without `cortexAgentConnectionName` sends cortex into first-run onboarding, whose first screen is a blocking dialog:

```
We found your Claude Code configuration
Import these settings into Cortex Code? You can change them later.
  [Y] Import settings
  [N] Skip
```

It appeared with a hooks-only `--config` file and again with one carrying only `theme`, and did not appear once the file also carried the operator's `cortexAgentConnectionName`.
Firstmate passes no `--config`, so the operator's real settings are used and this dialog is unreachable.

## Trust

Cortex stores project trust in `~/.snowflake/cortex/cortex.json` under `projects.<path>.hasTrustDialogAccepted`, and `isProjectTrusted` walks ancestor directories, so trusting a home directory once covers every worktree beneath it.
Independently of that, three launches under `--bypass` in a directory the store had never seen showed no trust dialog and left the stored project list unchanged, so a fresh task worktree cannot wedge a spawn on a trust gate.
No pre-registration equivalent to `bin/fm-claude-trust.sh` is needed.

## Interrupt and exit

A single `Escape` sent during a live `sleep` tool call cancelled the turn and rendered:

```
×  BASH  (Sleep 20 seconds (2 of 5))
 ■ Interrupted - tell Cortex Code what to do next. /feedback to report issues.
```

The composer returned to its placeholder with no repolluted text, so no clear key is needed.
The footer is `esc to interrupt` while a turn runs and `? for help` at rest.

`/quit` followed by one Enter exited: the PTY reached EOF 0.5s after the Enter, and the session-summary card with `cortex --resume <id>` was the last thing drawn.
`/exit` is not a cortex command - typing it leaves the slash-command picker open on a fuzzy `quit` match with `quit  Exit the CLI with session summary` as the top row - so `/exit` must not be used as the exit command.

## Model, effort, and skills

`cortex --help` on this build advertises `-m/--model` and `--effort minimal|low|medium|high|max`.
There is no `xhigh`, so the adapter caps a requested `xhigh` onto `high` per the shared model-and-effort contract, and `minimal` stays unreachable below firstmate's vocabulary.

`cortex skill list` reports the operator's `~/.claude/skills` entries as `[GLOBAL]` skills, including:

```
  [GLOBAL]
    - no-mistakes: /Users/<user>/.claude/skills/no-mistakes
```

So a cortex ship crewmate can invoke `/no-mistakes`, unlike rovo, whose skill loader rejects firstmate's `SKILL.md` frontmatter.

## Composer: unproven, and deliberately unfixed

Cortex's empty composer renders a dim placeholder whose first cell the terminal draws in reverse video, the same shape cursor-agent produces.
Under the adapter's own launch flags that placeholder is `Plans will be auto accepted (/auto-accept-plan-off to disable)`; without them it is `Type your message...` at rest and `Type to queue message...` while busy.
None is in `FM_COMPOSER_IDLE_RE_DEFAULT`, so an idle cortex composer classifies `pending-unproven` rather than `empty`.

This was measured from a raw PTY stream, not from a session provider's pane capture, because neither tmux nor a non-Herdr provider was installed on this host.
A fix would change the fleet-wide shared classifier, so it is left unmade rather than made against an unfaithful capture.
The consequence matches rovo's already-accepted composer gap and is bounded to composer-emptiness consumers: steering still lands, because `bin/fm-task-inbox-lib.sh` rings on every verdict except a proven `pending`.
The launch is unaffected, since the positional brief needs no readiness gate.

## Not verified

- Primary and secondmate use.
  No cortex wake protocol, turn-end guard adapter, session-start nudge, or watcher-continuity owner exists, and `bin/fm-spawn.sh` refuses a cortex secondmate.
- Behaviour under a firstmate session provider (tmux, Herdr, zellij, orca, cmux).
  Every interactive check here used a raw PTY.
- `cortex resume` and `--continue` as a recovery path.
  Firstmate relaunches deterministically from the brief on disk instead.
