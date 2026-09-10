# Verification: the cortex (Snowflake Cortex Code) crewmate/scout adapter

Active empirical evidence for firstmate's cortex adapter.
The [`harness-adapters`](../../.agents/skills/harness-adapters/SKILL.md) skill's [cortex reference](../../.agents/skills/harness-adapters/references/harness/cortex.md) owns the operating facts; this record owns how they were established and what is still unproven.
[`configuration.md`](../configuration.md#harness-support) owns the operator-facing support statement, and [`herdr-backend.md`](../herdr-backend.md#restart-and-liveness-behavior) owns the harness-aware Herdr classification rule this record establishes.

## Subject

| Field | Value |
|---|---|
| Version | `Cortex Code v1.1.84` (`1.1.84+190213.c06a9c29d351`) |
| Verified | 2026-09-09 |
| Binary | `~/.local/bin/cortex`, a symlink to a Mach-O arm64 single binary under `~/.local/share/cortex/<version>/cortex` |
| Platform | macOS arm64 (Darwin 25.3.0) |

Every check below ran unsandboxed against the real binary on a live Snowflake connection.

The first round's interactive checks were driven through a raw PTY, because neither tmux nor Herdr was installed on that host.
Both providers were available for the second round, so the backend-liveness, lifecycle-guard, and steering findings below are now established against a real tmux session and a real Herdr 0.8.2 server with live workers.
The raw-PTY bound survives for one finding only, recorded under "Composer" below.

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
  '/Users/<user>/.local/bin/cortex' --bypass --auto-accept-plans \
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

This was measured from a raw PTY stream rather than from a session provider's pane capture, so the verdict a faithful capture produces is not established here; re-measuring it belongs with the fix.
A fix would change the fleet-wide shared classifier, so it is left unmade rather than made against an unfaithful capture.
The consequence matches rovo's already-accepted composer gap and is bounded to composer-emptiness consumers: steering still lands, because `bin/fm-task-inbox-lib.sh` rings on every verdict except a proven `pending`.
The launch is unaffected, since the positional brief needs no readiness gate.

## Backend liveness: the tmux arm

The shared process-name vocabulary gained an anchored `cortex` arm, and `FM_HARNESS_RE`/`FM_HARNESS_NAMES` in `bin/fm-session-lock-lib.sh` gained the same name.
That vocabulary is owned by `fm_harness_classify_process_name` in [`../../bin/fm-harness-process-lib.sh`](../../bin/fm-harness-process-lib.sh), which both the tmux and herdr adapters delegate to; `fm_backend_tmux_classify_process_name` is the tmux adapter's name for it, so a harness added here reaches both backends at once.
The arm is needed because the neighbouring `*codex*` glob does not cover `cortex` - the two names differ by one letter - and it is anchored rather than a `*cortex*` glob so `cortexd` and `cortex-helper` cannot claim the identity.
Without it a live cortex pane classified `other`, the composed verdict was `ambiguous`, and every `bin/fm-control.sh` verb refused the worker it could no longer see.
Adding a literal name to those lists can only change the outcome for a process actually named `cortex`, so no other harness's classification moves; `tests/fm-cortex-harness.test.sh` asserts both directions against a faked process name.

## Backend liveness: Herdr, proven on a real server

Herdr's installed build ships no cortex integration (`herdr integration status` lists none - the same enumeration recorded in [rovo.md](rovo.md) for rovo's identical gap), so `herdr agent get <pane>` answers `agent_not_found` for a LIVE cortex pane exactly as it answers for an empty restored one.

Which harnesses this applies to is not pinned in firstmate: `fm_backend_herdr_pane_agent_state` reads Herdr's own reported integration coverage and resolves `agent_not_found` to `unknown` for every harness that enumeration omits.
On Herdr 0.8.2 that is `cortex`, `rovo`, `muse`, and `gemini`; `pi-signed` resolves through Herdr's `pi` integration because firstmate launches the same pi agent (`bin/fm-control-lib.sh`'s shared wiring paths).
Verified 2026-09-10 on Herdr 0.8.2 against a live Cortex Code worker in the default session's pane `w16:p2`, reading its own endpoint:

```
$ herdr pane get w16:p2 --session default
{"result":{"pane":{"agent_status":"unknown","pane_id":"w16:p2","terminal_title_stripped":"cortex",...}}}
$ herdr agent get w16:p2 --session default
{"error":{"code":"agent_not_found","message":"agent target w16:p2 not found"},"id":"cli:agent:get"}

$ herdr integration status | cut -d: -f1 | tr '\n' ' '
pi omp claude codex copilot devin droid kimi opencode kilo hermes qodercli qwen cursor mastracode antigravity-cli grok
```

