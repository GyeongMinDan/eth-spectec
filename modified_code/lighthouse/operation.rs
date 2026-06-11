//! # Process Operations
//!
//! Process individual operations (attestation, block_header, deposit, etc.) on a beacon state.

use crate::transition_blocks::load_from_ssz_with;
use clap::ArgMatches;
use clap_utils::parse_required;
use environment::Environment;
use eth2_network_config::Eth2NetworkConfig;
use ssz::{Decode, Encode};
use state_processing::per_block_processing::errors::BlockProcessingError;
use state_processing::{
    common::update_progressive_balances_cache::initialize_progressive_balances_cache,
    epoch_cache::initialize_epoch_cache,
    per_block_processing::{
        process_block_header,
        process_operations::{
            altair_deneb, base, process_attester_slashings, process_bls_to_execution_changes,
            process_consolidation_requests, process_deposit_requests, process_deposits,
            process_exits, process_proposer_slashings, process_withdrawal_requests,
        },
        process_sync_aggregate, process_withdrawals, VerifyBlockRoot, VerifySignatures,
    },
    ConsensusContext,
};
use std::fs::File;
use std::io::prelude::*;
use std::path::PathBuf;
use std::sync::Arc;
use tracing::info;
use types::{
    Attestation, AttesterSlashing, BeaconBlock, BeaconBlockBody, BeaconBlockBodyBellatrix,
    BeaconBlockBodyCapella, BeaconBlockBodyDeneb, BeaconBlockBodyElectra, BeaconState, ChainSpec,
    ConsolidationRequest, Deposit, DepositRequest, EthSpec, ExecutionPayload, ForkName,
    ForkVersionDecode, FullPayload, ProposerSlashing, SignedBlsToExecutionChange,
    SignedVoluntaryExit, SyncAggregate, WithdrawalRequest,
};

pub fn run<E: EthSpec>(
    _env: Environment<E>,
    network_config: Eth2NetworkConfig,
    matches: &ArgMatches,
) -> Result<(), String> {
    let spec = Arc::new(network_config.chain_spec::<E>()?);

    let operation_type: String = parse_required(matches, "operation-type")?;
    let pre_state_path: PathBuf = parse_required(matches, "pre-state-path")?;
    let operation_path: PathBuf = parse_required(matches, "operation-path")?;
    let post_state_output_path: PathBuf = parse_required(matches, "post-state-output-path")?;

    info!("Processing operation: {}", operation_type);
    info!("Pre-state path: {:?}", pre_state_path);
    info!("Operation path: {:?}", operation_path);
    info!("Post-state output path: {:?}", post_state_output_path);

    // Load pre-state
    let mut pre_state: BeaconState<E> =
        load_from_ssz_with(&pre_state_path, &spec, BeaconState::from_ssz_bytes)?;

    // Build committee caches (required for operations, same as official test runner)
    // NOTE: withdrawals operation doesn't require committee caches (0 active validators case)
    if operation_type != "withdrawals" {
        pre_state
            .build_all_committee_caches(&spec)
            .map_err(|e| format!("Failed to build committee caches: {:?}", e))?;
    }

    // Process operation based on type
    match operation_type.as_str() {
        "attestation" => process_attestation(&mut pre_state, &operation_path, &spec)?,
        "block_header" => process_block_header_op(&mut pre_state, &operation_path, &spec)?,
        "deposit" => process_deposit(&mut pre_state, &operation_path, &spec)?,
        "proposer_slashing" => process_proposer_slashing(&mut pre_state, &operation_path, &spec)?,
        "attester_slashing" => process_attester_slashing(&mut pre_state, &operation_path, &spec)?,
        "voluntary_exit" => process_voluntary_exit(&mut pre_state, &operation_path, &spec)?,
        "bls_to_execution_change" => {
            process_bls_to_execution_change(&mut pre_state, &operation_path, &spec)?
        }
        "sync_committee" => process_sync_committee(&mut pre_state, &operation_path, &spec)?,
        "execution_payload" => {
            let execution_valid = matches
                .get_one::<String>("execution-valid")
                .map(|s| s == "true")
                .unwrap_or(true); // Default to true if not provided
            process_execution_payload(&mut pre_state, &operation_path, &spec, execution_valid)?;
        }
        "withdrawals" => process_withdrawals_op(&mut pre_state, &operation_path, &spec)?,
        "deposit_request" => process_deposit_request(&mut pre_state, &operation_path, &spec)?,
        "withdrawal_request" => process_withdrawal_request(&mut pre_state, &operation_path, &spec)?,
        "consolidation_request" => {
            process_consolidation_request(&mut pre_state, &operation_path, &spec)?
        }
        _ => return Err(format!("Unknown operation type: {}", operation_type)),
    }

    // Save post-state
    let post_state_bytes = pre_state.as_ssz_bytes();
    let mut file = File::create(&post_state_output_path)
        .map_err(|e| format!("Failed to create output file: {:?}", e))?;
    file.write_all(&post_state_bytes)
        .map_err(|e| format!("Failed to write output file: {:?}", e))?;

    info!(
        "Operation processed successfully. Post state written to {:?}",
        post_state_output_path
    );
    Ok(())
}

