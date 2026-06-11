//! # Process Epoch Operations
//!
//! Process epoch operations (justification_and_finalization, rewards_and_penalties, etc.) on a beacon state.

use crate::transition_blocks::load_from_ssz_with;
use clap::ArgMatches;
use clap_utils::parse_required;
use environment::Environment;
use eth2_network_config::Eth2NetworkConfig;
use ssz::Encode;
use state_processing::{
    common::update_progressive_balances_cache::initialize_progressive_balances_cache,
    epoch_cache::initialize_epoch_cache,
    per_epoch_processing::capella::process_historical_summaries_update,
    per_epoch_processing::effective_balance_updates::{
        process_effective_balance_updates, process_effective_balance_updates_slow,
    },
    per_epoch_processing::{
        altair, base,
        historical_roots_update::process_historical_roots_update,
        process_registry_updates, process_registry_updates_slow, process_slashings,
        process_slashings_slow,
        resets::{process_eth1_data_reset, process_randao_mixes_reset, process_slashings_reset},
        single_pass::{process_epoch_single_pass, SinglePassConfig},
    },
};
use std::fs::File;
use std::io::prelude::*;
use std::path::PathBuf;
use std::sync::Arc;
use tracing::info;
use types::{BeaconState, ChainSpec, EthSpec};

pub fn run<E: EthSpec>(
    _env: Environment<E>,
    network_config: Eth2NetworkConfig,
    matches: &ArgMatches,
) -> Result<(), String> {
    let spec = Arc::new(network_config.chain_spec::<E>()?);

    let epoch_processing_type: String = parse_required(matches, "epoch-processing-type")?;
    let pre_state_path: PathBuf = parse_required(matches, "pre-state-path")?;
    let post_state_output_path: PathBuf = parse_required(matches, "post-state-output-path")?;

    info!("Processing epoch operation: {}", epoch_processing_type);
    info!("Pre-state path: {:?}", pre_state_path);
    info!("Post-state output path: {:?}", post_state_output_path);

    // Load pre-state
    let mut pre_state: BeaconState<E> =
        load_from_ssz_with(&pre_state_path, &spec, BeaconState::from_ssz_bytes)?;

    // Build committee caches (required for epoch processing, same as official test runner)
    pre_state
        .build_all_committee_caches(&spec)
        .map_err(|e| format!("Failed to build committee caches: {:?}", e))?;

    // Process epoch operation based on type
    match epoch_processing_type.as_str() {
        "justification_and_finalization" => {
            process_justification_and_finalization(&mut pre_state, &spec)?
        }
        "rewards_and_penalties" => process_rewards_and_penalties(&mut pre_state, &spec)?,
        "registry_updates" => process_registry_updates_op(&mut pre_state, &spec)?,
        "slashings" => process_slashings_op(&mut pre_state, &spec)?,
        "eth1_data_reset" => process_eth1_data_reset_op(&mut pre_state, &spec)?,
        "effective_balance_updates" => process_effective_balance_updates_op(&mut pre_state, &spec)?,
        "slashings_reset" => process_slashings_reset_op(&mut pre_state, &spec)?,
        "randao_mixes_reset" => process_randao_mixes_reset_op(&mut pre_state, &spec)?,
        "historical_summaries_update" => {
            process_historical_summaries_update_op(&mut pre_state, &spec)?
        }
        "historical_roots_update" => process_historical_roots_update_op(&mut pre_state, &spec)?,
        "participation_record_updates" => {
            process_participation_record_updates(&mut pre_state, &spec)?
        }
        "participation_flag_updates" => process_participation_flag_updates(&mut pre_state, &spec)?,
        "pending_deposits" => process_pending_deposits(&mut pre_state, &spec)?,
        "pending_consolidations" => process_pending_consolidations(&mut pre_state, &spec)?,
        "inactivity_updates" => process_inactivity_updates(&mut pre_state, &spec)?,
        _ => {
            return Err(format!(
                "Unknown epoch processing type: {}",
                epoch_processing_type
            ))
        }
    }

    // Save post-state
    let post_state_bytes = pre_state.as_ssz_bytes();
    let mut file = File::create(&post_state_output_path)
        .map_err(|e| format!("Failed to create output file: {:?}", e))?;
    file.write_all(&post_state_bytes)
        .map_err(|e| format!("Failed to write output file: {:?}", e))?;

    info!(
        "Epoch processing completed successfully. Post state written to {:?}",
        post_state_output_path
    );
    Ok(())
}