Install state is deliberately not consulted, and this run is why: `integration status` reported every integration `not installed`, yet a live claude pane in the same session still reported a registered agent, so Herdr registers agents it launches regardless of the harness-side hook file.

```
$ herdr pane list --session default   # claude pane, same server, same moment
{"agent":"claude","agent_status":"done","pane_id":"w0:p1",...}
```

The general rule is what makes the fix hold, and the before/after on that same live cortex pane shows why a harness name would not have:

```
harness   before(HEAD)   after
cortex    unreadable     alive        <- attributed by its foreground process
rovo      dead           alive        <- a LIVE worker had read as agent-free
muse      dead           alive
gemini    dead           alive
claude    dead           dead         <- unchanged: herdr's registry is authoritative
```

The `before` column is what HEAD produced on that same live pane, and `rovo`, `muse`, and `gemini` are why the harness name could not be the rule: the earlier guard pinned `cortex` alone, so three other harnesses still read a running worker as agent-free - `dead` being the one value the relaunch verifier acts on.
`claude` and `codex` stay `dead` here because for a harness Herdr DOES integrate with its registry remains authoritative, and no claude agent is registered in that pane.

Read with no harness argument the verdict is `dead`, unchanged, because a caller that names no harness never had a coverage question to ask.
The relaunch verifier is the highest-severity consumer: it previously read this live worker as `dead` and would have relaunched over the worktree it still owns; it now reads `alive` and refuses, and reads a genuinely stopped worker as `dead` and proceeds.
A coverage read that fails entirely resolves to `unknown` without consulting the process fallback, so the failure mode is refusal rather than substituting evidence for a coverage question that went unanswered.
That resolution is itself silent, because the predicate carrying it is polled by every lifecycle verb; the operator sees the condition once, in the `unreadable` verdict each caller names in its refusal.

### Lifecycle control: attributed by process, proven live

An honest registry read stops the lying but leaves every verb refusing a worker nobody can attribute, so the adapter attributes an uncovered harness's pane from its foreground process through `pane process-info`, read via the shared vocabulary in `bin/fm-harness-process-lib.sh`.
Verified 2026-09-10 on Herdr 0.8.2 against the same live cortex pane:

```
$ herdr pane process-info --pane w16:p2 --session default
{"result":{"process_info":{"pane_id":"w16:p2","shell_pid":3073,
  "foreground_process_group_id":4983,
  "foreground_processes":[{"pid":4983,"name":"cortex","argv0":"cortex"}]}}}
```

That pane then read `alive` where the registry read alone said `unreadable`.
Only the two positive verdicts are trusted - a verified harness process is `alive`, a pane proven to hold nothing but an idle shell is agent-free - and anything unreadable or unattributable stays `unknown`, so no verb fires on uncertainty.
The agent-free verdict is the one that can close a tab and clear the relaunch gate, and a shell-looking process name alone does not establish it: a worker suspended with Ctrl+Z or still inside its launch line presents a single foreground `bash`.
It therefore additionally requires `fm_backend_herdr_pane_idle_shell_sample`, one sample of the same childless-idle-shell proof the pane-close paths depend on rather than the retrying `fm_backend_herdr_pane_idle_shell_pid` wrapper, because this read is polled; a pane that cannot pass that sample stays `unknown`.
`rovo` (`comm=rovo`, [rovo.md](rovo.md)) and `muse` (`muse-bin`/`muse-bin-<version>`, [muse.md](muse.md)) are already carried by the shared name vocabulary, so they are attributable alongside `cortex`.
`gemini` is not: its CLI is a node bundle reporting `MainThread` and the interpreter path with the identity only in the script argument, so no process name attributes it and its panes read `unknown` - an honest refusal rather than lifecycle control.

`tests/fm-cortex-herdr-lifecycle-live-e2e.test.sh` is the opt-in guard that refreshes this end to end, on a host with a real Herdr server and an installed `cortex`:

```
FM_CORTEX_HERDR_LIFECYCLE_LIVE_E2E=1 bin/fm-test-run.sh tests/fm-cortex-herdr-lifecycle-live-e2e.test.sh
```

It provisions an isolated non-default `fm-lab-` session through `bin/fm-herdr-lab.sh`, launches a REAL Cortex Code worker into it, and asserts the whole sequence; run 2026-09-10 on Herdr 0.8.2, all cases green:

```
ok - an empty pane recorded as cortex reads agent-free from its shell process
ok - real cortex: the pane's foreground process attributes the worker
ok - a live cortex worker reads alive even though agent get cannot see it
ok - interrupt delivers to a live cortex worker and leaves the endpoint intact
ok - exit actually stops the cortex worker and the pane returns to agent-free
ok - relaunch cleared the endpoint gate
ok - the cortex lifecycle verbs are available and the endpoint survived every one
```

