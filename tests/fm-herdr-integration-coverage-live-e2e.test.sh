#!/usr/bin/env bash
# Default-on live guard for Herdr's reported integration coverage.
#
# Whether Herdr's agent read can see a given harness is a vendor-supplied fact
# that no fixture can prove: the fake in tests/fm-cortex-harness.test.sh can only
# confirm the assumption already written into the fake. This guard measures the
# real installed binary instead, and fails naming the harness and the Herdr
# version rather than degrading quietly.
#
# What it pins:
#   1. The coverage read yields a non-empty set from the REAL binary, so the
#      adapter never silently falls back to "coverage unreadable" (which makes
#      every agent read refuse) because the surface it parses moved.
#   2. Every harness family firstmate can dispatch is classified either covered
#      or not covered - never left unaccounted for.
#   3. The set actually diverges: at least one family covered AND at least one
#      not. A guard that saw only one side would pass vacuously if the parse
#      collapsed to empty or to everything.
#   4. The families this repo's verification records name as uncovered are still
#      uncovered, and the ones it names as covered are still covered, so a Herdr
#      release that changes either direction surfaces here instead of silently
#      changing recovery behavior.
#
# A run reads only `integration status` and the `integration list` usage text.
# Both are read-only and session-independent - they inspect the installed build
# and the harness-side hook paths, never a server, a session, a workspace, or a
# pane - so no Herdr lifecycle operation is involved and no prompt is submitted.
# The shared live gate therefore runs it by default wherever its tools exist.
# Run it after every Herdr upgrade and before trusting a refreshed
# docs/verification/cortex.md or docs/verification/rovo.md coverage claim.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

fm_live_gate default-on FM_HERDR_INTEGRATION_COVERAGE_LIVE_E2E herdr jq

# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

VERSION=$(herdr --version 2>/dev/null | head -1)
[ -n "$VERSION" ] || VERSION="herdr version unknown"

# 1. The real binary must yield a coverage set at all.
NAMES=$(fm_backend_herdr_integration_names)
[ -n "$NAMES" ] || fail "$VERSION reported no integration coverage at all; the adapter would refuse every agent read (check 'herdr integration status' output shape)"
pass "coverage reads from the real binary ($VERSION): $(printf '%s' "$NAMES" | tr '\n' ' ')"

# 2. Every dispatchable harness family must be classified, never unaccounted for.
# This list is the families bin/fm-control-lib.sh's fm_control_harness_family can
# return, which is what a task's recorded harness normalizes to.
FAMILIES="pi pi-signed omp claude cortex codex opencode grok kimi cursor gemini muse rovo"
COVERED=
UNCOVERED=
for fam in $FAMILIES; do
  fm_backend_herdr_integration_covers "$fam"
  case $? in
    0) COVERED="$COVERED $fam" ;;
    1) UNCOVERED="$UNCOVERED $fam" ;;
    *) fail "$VERSION left harness family '$fam' unclassified; coverage must be readable for every dispatchable family" ;;
  esac
done
pass "every dispatchable harness family is classified (covered:${COVERED:- none}; not covered:${UNCOVERED:- none})"

# 3. Divergence, so neither direction can pass vacuously.
[ -n "$COVERED" ] \
  || fail "$VERSION classified NO family as covered; a collapsed parse would make every agent read refuse"
[ -n "$UNCOVERED" ] \
  || fail "$VERSION classified EVERY family as covered; a collapsed parse would restore the blind read this guard exists to prevent"
pass "the covered set diverges, so neither verdict is vacuous"

# 4. The specific claims this repo's verification records rest on.
# A change on either side is a real finding, not a test to relax: it changes
# whether firstmate may act on an agent read for that harness.
for fam in cortex rovo muse gemini; do
  case " $UNCOVERED " in
    *" $fam "*) : ;;
    *) fail "$VERSION now reports an integration for '$fam'; that is a real behavior change - refresh docs/verification/cortex.md and rovo.md, which record it as uncovered" ;;
  esac
done
for fam in claude codex pi pi-signed opencode cursor grok kimi omp; do
  case " $COVERED " in
    *" $fam "*) : ;;
    *) fail "$VERSION no longer reports an integration covering '$fam'; its agent reads will now refuse, so recovery for that harness changes - confirm against Herdr's release notes before relaxing this" ;;
  esac
done
pass "the recorded per-harness coverage claims still hold on $VERSION"