fn process_justification_and_finalization<E: EthSpec>(
    state: &mut BeaconState<E>,
    spec: &ChainSpec,
) -> Result<(), String> {
    if state.fork_name_unchecked().altair_enabled() {
        // Same as official test runner: only initialize_progressive_balances_cache
        initialize_progressive_balances_cache(state, spec)
            .map_err(|e| format!("Failed to initialize progressive balances cache: {:?}", e))?;
        let justification_and_finalization_state =
            altair::process_justification_and_finalization(state).map_err(|e| {
                format!("Failed to process justification and finalization: {:?}", e)
            })?;
        justification_and_finalization_state.apply_changes_to_state(state);
    } else {
        let mut validator_statuses = base::ValidatorStatuses::new(state, spec)
            .map_err(|e| format!("Failed to create validator statuses: {:?}", e))?;
        validator_statuses
            .process_attestations(state)
            .map_err(|e| format!("Failed to process attestations: {:?}", e))?;
        let justification_and_finalization_state = base::process_justification_and_finalization(
            state,
            &validator_statuses.total_balances,
            spec,
        )
        .map_err(|e| format!("Failed to process justification and finalization: {:?}", e))?;
        justification_and_finalization_state.apply_changes_to_state(state);
    }
    Ok(())
}

fn process_rewards_and_penalties<E: EthSpec>(
    state: &mut BeaconState<E>,
    spec: &ChainSpec,
) -> Result<(), String> {
    if state.fork_name_unchecked().altair_enabled() {
        altair::process_rewards_and_penalties_slow(state, spec)
            .map_err(|e| format!("Failed to process rewards and penalties: {:?}", e))?;
    } else {
        let mut validator_statuses = base::ValidatorStatuses::new(state, spec)
            .map_err(|e| format!("Failed to create validator statuses: {:?}", e))?;
        validator_statuses
            .process_attestations(state)
            .map_err(|e| format!("Failed to process attestations: {:?}", e))?;
        base::process_rewards_and_penalties(state, &validator_statuses, spec)
            .map_err(|e| format!("Failed to process rewards and penalties: {:?}", e))?;
    }
    Ok(())
}

fn process_registry_updates_op<E: EthSpec>(
    state: &mut BeaconState<E>,
    spec: &ChainSpec,
) -> Result<(), String> {
    initialize_epoch_cache(state, spec)
        .map_err(|e| format!("Failed to initialize epoch cache: {:?}", e))?;
    match state {
        BeaconState::Base(_) => {
            process_registry_updates(state, spec)
                .map_err(|e| format!("Failed to process registry updates: {:?}", e))?;
        }
        _ => {
            process_registry_updates_slow(state, spec)
                .map_err(|e| format!("Failed to process registry updates: {:?}", e))?;
        }
    }
    Ok(())
}

fn process_slashings_op<E: EthSpec>(
    state: &mut BeaconState<E>,
    spec: &ChainSpec,
) -> Result<(), String> {
    if state.fork_name_unchecked().altair_enabled() {
        process_slashings_slow(state, spec)
            .map_err(|e| format!("Failed to process slashings: {:?}", e))?;
    } else {
        let mut validator_statuses = base::ValidatorStatuses::new(state, spec)
            .map_err(|e| format!("Failed to create validator statuses: {:?}", e))?;
        validator_statuses
            .process_attestations(state)
            .map_err(|e| format!("Failed to process attestations: {:?}", e))?;
        process_slashings(
            state,
            validator_statuses.total_balances.current_epoch(),
            spec,
        )
        .map_err(|e| format!("Failed to process slashings: {:?}", e))?;
    }
    Ok(())
}