The guard asserts that Herdr still answers `agent_not_found` for that worker, so the fallback can never be silently untested by a future build that starts registering cortex.
`tests/fm-herdr-integration-coverage-live-e2e.test.sh` is the companion guard over the coverage read itself and needs no opt-in: it runs by default wherever `herdr` and `jq` are installed.
The empty-pane case is the divergence that keeps the rest from being vacuous: the same pane, same session, same recorded harness, differing only in whether a cortex process runs, must classify differently.
Relaunch is asserted at its endpoint gate rather than to completion, because that gate is what the blind read broke; a full relaunch additionally drives worktree acquisition, which fails in the guard's synthetic home for reasons unrelated to this classifier.

This is no longer asserted only against a canned Herdr CLI.
It was re-verified against a **real Herdr 0.8.2 server** with a real Cortex Code v1.1.84 worker and a real claude worker spawned into the same isolated lab session at the same moment, both idle at their composers and both demonstrably alive by pane read.
Herdr saw one of them:

```
$ herdr agent list --session <lab>
{"result":{"agents":[{"agent":"claude","agent_status":"idle","pane_id":"w2:p2",...}]}}   # cortex absent
```

### The guard, both directions

These readings are the coverage guard measured on its own, before the process-attribution fallback above was added; `unreadable` is where a blind read stopped, not where a cortex pane stops today.

```
cortex  no harness arg   -> dead          <- the hazard, if a consumer is left unthreaded
cortex  harness=cortex   -> unreadable    <- the guard
claude  no harness arg   -> alive         <- no collateral damage to other harnesses
claude  harness=claude   -> alive
```

The counterfactual is the important half, and it is equally clear on the live server.
The husk classifier, run directly against the running cortex pane:

```
tab_is_husk no harness     -> 0  HUSK -> WOULD CLOSE THE LIVE WORKER
tab_is_husk harness=cortex -> 1  refuse
```

and `bin/fm-control.sh ctx1 exit` refused rather than reporting a false `already-stopped`:

```
error: task ctx1's endpoint reads 'unreadable' rather than a positively classified
state; refusing to send a lifecycle command into an unattributed endpoint
```

At that stage every path that could act destructively on the blind read refused instead, which removed the hazard without giving cortex lifecycle CONTROL on Herdr; the process-attribution fallback recorded above is what turned those refusals into working control.

### Steering: the consumer that did not refuse safely

An earlier revision of this file framed the blind spot as affecting exactly three RECOVERY paths and called their refusals "the verified-safe behaviour".
That was incomplete in a way that mattered.
The steering doorbell is a fourth consumer of the same read, it is not a recovery path, and it did not refuse safely.

`fm_task_inbox_ring`'s endpoint pre-check resolved a live cortex worker to `dead`, so it silently declined to type, `bin/fm-send.sh` reported that the agent "has exited", and the watcher read the same blind state and escalated the worker as unavailable instead of re-ringing it - disabling the very ladder that exists to recover an undelivered steer.
A cortex worker on a Herdr home was therefore **write-only**: startable, never redirectable.
Every guarded lifecycle path failed loudly; this one failed quietly, which is why it survived the first round.

The fix threads the same optional harness family already carried by `fm_backend_agent_state` through the remaining firstmate-side consumers: `fm_task_inbox_ring` and `fm_backend_agent_alive` now accept it, and `bin/fm-send.sh`, `bin/fm-watch.sh` (both its steer check and its paused-classification gates), `bin/fm-spawn.sh`'s duplicate-launch guards, and `bin/fm-crew-state.sh`'s degraded-path endpoint read all pass it.
That last one is the supervision read: when `pane_readable`'s capture errors or stalls under load, the fallback classifier ran blind and reported a live cortex worker as `backend target gone ... (agent gone, pane shell remains)`, a false claim that invites a teardown where `backend unreachable` invites a retry.
Omitting the argument still yields the previous harness-blind classification, so no existing caller changes behaviour.

The three-state compatibility view gained the same argument, because `dead` is the one value it licenses action on.
Read on the live server, with the worker running throughout - the harness-blind form is retained deliberately, so an old caller's verdict is unchanged:

```
fm_backend_agent_alive herdr <cortex-pane>          -> dead      <- harness-blind, unchanged
fm_backend_agent_alive herdr <cortex-pane> cortex   -> unknown   <- honest, and no longer actionable
fm_backend_agent_alive herdr <claude-pane> claude   -> alive     <- unaffected
```

Its consumers are `bin/fm-watch.sh`'s two paused-classification gates and `bin/fm-spawn.sh`'s duplicate-launch guard, all of which now pass the harness; `bin/fm-fleet-snapshot.sh` reads it for secondmates only, and cortex cannot be a secondmate, so no fleet view was affected.

