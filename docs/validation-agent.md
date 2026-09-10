# Validation agent selection

This page owns which agent the no-mistakes validation gate uses, and how to change it.
It exists because that choice is a separate setting from firstmate's own crew harness, and operators reasonably assume the two move together.

## The gate resolves its own agent

no-mistakes runs the validation pipeline, so the reviewer, fixer, and test agent inside a validation run are all whatever no-mistakes resolved for itself.
It reads that from its own global configuration and never from firstmate's.

Switching crews to a harness therefore does NOT switch the validation gate.
`config/crew-harness`, a per-spawn harness, and every `config/crew-dispatch.json` profile govern the workers firstmate launches; see [`configuration.md`](configuration.md) for those settings.
None of them reaches the gate.
Until you change the gate's own setting, code written by a crew on one tool is validated and fixed by a different tool, on a different account.

The gate's setting lives in no-mistakes' global `config.yaml`, in the data directory `no-mistakes doctor` prints.
The whole selection is global: a repository's own `.no-mistakes.yaml` does not choose the agent.

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

## Model and reasoning effort, and the one-configuration limit

`agent_config` is where a model and reasoning effort are pinned, in one common spelling that no-mistakes maps down to whatever the selected harness actually accepts.
On the ACP path that mapping is `acpx --model`, so the model is the knob that reliably lands there; the config's own comment is the current owner of the per-harness mapping and of the accepted effort levels.
A harness rejects any effort level it does not implement, so verify a pin rather than assuming it was honored.

no-mistakes applies ONE agent configuration to a whole validation run.
There is no per-step split, so a validation run cannot use one model to fix and another to review.
A firstmate crew-dispatch policy that deliberately splits models - a strong model for implementation and a cheaper one for review, for instance - cannot be mirrored inside a validation run.
Choose the single model that has to carry every step of the run, including review and auto-fix.

Cortex's effort levels stop below firstmate's shared `xhigh`, so `xhigh` maps onto `high` there.
The [cortex harness reference](../.agents/skills/harness-adapters/references/harness/cortex.md) owns that fact and the rest of the adapter's operating detail.

## Verify the result instead of assuming it

Run `no-mistakes doctor`.
For an ACP setup it should show `acpx` found with its resolved path, and a gate validation line naming your chosen agent as runnable.
A configuration that parses is not evidence the bridge works; that line is.

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
