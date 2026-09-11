# Validation agent selection

This page owns which agent the no-mistakes validation gate uses, and how to change it.
It exists because that choice is a separate setting from firstmate's own crew harness, and operators reasonably assume the two move together.

## The gate resolves its own agent

no-mistakes runs the validation pipeline, so every agent inside a validation run is one no-mistakes resolved for itself.
It reads that from its own configuration and never from firstmate's crew settings.

Switching crews to a harness therefore does NOT switch the validation gate.
`config/crew-harness`, a per-spawn harness, and every `config/crew-dispatch.json` profile govern the workers firstmate launches; see [`configuration.md`](configuration.md) for those settings.
None of them reaches the gate.
Until you change the gate's own setting, code written by a crew on one tool is validated and fixed by a different tool, on a different account.

The machine-wide setting lives in no-mistakes' global `config.yaml`, in the data directory `no-mistakes doctor` prints.
A repository can pin `agent` in its own `.no-mistakes.yaml` instead, which is how a repository binds its gate agent to itself rather than to whichever machine happens to push it.
That pin is trusted-only: no-mistakes reads `agent` and `commands` from the default-branch copy of the file, not from the copy on the pushed branch, unless the default-branch copy sets `allow_repo_commands`.
Model and effort stay machine-wide either way.
`agent_config` and `agent_args_override` are both marked global-only in the config's own comments, and `review_agents` is global-only in effect: a copy in a repository's `.no-mistakes.yaml` is ignored rather than rejected, so even one naming a harness no-mistakes does not accept loads without complaint while Review still runs on the global agent.

## Pointing the gate at a natively supported harness

Set `agent:` to the harness name.
It also accepts an ordered fallback list, such as `[codex, grok]`, which no-mistakes works through when an agent fails.
`no-mistakes doctor` lists the agent names it knows under `Agents`, but that section is not a list of natively supported harnesses: it carries `acpx`, the bridge itself, and `cursor`, an ACP alias, alongside the native names.
The config's own comment carries the current accepted values alongside `auto`, and marks which of them are aliases.
`auto` picks the first available native agent or ACP alias on the system, which is convenient and non-deterministic; name the harness when you care which one runs.
The next section owns which of those names a given repository can actually use, so settle that before you commit to one.

## A repository that suppresses its own agent instructions restricts the gate agent

