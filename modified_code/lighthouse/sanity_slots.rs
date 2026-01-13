//! # Sanity Slots
//!
//! Use this tool to process a `BeaconState` through a specified number of slots.
//! This matches the official test runner's sanity_slots test case behavior.
//!
//! ## Examples
//!
//! Process a state through 64 slots:
//!
//! ```ignore
//! lcli sanity-slots \
//!     --pre-state-path /path/to/pre.ssz \
//!     --slots 64 \
//!     --post-state-output-path /path/to/post.ssz
//! ```
use crate::transition_blocks::load_from_ssz_with;
use clap::ArgMatches;
use clap_utils::parse_required;
use environment::Environment;
use eth2_network_config::Eth2NetworkConfig;
use ssz::Encode;
use state_processing::per_slot_processing;
use std::fs::File;
use std::io::prelude::*;
use std::path::PathBuf;
use tracing::info;
use types::{BeaconState, EthSpec};

pub fn run<E: EthSpec>(
    env: Environment<E>,
    network_config: Eth2NetworkConfig,
    matches: &ArgMatches,
) -> Result<(), String> {
    let spec = &network_config.chain_spec::<E>()?;
    let _executor = env.core_context().executor;

    let pre_state_path: PathBuf = parse_required(matches, "pre-state-path")?;
    let slots: u64 = parse_required(matches, "slots")?;
    let post_state_output_path: PathBuf = parse_required(matches, "post-state-output-path")?;

    info!("Using {} spec", E::spec_name());
    info!("Processing {} slots", slots);
    info!("Pre-state path: {:?}", pre_state_path);
    info!("Post-state output path: {:?}", post_state_output_path);

    // Load pre-state
    let mut state: BeaconState<E> = load_from_ssz_with(&pre_state_path, spec, BeaconState::from_ssz_bytes)?;

    // Build caches (required for processing, same as official test runner)
    state
        .build_caches(spec)
        .map_err(|e| format!("Unable to build caches: {:?}", e))?;

    // Process slots (same logic as sanity_slots.rs test case)
    (0..slots)
        .try_for_each(|_| per_slot_processing(&mut state, None, spec).map(|_| ()))
        .map_err(|e| format!("Failed to process slots: {:?}", e))?;

    // Write post-state to file
    let mut output_file = File::create(&post_state_output_path)
        .map_err(|e| format!("Unable to create output file: {:?}", e))?;

    output_file
        .write_all(&state.as_ssz_bytes())
        .map_err(|e| format!("Unable to write to output file: {:?}", e))?;

    info!("Successfully processed {} slots and saved post-state", slots);
    Ok(())
}

