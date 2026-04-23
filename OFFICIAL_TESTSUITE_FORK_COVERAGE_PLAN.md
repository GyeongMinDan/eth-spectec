# OfficialTestSuite Fork Coverage Plan

## Goal

Measure cumulative state-transition coverage from official Ethereum consensus
test vectors only. The target suites are:

- `sanity/blocks`
- `random`
- `finality`

The target forks are:

- `phase0`
- `altair`
- `bellatrix`
- `capella`
- `deneb`
- `electra`

The target clients are Lighthouse, Prysm, Nimbus, Teku, and Lodestar. The
coverage run uses `diff_testing.py --test-type state-transition --workflow
sequential --enable-coverage`.

## Scope

In scope:

- Run `Converter/OfficialTestSuite/<fork>/{sanity/blocks,random,finality}`.
- Keep existing post-state output, status, time, and SSZ-diff behavior.
- Accumulate coverage per suite, per fork, and across all forks.
- Extend client wrapper/config handling so each fork can be selected explicitly.

Out of scope for this pass:

- Operation, epoch-processing, and sanity-slots coverage expansion.
- Eth2SpecTec-generated tests.
- Fulu/Gloas or any fork after Electra.

## Design

### Single Fork Profile Source

`fork_profiles.py` is the single source of truth for fork-specific runtime
settings:

- CLI-supported fork names.
- Lighthouse pure testnet config path.
- Teku `--Xnetwork-*-fork-epoch` arguments.
- Lodestar `--fork-version` value.
- Nimbus `FORK_VERSION` value.
- Prysm `--fork-version` value.

`diff_testing.py` should not contain `if fork_version == "deneb" else capella`
logic for state-transition clients. It should call `get_fork_profile()` and use
the profile fields.

### Pure Testnet Configs

Existing checked-in configs are preserved for `capella` and `deneb`. Missing
fork configs are generated from the existing Lighthouse config template into:

`Converter/_generated_pure_configs/pure_<fork>_configs/lighthouse_testnet`

Generated configs set prior/current fork epochs according to the profile and
future forks to a far-future epoch. This keeps the checkout small and makes fork
epoch changes auditable in one table.

### Client Contracts

State-transition execution uses these contracts:

- Lighthouse receives `--testnet-dir <profile lighthouse_testnet_dir>`.
- Teku receives fork epoch CLI arguments generated from the profile.
- Lodestar receives `--fork-version=<profile lodestar_fork_version>`.
- Nimbus receives `FORK_VERSION=<profile nimbus_fork_version>`.
- Prysm receives `--fork-version=<profile prysm_fork_version>`.

The modified client wrappers must parse these values and select the correct
state/block SSZ type and pure fork schedule.

### Coverage Aggregation

For each fork and suite, `diff_testing.py` already writes a suite-level
`total-node-coverage` report. The all-fork runner then calls
`diff_testing.py --generate-final-coverage` over every suite output directory to
produce the final cumulative coverage report.

## Implementation Phases

1. Add fork profiles and route state-transition client execution through them.
2. Preserve capella/deneb behavior while expanding CLI choices to all target
   forks.
3. Extend modified client wrappers so state-transition can load phase0 through
   electra SSZ.
4. Add an OfficialTestSuite-only coverage runner for all forks and three suites.
5. Validate with static checks first, then one small smoke case per fork when
   clients are built.
6. Run the full sequential coverage pipeline and inspect the final accumulated
   reports.

## Acceptance Criteria

- `python3 diff_testing.py --help` lists all target forks.
- `diff_testing.py --test-suite ... --fork-version <fork>` uses fork-specific
  Lighthouse/Teku/Lodestar/Nimbus/Prysm settings.
- Unsupported fork names fail before client execution with a clear message.
- Existing capella/deneb commands keep their old output shape.
- `run_officialtestsuite_fork_coverage.sh` can run the three OfficialTestSuite
  suites per fork and produce an all-fork final accumulated coverage directory.

## Current Validation Notes

Static checks completed:

- `python3 -m py_compile fork_profiles.py diff_testing.py Converter/eth2specResult.py`
- `bash -n build_coverage_clients.sh`
- `bash -n run_officialtestsuite_fork_coverage.sh`
- Prysm `go test ./tools/pcli -run TestDoesNotExist`
- Lodestar `node --check testing_clients/lodestar/transition.js`

Coverage-mode empty-block smoke tests completed successfully for:

- `phase0`
- `altair`
- `bellatrix`
- `capella`
- `deneb`
- `electra`

Each successful smoke ran Lighthouse, Prysm, Nimbus, Teku, Lodestar, and
Eth2spec and produced `total-node-coverage` reports.

Electra note:

- The previous local Electra vectors decoded as Fulu-shaped states. After
  replacing them with regenerated Electra vectors, `eth2spec.electra` decoding
  and the coverage-mode empty-block smoke test both pass.