fn process_attestation<E: EthSpec>(
    state: &mut BeaconState<E>,
    path: &PathBuf,
    spec: &ChainSpec,
) -> Result<(), String> {
    let fork_name = state.fork_name_unchecked();
    let attestation: Attestation<E> = load_from_ssz_with(path, spec, |bytes, _spec| {
        if fork_name < ForkName::Electra {
            Ok(Attestation::Base(Decode::from_ssz_bytes(bytes)?))
        } else {
            Ok(Attestation::Electra(Decode::from_ssz_bytes(bytes)?))
        }
    })?;
    initialize_epoch_cache(state, spec)
        .map_err(|e| format!("Failed to initialize epoch cache: {:?}", e))?;
    let mut ctxt = ConsensusContext::new(state.slot());
    if state.fork_name_unchecked().altair_enabled() {
        initialize_progressive_balances_cache(state, spec)
            .map_err(|e| format!("Failed to initialize progressive balances cache: {:?}", e))?;
        altair_deneb::process_attestation(
            state,
            attestation.to_ref(),
            0,
            &mut ctxt,
            VerifySignatures::True,
            spec,
        )
        .map_err(|e| format!("Failed to process attestation: {:?}", e))?;
    } else {
        base::process_attestations(
            state,
            [attestation.to_ref()].into_iter(),
            VerifySignatures::True,
            &mut ctxt,
            spec,
        )
        .map_err(|e| format!("Failed to process attestation: {:?}", e))?;
    }
    Ok(())
}

fn process_block_header_op<E: EthSpec>(
    state: &mut BeaconState<E>,
    path: &PathBuf,
    spec: &ChainSpec,
) -> Result<(), String> {
    let block: BeaconBlock<E> = load_from_ssz_with(path, spec, |bytes, spec| {
        BeaconBlock::from_ssz_bytes(bytes, spec)
    })?;
    let mut ctxt = ConsensusContext::new(state.slot());
    process_block_header(
        state,
        block.to_ref().temporary_block_header(),
        VerifyBlockRoot::True,
        &mut ctxt,
        spec,
    )
    .map_err(|e| format!("Failed to process block header: {:?}", e))?;
    Ok(())
}

fn process_deposit<E: EthSpec>(
    state: &mut BeaconState<E>,
    path: &PathBuf,
    spec: &ChainSpec,
) -> Result<(), String> {
    let deposit: Deposit = load_from_ssz_with(path, spec, |bytes, _spec| {
        Ok(Decode::from_ssz_bytes(bytes)?)
    })?;
    process_deposits(state, std::slice::from_ref(&deposit), spec)
        .map_err(|e| format!("Failed to process deposit: {:?}", e))?;
    Ok(())
}