### The steering experiment, re-run live

The same controlled side-by-side experiment that first exposed the defect, re-run against the fix: one cortex scout and one claude scout in one lab session, the identical `bin/fm-send.sh` command to each.

**Both acted on it.** The cortex worker, which previously never learned anything had been sent:

```
Handled 001.msg: wrote STEER-RECEIVED to /tmp/ctx1-steer-proof.txt (verified) and moved the
message to handled/. Inbox is empty; going idle at the composer awaiting the next steering
instruction.
```

Proof files after the run: `cortex: STEER-RECEIVED`, `claude: STEER-RECEIVED`, and both `001.msg` records moved into their `handled/` directories - the acknowledgement move being the only real delivery signal.
`bin/fm-send.sh` printed no undelivered-doorbell notice for either worker.

All Herdr work ran in an isolated non-`default` lab session provisioned and torn down only through `bin/fm-herdr-lab.sh`, with the live `default` session recorded before the run and verified running and unchanged after teardown.

`tests/fm-cortex-harness.test.sh` pins the divergence against a canned Herdr CLI in both directions: a cortex ring must not skip as dead and must actually type the doorbell, an agent-free claude ring must still skip with 3, and a harness-less ring must keep the existing verdict.

## Landed since the first round

Recorded because an earlier revision of this file listed these as pending, and a reader outside this fleet would otherwise plan around follow-up work that no longer exists.

- **Lifecycle control is done**, not pending.
  cortex is in `fm_control_harness_supported` (`bin/fm-control-lib.sh`) and its interrupt and exit mechanics are wired, with the full verb set verified end to end on tmux and on Herdr.
  Herdr still ships no cortex *detection*, which is Herdr's to close, but firstmate no longer waits on it: the process-attribution fallback under "Backend liveness: Herdr" above supplies the endpoint verdict those verbs need.
- **Steering a cortex worker on Herdr is fixed and verified live.**
  See "Backend liveness: Herdr"; this was the one silent failure in the set.
- `--no-auto-update` removed from the launch template and its rationale corrected.
  It cannot deliver the version pinning it appears to: it suppresses the launch-time update only, so it never prevents the mid-session swap that is the actual hazard, while its one durable effect is keeping every crewmate on whatever build the host happens to carry, declining upstream fixes indefinitely.
- cortex added to `crew_dispatch_validate`'s verified list in `bin/fm-bootstrap.sh`, so it is dispatchable through `config/crew-dispatch.json` instead of producing an actionable `CREW_DISPATCH: invalid` diagnostic every session start.

## Decided but not included

These were raised by review on this branch and decided, but are not in this change; they are the accurate starting point for the follow-up.

- Remove `.cortex/settings.local.json` in `bin/fm-teardown.sh`'s pool-worktree cleanup, beside the `.claude`, `.opencode`, grok, and kimi artifacts.
- Replace the raw `grep` over `.git/info/exclude` in `tests/fm-cortex-harness.test.sh` with `git check-ignore`, this repo's own idiom.
- Remove the `${HOME:-}/.local/bin/cortex` fallback from `resolve_cortex_binary`, leaving the PATH lookup, matching `resolve_muse_binary`.
  `resolve_rovo_binary` carries the identical fallback, so removing it from cortex alone leaves the two inconsistent; decide both together.
- Remove the second detection marker arm `CORTEX_TASK_CONTEXT_ID`, since the two variables were only ever observed together and `bin/fm-harness.sh` returning `unknown` is a safe stop-and-ask failure mode.
- The composer classification above, which is fleet-wide in `bin/fm-composer-lib.sh` and shared with rovo rather than specific to this adapter.
  It needs a real pane capture, its own regression, and a decision taken across every affected harness at once.
- Thread the harness family through `bin/fm-remote-secondmate-control.sh`'s two endpoint reads (its agent-state probe and its doorbell ring).
  They are deliberately untouched here because they are reachable only for a SECONDMATE, and `bin/fm-spawn.sh` refuses a cortex secondmate, so no cortex worker can reach them.
  They are worth closing when another harness Herdr cannot see becomes secondmate-capable.

## Not verified

- Primary and secondmate use.
  No cortex wake protocol, turn-end guard adapter, session-start nudge, or watcher-continuity owner exists, and `bin/fm-spawn.sh` refuses a cortex secondmate.
- Behaviour under the zellij, orca, and cmux session providers.
  tmux and Herdr are both covered above with live workers; the other three were not installed and are unexercised.
- `cortex resume` and `--continue` as a recovery path.
  Firstmate relaunches deterministically from the brief on disk instead.