fn process_eth1_data_reset_op<E: EthSpec>(
    state: &mut BeaconState<E>,
    _spec: &ChainSpec,
) -> Result<(), String> {
    process_eth1_data_reset(state)
        .map_err(|e| format!("Failed to process eth1 data reset: {:?}", e))?;
    Ok(())
}

fn process_effective_balance_updates_op<E: EthSpec>(
    state: &mut BeaconState<E>,
    spec: &ChainSpec,
) -> Result<(), String> {
    match state {
        BeaconState::Base(_) => {
            process_effective_balance_updates(state, spec)
                .map_err(|e| format!("Failed to process effective balance updates: {:?}", e))?;
        }
        _ => {
            process_effective_balance_updates_slow(state, spec)
                .map_err(|e| format!("Failed to process effective balance updates: {:?}", e))?;
        }
    }
    Ok(())
}

fn process_slashings_reset_op<E: EthSpec>(
    state: &mut BeaconState<E>,
    _spec: &ChainSpec,
) -> Result<(), String> {
    process_slashings_reset(state)
        .map_err(|e| format!("Failed to process slashings reset: {:?}", e))?;
    Ok(())
}

fn process_randao_mixes_reset_op<E: EthSpec>(
    state: &mut BeaconState<E>,
    _spec: &ChainSpec,
) -> Result<(), String> {
    process_randao_mixes_reset(state)
        .map_err(|e| format!("Failed to process randao mixes reset: {:?}", e))?;
    Ok(())
}

fn process_historical_summaries_update_op<E: EthSpec>(
    state: &mut BeaconState<E>,
    _spec: &ChainSpec,
) -> Result<(), String> {
    if state.fork_name_unchecked().capella_enabled() {
        process_historical_summaries_update(state)
            .map_err(|e| format!("Failed to process historical summaries update: {:?}", e))?;
    }
    Ok(())
}

fn process_historical_roots_update_op<E: EthSpec>(
    state: &mut BeaconState<E>,
    _spec: &ChainSpec,
) -> Result<(), String> {
    process_historical_roots_update(state)
        .map_err(|e| format!("Failed to process historical roots update: {:?}", e))?;
    Ok(())
}

fn process_participation_record_updates<E: EthSpec>(
    state: &mut BeaconState<E>,
    _spec: &ChainSpec,
) -> Result<(), String> {
    base::process_participation_record_updates(state)
        .map_err(|e| format!("Failed to process participation record updates: {:?}", e))?;
    Ok(())
}

fn process_participation_flag_updates<E: EthSpec>(
    state: &mut BeaconState<E>,
    _spec: &ChainSpec,
) -> Result<(), String> {
    if state.fork_name_unchecked().altair_enabled() {
        altair::process_participation_flag_updates(state)
            .map_err(|e| format!("Failed to process participation flag updates: {:?}", e))?;
    }
    Ok(())
}

fn process_inactivity_updates<E: EthSpec>(
    state: &mut BeaconState<E>,
    spec: &ChainSpec,
) -> Result<(), String> {
    if state.fork_name_unchecked().altair_enabled() {
        altair::process_inactivity_updates_slow(state, spec)
            .map_err(|e| format!("Failed to process inactivity updates: {:?}", e))?;
    }
    Ok(())
}

fn process_pending_deposits<E: EthSpec>(
    state: &mut BeaconState<E>,
    spec: &ChainSpec,
) -> Result<(), String> {
    process_epoch_single_pass(
        state,
        spec,
        SinglePassConfig {
            pending_deposits: true,
            ..SinglePassConfig::disable_all()
        },
    )
    .map_err(|e| format!("Failed to process pending deposits: {:?}", e))?;
    Ok(())
}

fn process_pending_consolidations<E: EthSpec>(
    state: &mut BeaconState<E>,
    spec: &ChainSpec,
) -> Result<(), String> {
    process_epoch_single_pass(
        state,
        spec,
        SinglePassConfig {
            pending_consolidations: true,
            ..SinglePassConfig::disable_all()
        },
    )
    .map_err(|e| format!("Failed to process pending consolidations: {:?}", e))?;
    Ok(())
}