fn process_proposer_slashing<E: EthSpec>(
    state: &mut BeaconState<E>,
    path: &PathBuf,
    spec: &ChainSpec,
) -> Result<(), String> {
    let slashing: ProposerSlashing = load_from_ssz_with(path, spec, |bytes, _spec| {
        Ok(Decode::from_ssz_bytes(bytes)?)
    })?;
    let mut ctxt = ConsensusContext::new(state.slot());
    initialize_progressive_balances_cache(state, spec)
        .map_err(|e| format!("Failed to initialize progressive balances cache: {:?}", e))?;
    process_proposer_slashings(
        state,
        std::slice::from_ref(&slashing),
        VerifySignatures::True,
        &mut ctxt,
        spec,
    )
    .map_err(|e| format!("Failed to process proposer slashing: {:?}", e))?;
    Ok(())
}

fn process_attester_slashing<E: EthSpec>(
    state: &mut BeaconState<E>,
    path: &PathBuf,
    spec: &ChainSpec,
) -> Result<(), String> {
    let fork_name = state.fork_name_unchecked();
    let slashing: AttesterSlashing<E> = load_from_ssz_with(path, spec, |bytes, _spec| {
        if fork_name.electra_enabled() {
            Ok(AttesterSlashing::Electra(Decode::from_ssz_bytes(bytes)?))
        } else {
            Ok(AttesterSlashing::Base(Decode::from_ssz_bytes(bytes)?))
        }
    })?;
    let mut ctxt = ConsensusContext::new(state.slot());
    initialize_progressive_balances_cache(state, spec)
        .map_err(|e| format!("Failed to initialize progressive balances cache: {:?}", e))?;
    process_attester_slashings(
        state,
        [slashing.to_ref()].into_iter(),
        VerifySignatures::True,
        &mut ctxt,
        spec,
    )
    .map_err(|e| format!("Failed to process attester slashing: {:?}", e))?;
    Ok(())
}

fn process_voluntary_exit<E: EthSpec>(
    state: &mut BeaconState<E>,
    path: &PathBuf,
    spec: &ChainSpec,
) -> Result<(), String> {
    let exit: SignedVoluntaryExit = load_from_ssz_with(path, spec, |bytes, _spec| {
        Ok(Decode::from_ssz_bytes(bytes)?)
    })?;
    process_exits(
        state,
        std::slice::from_ref(&exit),
        VerifySignatures::True,
        spec,
    )
    .map_err(|e| format!("Failed to process voluntary exit: {:?}", e))?;
    Ok(())
}

fn process_bls_to_execution_change<E: EthSpec>(
    state: &mut BeaconState<E>,
    path: &PathBuf,
    spec: &ChainSpec,
) -> Result<(), String> {
    let change: SignedBlsToExecutionChange = load_from_ssz_with(path, spec, |bytes, _spec| {
        Ok(Decode::from_ssz_bytes(bytes)?)
    })?;
    process_bls_to_execution_changes(
        state,
        std::slice::from_ref(&change),
        VerifySignatures::True,
        spec,
    )
    .map_err(|e| format!("Failed to process BLS to execution change: {:?}", e))?;
    Ok(())
}

fn process_sync_committee<E: EthSpec>(
    state: &mut BeaconState<E>,
    path: &PathBuf,
    spec: &ChainSpec,
) -> Result<(), String> {
    let sync_agg: SyncAggregate<E> = load_from_ssz_with(path, spec, |bytes, _spec| {
        Ok(Decode::from_ssz_bytes(bytes)?)
    })?;
    let proposer_index = state
        .get_beacon_proposer_index(state.slot(), spec)
        .map_err(|e| format!("Failed to get proposer index: {:?}", e))?
        as u64;
    process_sync_aggregate(
        state,
        &sync_agg,
        proposer_index,
        VerifySignatures::True,
        spec,
    )
    .map_err(|e| format!("Failed to process sync aggregate: {:?}", e))?;
    Ok(())
}