A repository opts into suppressing its own `AGENTS.md` and `CLAUDE.md` for gate agents with `disable_project_settings: true` in its `.no-mistakes.yaml`; [`architecture.md`](architecture.md#no-mistakes-gate-authority-boundary) owns that setting and how no-mistakes sources it.
A gate agent that cannot neutralize those files is refused there rather than allowed to read the project's own agent instructions.
That rule is about the agent you chose, not about any one way of reaching it: only `codex`, `claude`, and `pi` carry a verified neutralization knob, and only while `agent_args_override` does not replace it.
Every other native harness is refused in such a repository, an `acp:<target>` agent is refused, and `auto` is refused whenever it resolves to one of them - which makes the outcome a property of the machine rather than of your configuration.
An ordered fallback list has to satisfy the rule in every entry that resolves on the machine, not just the entry that would run: in an opt-in repository, `[claude, "acp:cortex"]` with both resolvable failed before the first step, while `[claude, grok]` on a machine without grok installed ran normally, because an entry whose binary is not installed is pruned and does not count against the rule.

The trigger is that opt-in, not the presence of the files.
A repository that carries `AGENTS.md` or `CLAUDE.md` and does not set `disable_project_settings` launches any runnable gate agent normally, ACP-bridged ones included.

The refusal arrives as a failed run before the first step, naming the gate agent and the instruction files it will not neutralize.
`no-mistakes doctor` does NOT catch this, because the refusal depends on the repository being validated while doctor answers only whether the agent is runnable at all.
A doctor line reporting your chosen agent runnable is therefore compatible with every run in such a repository failing.

firstmate carries that opt-in, so its own gate agent has to be `codex`, `claude`, or `pi`, and validating firstmate through the ACP bridge is not available.
That is the tradeoff the opt-in buys: such a repository can still run its crews on any tool, an ACP-bridged one included, but its validation gate has to be one of the three natively neutralizing agents.

## Pointing the gate at a harness no-mistakes cannot drive natively

Use the `acp:<target>` agent form.
Both sides of that bridge speak the Agent Client Protocol, and `acpx` is the piece in the middle: a headless ACP client that drives an ACP agent over stdio, so no-mistakes can use a tool it has no native integration for.
`acpx` is user-installed and is a hard requirement for this setup rather than an optional extra - `no-mistakes doctor` lists it under `Agents` and reports it not found until you install it.

One key always applies; the other two cover the machine and the targets `acpx` does not already know:

- `agent: acp:<target>` selects it.
- `acpx_path` points at the installed `acpx` binary, and defaults to resolving `acpx` from `PATH`, so set it only when that lookup cannot be relied on - see Troubleshooting for the case that makes it advisable.
- `acp_registry_overrides` maps `<target>` to the command that starts that tool as an ACP agent.

`acpx` ships its own registry, which `acpx --help` lists as subcommands, so a target it already knows resolves with no override at all.
The override is what makes a target it does not know, such as `cortex`, resolvable; for one of those the name is yours to choose, and it is meaningful only as the key `acp_registry_overrides` resolves.

## Cortex Code as the worked example

Cortex Code's ACP entry point is `cortex acp serve`, which starts it as an ACP agent over stdio.
Mapping it as a target called `cortex` gives the gate `acp:cortex`:

```yaml
agent: acp:cortex

acpx_path: <your-acpx-path>

acp_registry_overrides:
  cortex: <your-cortex-path> acp serve

agent_config:
  "acp:cortex":
    model: <model-id>
```

`acp:cortex` parses as an `agent_config` key unquoted too, because a colon only ends a key when whitespace follows it, but quoting a key that contains one is the safer habit.

## Model and reasoning effort

`agent_config` is where a model and reasoning effort are pinned, in one common spelling that no-mistakes maps down to whatever the selected harness actually accepts.
The config's own comment is the current owner of the per-harness mapping and of the accepted effort levels, and a harness rejects any level it does not implement, so verify a pin rather than assuming it was honored.

On the ACP path the only mapping is `acpx --model`, so an ACP-backed agent takes `model` and nothing else - which covers the bare `cursor` alias as much as an explicit `acp:<target>` spelling.
An `effort` under one is not merely ignored: it fails config load with `agent "<name>" cannot express effort` and takes the whole gate down until you remove it.
`agent_config.cursor` with `effort: high` is refused as `invalid agent_config.cursor: agent "cursor" cannot express effort`, while the same key carrying `model` alone loads; this is config-load validation, so the refusal lands even on a machine where the underlying tool is not installed.
The escape hatch the error itself names is to bake the flag into that target's `acp_registry_overrides` command, if the tool's own command accepts one.
A `review_agents` role agent is held to the same rule: `reviewer` set to `agent: "acp:cortex"` with `effort: high` fails config load as `invalid review_agents.reviewer: agent "acp:cortex" cannot express effort`, naming the offending role key, and leaves the whole gate unavailable until the effort key is removed.
`no-mistakes doctor` does report this refusal, unlike the neutralization one.

`agent` and `agent_config` configure the whole run, and the Review step is the one place that can be split away from them.
`review_agents` pins the `reviewer` and `fixer` roles - the review pass and its review-fix turns - to their own harness, model, and effort:

```yaml
review_agents:
  reviewer:
    agent: claude
    model: sonnet
  fixer:
    agent: claude
    model: opus
```

Each role must name an explicit harness: `auto` and an omitted `agent` are both refused at config load.
Every configured role agent is subject to the neutralization rule above as well, so pinning a non-neutralizing harness to `reviewer` or `fixer` fails a run in such a repository exactly as a non-neutralizing top-level `agent` does, even when that top-level `agent` is one of the three.
The split reaches no further than Review.
Rebase, test, lint, document, PR, and CI all run on the top-level `agent` and its `agent_config`, so that remains the choice that has to carry every other step.
A firstmate crew-dispatch policy that splits a strong implementation model from a cheaper review model is therefore mirrored across a validation run's review and review-fix turns, not across the whole pipeline.

The [cortex harness reference](../.agents/skills/harness-adapters/references/harness/cortex.md) owns how firstmate's own crew adapters handle model and effort for Cortex, and the rest of that adapter's operating detail.

## Verify the result instead of assuming it

Run `no-mistakes doctor`.
For an ACP setup it should show `acpx` found with its resolved path, and a gate validation line naming your chosen agent as runnable.
Read that line narrowly: for an `acp:` agent it reports that `acpx` was found, not that your target resolves, and a made-up target with no `acp_registry_overrides` entry still reports runnable.
It does not clear the repository-dependent refusal above either, so confirm the target repository does not set `disable_project_settings` before relying on any gate agent, or any resolvable fallback-list entry, other than `codex`, `claude`, or `pi`.

The one-shot prompt below is what proves the bridge, so spend one before trusting it with a real run:

```
acpx --agent "<your-cortex-path> acp serve" --approve-all --format text exec "Reply with the single word: ok"
```

A run that initializes, opens a session, answers, and ends its turn proves the bridge end to end.
Only then start a validation run.

## Troubleshooting

**The bridge is not found even though it works in your shell.**
The gate runs from a background daemon, which need not see the `PATH` your interactive shell builds, so a binary under a version manager's shim directory can be invisible to it.
Give absolute paths in `acpx_path` and in every `acp_registry_overrides` command.

**A run is refused for not neutralizing project instructions, but the agent it names is one of the three that can.**
With an ordered `agent:` list in a repository carrying the opt-in, the refusal names the first entry rather than the offending one: a `[claude, "acp:cortex"]` list was refused as `gate agent "claude" does not neutralize ...`, the entry actually responsible was never named, and `no-mistakes doctor` reported that same `claude` runnable.
Check every entry in the configured list, not the agent the message names.
A `review_agents` role agent triggers the same refusal, but there the message identifies it: `agent: claude` with `review_agents.reviewer.agent: "acp:cortex"` failed before the first step as `create review_agents.reviewer: gate agent "acp:cortex" does not neutralize ...`, naming the role and the offending agent.

**A one-shot check fails with no session found.**
`acpx`'s bare prompt form expects an existing session for that agent and exits without prompting when it finds none.
Use the `exec` subcommand for a config-free check, as in the command above: it creates its own session for the single turn.
