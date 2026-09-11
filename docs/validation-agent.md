# Validation agent selection

This page owns which agent the no-mistakes validation gate uses, and how to change it.
It exists because that choice is a separate setting from firstmate's own crew harness, and operators reasonably assume the two move together.

## The gate resolves its own agent

no-mistakes runs the validation pipeline, so the reviewer, fixer, and test agent inside a validation run are all whatever no-mistakes resolved for itself.
It reads that from its own configuration and never from firstmate's crew settings.

Switching crews to a harness therefore does NOT switch the validation gate.
`config/crew-harness`, a per-spawn harness, and every `config/crew-dispatch.json` profile govern the workers firstmate launches; see [`configuration.md`](configuration.md) for those settings.
None of them reaches the gate.
Until you change the gate's own setting, code written by a crew on one tool is validated and fixed by a different tool, on a different account.

The machine-wide setting lives in no-mistakes' global `config.yaml`, in the data directory `no-mistakes doctor` prints.
A repository can pin `agent` in its own `.no-mistakes.yaml` instead, which is how a repository binds its gate agent to itself rather than to whichever machine happens to push it.
That pin is trusted-only: no-mistakes reads `agent` and `commands` from the default-branch copy of the file, not from the copy on the pushed branch, unless the default-branch copy sets `allow_repo_commands`.
Model and effort stay machine-wide either way - `agent_config`, `agent_path_override`, and `agent_args_override` are marked global-only in the config's own comments.

## Pointing the gate at a natively supported harness

Set `agent:` to the harness name.
`no-mistakes doctor` lists the names it supports natively under `Agents`, and the config's own comment carries the current accepted values alongside `auto`.
`auto` picks the first available native agent or ACP alias on the system, which is convenient and non-deterministic; name the harness when you care which one runs.

## Pointing the gate at a harness no-mistakes cannot drive natively

Use the `acp:<target>` agent form.
Both sides of that bridge speak the Agent Client Protocol, and `acpx` is the piece in the middle: a headless ACP client that drives an ACP agent over stdio, so no-mistakes can use a tool it has no native integration for.
`acpx` is user-installed and is a hard requirement for this setup rather than an optional extra - `no-mistakes doctor` lists it under `Agents` and reports it not found until you install it.

Three keys make an ACP target work:

- `agent: acp:<target>` selects it.
- `acpx_path` points at the installed `acpx` binary.
- `acp_registry_overrides` maps `<target>` to the command that starts that tool as an ACP agent.

A target name is yours to choose; it is meaningful only as the key `acp_registry_overrides` resolves.

### The ACP bridge is refused in a repository carrying agent instructions

An `acp:<target>` gate agent cannot validate a repository that carries `AGENTS.md` or `CLAUDE.md`.
no-mistakes refuses to launch it there because it cannot prove it can suppress those project instructions for an ACP-bridged agent, and a validation agent reading the project's own agent instructions is not a validation agent.
Only `codex`, `claude`, and `pi` carry a verified neutralization knob, and only while `agent_args_override` does not replace it.

The refusal arrives as a failed run before the first step, naming the gate agent and the instruction files it will not neutralize.
`no-mistakes doctor` does NOT catch this, because the refusal depends on the repository being validated while doctor answers only whether the agent is runnable at all.
A doctor line reporting your `acp:` agent runnable is therefore compatible with every run in such a repository failing.

firstmate's own repository carries both files, so validating firstmate through the ACP bridge is not available.
Where that leaves a single-vendor setup is a real tradeoff: a repository with agent instructions can run its crews on an ACP-bridged tool, but its validation gate has to be one of the three natively neutralizing agents.

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

Quote `"acp:cortex"` as an `agent_config` key, because the colon is YAML syntax otherwise.

## Model and reasoning effort

`agent_config` is where a model and reasoning effort are pinned, in one common spelling that no-mistakes maps down to whatever the selected harness actually accepts.
On the ACP path that mapping is `acpx --model`, so the model is the knob that reliably lands there; the config's own comment is the current owner of the per-harness mapping and of the accepted effort levels.
A harness rejects any effort level it does not implement, so verify a pin rather than assuming it was honored.

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
The split reaches no further than Review.
Rebase, test, lint, document, PR, and CI all run on the top-level `agent` and its `agent_config`, so that remains the choice that has to carry every other step.
A firstmate crew-dispatch policy that splits a strong implementation model from a cheaper review model is therefore mirrored across a validation run's review and review-fix turns, not across the whole pipeline.

Cortex has no `xhigh`, so the shared cap rule maps `xhigh` onto `high` there.
The [cortex harness reference](../.agents/skills/harness-adapters/references/harness/cortex.md) owns that fact and the rest of the adapter's operating detail.

## Verify the result instead of assuming it

Run `no-mistakes doctor`.
For an ACP setup it should show `acpx` found with its resolved path, and a gate validation line naming your chosen agent as runnable.
A configuration that parses is not evidence the bridge works; that line is.
That line does not clear the repository-dependent refusal above, so confirm the target repository carries no `AGENTS.md` or `CLAUDE.md` before relying on an `acp:` gate agent for it.

Then spend one one-shot prompt through the bridge before trusting it with a real run:

```
acpx --agent "<your-cortex-path> acp serve" --approve-all --format text exec "Reply with the single word: ok"
```

A run that initializes, opens a session, answers, and ends its turn proves the bridge end to end.
Only then start a validation run.

## Troubleshooting

**The bridge is not found even though it works in your shell.**
The gate runs from a background daemon, which need not see the `PATH` your interactive shell builds, so a binary under a version manager's shim directory can be invisible to it.
Give absolute paths in `acpx_path` and in every `acp_registry_overrides` command.

**A one-shot check fails with no session found.**
`acpx`'s bare prompt form expects an existing session for that agent and exits without prompting when it finds none.
Use the `exec` subcommand for a config-free check, as in the command above: it creates its own session for the single turn.