fn process_execution_payload<E: EthSpec>(
    state: &mut BeaconState<E>,
    path: &PathBuf,
    spec: &ChainSpec,
    execution_valid: bool,
) -> Result<(), String> {
    use state_processing::per_block_processing::process_execution_payload as process_payload;

    // If execution is invalid, return error immediately (matching official test runner behavior)
    if !execution_valid {
        return Err(format!("{:?}", BlockProcessingError::ExecutionInvalid));
    }

    let fork_name = state.fork_name_unchecked();
    let body: BeaconBlockBody<E, FullPayload<E>> =
        load_from_ssz_with(path, spec, |bytes, _spec| {
            Ok(match fork_name {
                ForkName::Bellatrix => BeaconBlockBody::Bellatrix(<BeaconBlockBodyBellatrix<
                    E,
                    FullPayload<E>,
                > as Decode>::from_ssz_bytes(
                    bytes
                )?),
                ForkName::Capella => BeaconBlockBody::Capella(<BeaconBlockBodyCapella<
                    E,
                    FullPayload<E>,
                > as Decode>::from_ssz_bytes(
                    bytes
                )?),
                ForkName::Deneb => BeaconBlockBody::Deneb(
                    <BeaconBlockBodyDeneb<E, FullPayload<E>> as Decode>::from_ssz_bytes(bytes)?,
                ),
                ForkName::Electra => BeaconBlockBody::Electra(<BeaconBlockBodyElectra<
                    E,
                    FullPayload<E>,
                > as Decode>::from_ssz_bytes(
                    bytes
                )?),
                _ => {
                    return Err(ssz::DecodeError::BytesInvalid(format!(
                        "Unsupported fork: {:?}",
                        fork_name
                    )))
                }
            })
        })?;

    process_payload::<E, FullPayload<E>>(state, body.to_ref(), spec)
        .map_err(|e| format!("Failed to process execution payload: {:?}", e))?;
    Ok(())
}

fn process_deposit_request<E: EthSpec>(
    state: &mut BeaconState<E>,
    path: &PathBuf,
    spec: &ChainSpec,
) -> Result<(), String> {
    let request: DepositRequest = load_from_ssz_with(path, spec, |bytes, _spec| {
        Ok(Decode::from_ssz_bytes(bytes)?)
    })?;
    process_deposit_requests(state, std::slice::from_ref(&request), spec)
        .map_err(|e| format!("Failed to process deposit request: {:?}", e))?;
    Ok(())
}

fn process_withdrawal_request<E: EthSpec>(
    state: &mut BeaconState<E>,
    path: &PathBuf,
    spec: &ChainSpec,
) -> Result<(), String> {
    let request: WithdrawalRequest = load_from_ssz_with(path, spec, |bytes, _spec| {
        Ok(Decode::from_ssz_bytes(bytes)?)
    })?;
    state
        .update_pubkey_cache()
        .map_err(|e| format!("Failed to update pubkey cache: {:?}", e))?;
    process_withdrawal_requests(state, std::slice::from_ref(&request), spec)
        .map_err(|e| format!("Failed to process withdrawal request: {:?}", e))?;
    Ok(())
}

fn process_consolidation_request<E: EthSpec>(
    state: &mut BeaconState<E>,
    path: &PathBuf,
    spec: &ChainSpec,
) -> Result<(), String> {
    let request: ConsolidationRequest = load_from_ssz_with(path, spec, |bytes, _spec| {
        Ok(Decode::from_ssz_bytes(bytes)?)
    })?;
    state
        .update_pubkey_cache()
        .map_err(|e| format!("Failed to update pubkey cache: {:?}", e))?;
    process_consolidation_requests(state, std::slice::from_ref(&request), spec)
        .map_err(|e| format!("Failed to process consolidation request: {:?}", e))?;
    Ok(())
}

fn process_withdrawals_op<E: EthSpec>(
    state: &mut BeaconState<E>,
    path: &PathBuf,
    spec: &ChainSpec,
) -> Result<(), String> {
    let fork_name = state.fork_name_unchecked();
    let payload: FullPayload<E> = load_from_ssz_with(path, spec, |bytes, _spec| {
        Ok(ExecutionPayload::from_ssz_bytes_by_fork(bytes, fork_name)?.into())
    })?;

    process_withdrawals::<_, FullPayload<_>>(state, payload.to_ref(), spec)
        .map_err(|e| format!("Failed to process withdrawals: {:?}", e))?;
    Ok(())
}
