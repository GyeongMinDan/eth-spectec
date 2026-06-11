/*
 * Copyright Consensys Software Inc., 2025
 *
 * Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with
 * the License. You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on
 * an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the
 * specific language governing permissions and limitations under the License.
 */

package tech.pegasys.teku.cli.subcommand;

import static tech.pegasys.teku.infrastructure.logging.SubCommandLogger.SUB_COMMAND_LOG;

import com.google.common.base.MoreObjects;
import com.google.common.io.ByteStreams;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Optional;
import java.util.function.Supplier;
import org.apache.tuweni.bytes.Bytes;
import org.apache.tuweni.ssz.SSZException;
import org.bouncycastle.util.encoders.Hex;
import picocli.CommandLine;
import picocli.CommandLine.Command;
import picocli.CommandLine.Help.Visibility;
import picocli.CommandLine.Mixin;
import picocli.CommandLine.Option;
import picocli.CommandLine.Parameters;
import tech.pegasys.teku.bls.BLSSignatureVerifier;
import tech.pegasys.teku.cli.converter.PicoCliVersionProvider;
import tech.pegasys.teku.cli.options.Eth2NetworkOptions;
import tech.pegasys.teku.infrastructure.unsigned.UInt64;
import tech.pegasys.teku.spec.Spec;
import tech.pegasys.teku.spec.datastructures.blocks.SignedBeaconBlock;
import tech.pegasys.teku.spec.datastructures.state.beaconstate.BeaconState;
import tech.pegasys.teku.spec.logic.common.statetransition.exceptions.BlockProcessingException;
import tech.pegasys.teku.spec.logic.common.statetransition.exceptions.EpochProcessingException;
import tech.pegasys.teku.spec.logic.common.statetransition.exceptions.ExecutionPayloadProcessingException;
import tech.pegasys.teku.spec.logic.common.statetransition.exceptions.SlotProcessingException;
import tech.pegasys.teku.spec.logic.common.statetransition.exceptions.StateTransitionException;
import tech.pegasys.teku.spec.datastructures.blocks.BeaconBlock;
import tech.pegasys.teku.spec.datastructures.blocks.BeaconBlockSummary;
import tech.pegasys.teku.spec.datastructures.blocks.blockbody.BeaconBlockBody;
import tech.pegasys.teku.spec.datastructures.blocks.blockbody.versions.altair.BeaconBlockBodySchemaAltair;
import tech.pegasys.teku.spec.datastructures.blocks.blockbody.versions.capella.BeaconBlockBodySchemaCapella;
import tech.pegasys.teku.spec.datastructures.blocks.blockbody.versions.deneb.BeaconBlockBodySchemaDeneb;
import tech.pegasys.teku.spec.logic.common.block.BlockProcessor;
import tech.pegasys.teku.spec.logic.common.execution.ExecutionRequestsProcessor;
import tech.pegasys.teku.spec.logic.common.helpers.BeaconStateMutators.ValidatorExitContext;
import tech.pegasys.teku.spec.logic.common.statetransition.epoch.EpochProcessor;
import tech.pegasys.teku.spec.logic.common.statetransition.epoch.status.ValidatorStatusFactory;
import tech.pegasys.teku.spec.logic.versions.bellatrix.block.OptimisticExecutionPayloadExecutor;
import tech.pegasys.teku.spec.datastructures.execution.ExecutionPayload;
import tech.pegasys.teku.spec.datastructures.execution.versions.electra.ConsolidationRequest;
import tech.pegasys.teku.spec.datastructures.execution.versions.electra.DepositRequest;
import tech.pegasys.teku.spec.datastructures.execution.versions.electra.WithdrawalRequest;
import tech.pegasys.teku.spec.datastructures.operations.Attestation;
import tech.pegasys.teku.spec.datastructures.operations.AttesterSlashing;
import tech.pegasys.teku.spec.datastructures.operations.Deposit;
import tech.pegasys.teku.spec.datastructures.operations.ProposerSlashing;
import tech.pegasys.teku.spec.datastructures.operations.SignedBlsToExecutionChange;
import tech.pegasys.teku.spec.datastructures.operations.SignedVoluntaryExit;
import tech.pegasys.teku.spec.datastructures.state.beaconstate.MutableBeaconState;
import tech.pegasys.teku.spec.schemas.SchemaDefinitions;
import tech.pegasys.teku.spec.schemas.SchemaDefinitionsCapella;
import tech.pegasys.teku.spec.schemas.SchemaDefinitionsDeneb;
import tech.pegasys.teku.spec.schemas.SchemaDefinitionsElectra;

@Command(
    name = "transition",
    description = "Manually run state transitions",
    showDefaultValues = true,
    abbreviateSynopsis = true,
    mixinStandardHelpOptions = true,
    versionProvider = PicoCliVersionProvider.class,
    synopsisHeading = "%n",
    descriptionHeading = "%nDescription:%n%n",
    optionListHeading = "%nOptions:%n",
    footerHeading = "%n",
    footer = "Teku is licensed under the Apache License 2.0")
public class TransitionCommand implements Runnable {

  private static final Comparator<SignedBeaconBlock> SLOT_COMPARATOR =
      Comparator.comparing(SignedBeaconBlock::getSlot);

  @Command(
      name = "blocks",
      description = "Process blocks on the pre-state to get a post-state",
      mixinStandardHelpOptions = true,
      showDefaultValues = true,
      abbreviateSynopsis = true,
      versionProvider = PicoCliVersionProvider.class,
      synopsisHeading = "%n",
      descriptionHeading = "%nDescription:%n%n",
      optionListHeading = "%nOptions:%n",
      footerHeading = "%n",
      footer = "Teku is licensed under the Apache License 2.0")
  public int blocks(
      @Mixin final InAndOutParams params,
      @Parameters(paramLabel = "block", description = "Files to read blocks from (ssz or hex)")
          final List<String> blockPaths) {
    return processStateTransition(
        params,
        (spec, state) -> {
          if (blockPaths != null) {
            List<SignedBeaconBlock> blocks = new ArrayList<>();
            for (String blockPath : blockPaths) {
              blocks.add(readBlock(spec, blockPath));
            }
            blocks.sort(SLOT_COMPARATOR);
            for (SignedBeaconBlock block : blocks) {
              // validate_result = false: Disable block signature and state root verification
              // When validate_result = false, we use SIMPLE to verify other signatures
              // (attestations, RANDAO, etc.) but skip block signature verification in validateBlockPostProcessing.
              // Block signature and state root verification are skipped in AbstractBlockProcessor.
              state =
                  spec.processBlock(state, block, BLSSignatureVerifier.SIMPLE, Optional.empty());
            }
          }
          return state;
        });
  }

  @Command(
      name = "slots",
      description = "Process empty slots on the pre-state to get a post-state",
      mixinStandardHelpOptions = true,
      showDefaultValues = true,
      abbreviateSynopsis = true,
      versionProvider = PicoCliVersionProvider.class,
      synopsisHeading = "%n",
      descriptionHeading = "%nDescription:%n%n",
      optionListHeading = "%nOptions:%n",
      footerHeading = "%n",
      footer = "Teku is licensed under the Apache License 2.0")
  public int slots(
      @Mixin final InAndOutParams params,
      @Option(
              names = {"--delta", "-d"},
              showDefaultValue = Visibility.ALWAYS,
              fallbackValue = "true",
              description = "to interpret the slot number as a delta from the pre-state")
          final boolean delta,
      @Parameters(paramLabel = "<number>", description = "Number of slots to process")
          final long number) {
    return processStateTransition(
        params,
        (specProvider, state) -> {
          UInt64 targetSlot = UInt64.valueOf(number);
          if (delta) {
            targetSlot = state.getSlot().plus(targetSlot);
          }
          return specProvider.processSlots(state, targetSlot);
        });
  }

  @Command(
      name = "operation",
      description = "Process an operation on the pre-state to get a post-state",
      mixinStandardHelpOptions = true,
      showDefaultValues = true,
      abbreviateSynopsis = true,
      versionProvider = PicoCliVersionProvider.class,
      synopsisHeading = "%n",
      descriptionHeading = "%nDescription:%n%n",
      optionListHeading = "%nOptions:%n",
      footerHeading = "%n",
      footer = "Teku is licensed under the Apache License 2.0")
  public int operation(
      @Mixin final InAndOutParams params,
      @Parameters(
              paramLabel = "<operation-type>",
              description =
                  "Operation type: attestation, attester_slashing, proposer_slashing, "
                      + "block_header, deposit, voluntary_exit, sync_aggregate, execution_payload, "
                      + "bls_to_execution_change, withdrawal, deposit_request, "
                      + "withdrawal_request, consolidation_request")
          final String operationType,
      @Option(
              names = {"--operation-data"},
              description = "Path to operation SSZ file (required for most operations)")
          final String operationDataPath,
      @Option(
              names = {"--execution-valid"},
              description = "For execution_payload operation: whether execution payload is valid (true or false, default: true)")
          final String executionValid) {
    return processStateTransition(
        params,
        (spec, state) -> {
          return state.updated(
              mutableState -> {
                try {
                  processOperation(
                      spec, mutableState, operationType, operationDataPath, executionValid);
                } catch (final BlockProcessingException
                    | ExecutionPayloadProcessingException
                    | IOException e) {
                  throw new StateTransitionException(e);
                }
              });
        });
  }

  @Command(
      name = "epoch-processing",
      description = "Process an epoch operation on the pre-state to get a post-state",
      mixinStandardHelpOptions = true,
      showDefaultValues = true,
      abbreviateSynopsis = true,
      versionProvider = PicoCliVersionProvider.class,
      synopsisHeading = "%n",
      descriptionHeading = "%nDescription:%n%n",
      optionListHeading = "%nOptions:%n",
      footerHeading = "%n",
      footer = "Teku is licensed under the Apache License 2.0")
  public int epochProcessing(
      @Mixin final InAndOutParams params,
      @Parameters(
              paramLabel = "<epoch-operation-type>",
              description =
                  "Epoch operation type: justification_and_finalization, "
                      + "rewards_and_penalties, registry_updates, slashings, "
                      + "effective_balance_updates, participation_flag_updates, "
                      + "eth1_data_reset, slashings_reset, randao_mixes_reset, "
                      + "historical_roots_update, historical_summaries_update, "
                      + "sync_committee_updates, inactivity_updates, pending_deposits, "
                      + "pending_consolidations")
          final String epochOperationType) {
    return processStateTransition(
        params,
        (spec, state) -> {
          final EpochProcessor epochProcessor =
              spec.getGenesisSpec().getEpochProcessor();
          final ValidatorStatusFactory validatorStatusFactory =
              spec.getGenesisSpec().getValidatorStatusFactory();
          return state.updated(
              mutableState -> {
                try {
                  processEpochOperation(
                      mutableState, epochProcessor, validatorStatusFactory, epochOperationType);
                } catch (final EpochProcessingException e) {
                  throw new StateTransitionException(e);
                }
              });
        });
  }

  private int processStateTransition(
      final InAndOutParams params, final StateTransitionFunction transition) {
    final Spec spec = params.eth2NetworkOptions.getNetworkConfiguration().getSpec();
    try (final InputStream in = selectInputStream(params);
        final OutputStream out = selectOutputStream(params)) {
      final Bytes inData = Bytes.wrap(ByteStreams.toByteArray(in));
      BeaconState state = readState(spec, inData);

      try {
        BeaconState result = transition.applyTransition(spec, state);
        out.write(result.sszSerialize().toArrayUnsafe());
        return 0;
      } catch (final StateTransitionException
          | EpochProcessingException
          | SlotProcessingException e) {
        SUB_COMMAND_LOG.error("State transition failed", e);
        return 1;
      }
    } catch (final SSZException e) {
      SUB_COMMAND_LOG.error(e.getMessage());
      return 1;
    } catch (final IOException e) {
      SUB_COMMAND_LOG.error("I/O error: " + e.toString());
      return 1;
    } catch (final Throwable t) {
      t.printStackTrace();
      return 2;
    }
  }

  private OutputStream selectOutputStream(@Mixin final InAndOutParams params) throws IOException {
    return params.post != null ? Files.newOutputStream(Path.of(params.post)) : System.out;
  }

  private InputStream selectInputStream(@Mixin final InAndOutParams params) throws IOException {
    if (params.pre != null) {
      final Path inputPath = Path.of(params.pre);
      return Files.newInputStream(inputPath);
    } else {
      return System.in;
    }
  }

  private BeaconState readState(final Spec spec, final Bytes inData) {
    try {
      return spec.deserializeBeaconState(inData);
    } catch (final IllegalArgumentException e) {
      throw new SSZException("Failed to parse SSZ (pre state): " + e.getMessage(), e);
    }
  }

  private SignedBeaconBlock readBlock(final Spec spec, final String path) throws IOException {
    final byte[] blockDataBytesArray;
    if (path.endsWith(".hex")) {
      final String str = Files.readString(Path.of(path)).trim();
      blockDataBytesArray = Bytes.fromHexString(str).toArrayUnsafe();
    } else {
      blockDataBytesArray = Files.readAllBytes(Path.of(path));
    }
    try {
      return spec.deserializeSignedBeaconBlock(Bytes.wrap(blockDataBytesArray));
    } catch (final RuntimeException e) {
      return deserializeSignedBeaconBlockFromHex(spec, path, blockDataBytesArray, e);
    }
  }

  private SignedBeaconBlock deserializeSignedBeaconBlockFromHex(
      final Spec spec,
      final String path,
      final byte[] hexBlockData,
      final RuntimeException sszSerializationException) {
    try {
      final Bytes blockData = Bytes.wrap(Hex.decode(hexBlockData));
      return spec.deserializeSignedBeaconBlock(blockData);
    } catch (final RuntimeException e) {
      throw new RuntimeException(
          String.format(
              "Failed to parse (%s). SSZ deserialization error: %s. HEX deserialization error: %s",
              path, sszSerializationException.getMessage(), e.getMessage()),
          e);
    }
  }

  private void processOperation(
      final Spec spec,
      final MutableBeaconState state,
      final String operationType,
      final String operationDataPath,
      final String executionValid)
      throws BlockProcessingException, ExecutionPayloadProcessingException, IOException {
    // Get schema definitions for the current slot (supports both Capella and Deneb)
    final SchemaDefinitions schemaDefinitions = spec.atSlot(state.getSlot()).getSchemaDefinitions();
    final BlockProcessor blockProcessor = spec.getBlockProcessor(state.getSlot());
    final Bytes operationData =
        operationDataPath != null
            ? Bytes.wrap(Files.readAllBytes(Path.of(operationDataPath)))
            : null;

    switch (operationType) {
      case "attestation" -> {
        final Attestation attestation =
            schemaDefinitions.getAttestationSchema().sszDeserialize(operationData);
        blockProcessor.processAttestations(
            state,
            schemaDefinitions.getBeaconBlockBodySchema().getAttestationsSchema().of(attestation),
            BLSSignatureVerifier.SIMPLE);
      }
      case "attester_slashing" -> {
        final AttesterSlashing attesterSlashing =
            schemaDefinitions.getAttesterSlashingSchema().sszDeserialize(operationData);
        blockProcessor.processAttesterSlashings(
            state,
            schemaDefinitions.getBeaconBlockBodySchema().getAttesterSlashingsSchema().of(attesterSlashing));
      }
      case "proposer_slashing" -> {
        final ProposerSlashing proposerSlashing =
            ProposerSlashing.SSZ_SCHEMA.sszDeserialize(operationData);
        blockProcessor.processProposerSlashings(
            state,
            schemaDefinitions.getBeaconBlockBodySchema().getProposerSlashingsSchema().of(proposerSlashing),
            BLSSignatureVerifier.SIMPLE);
      }
      case "block_header" -> {
        final BeaconBlockSummary blockHeader =
            schemaDefinitions.getBeaconBlockSchema().sszDeserialize(operationData);
        blockProcessor.processBlockHeader(state, blockHeader);
      }
      case "deposit" -> {
        final Deposit deposit = Deposit.SSZ_SCHEMA.sszDeserialize(operationData);
        blockProcessor.processDeposits(
            state,
            schemaDefinitions.getBeaconBlockBodySchema().getDepositsSchema().of(deposit));
      }
      case "voluntary_exit" -> {
        final SignedVoluntaryExit voluntaryExit =
            SignedVoluntaryExit.SSZ_SCHEMA.sszDeserialize(operationData);
        blockProcessor.processVoluntaryExits(
            state,
            schemaDefinitions.getBeaconBlockBodySchema().getVoluntaryExitsSchema().of(voluntaryExit),
            BLSSignatureVerifier.SIMPLE);
      }
      case "sync_aggregate" -> {
        final BeaconBlockBodySchemaAltair<?> altairSchema =
            BeaconBlockBodySchemaAltair.required(
                schemaDefinitions.getBeaconBlockBodySchema());
        final Bytes syncAggregateData =
            operationData != null ? operationData : Bytes.EMPTY;
        blockProcessor.processSyncAggregate(
            state, altairSchema.getSyncAggregateSchema().sszDeserialize(syncAggregateData), BLSSignatureVerifier.SIMPLE);
      }
      case "execution_payload" -> {
        final BeaconBlockBody beaconBlockBody =
            schemaDefinitions.getBeaconBlockBodySchema().sszDeserialize(operationData);
        // Parse execution_valid flag (default to true if not provided)
        final boolean executionValidBool =
            executionValid == null || executionValid.isEmpty() || "true".equals(executionValid);
        // Create executor that returns execution_valid value (matching official test runner behavior)
        final Optional<OptimisticExecutionPayloadExecutor> payloadExecutor =
            Optional.of(
                (latestExecutionPayloadHeader, payloadToExecute) -> executionValidBool);
        blockProcessor.processExecutionPayload(state, beaconBlockBody, payloadExecutor);
      }
      case "bls_to_execution_change" -> {
        // Support both Capella and Deneb (SchemaDefinitionsDeneb extends SchemaDefinitionsCapella)
        final SchemaDefinitionsCapella capellaSchema =
            SchemaDefinitionsCapella.required(schemaDefinitions);
        final SignedBlsToExecutionChange blsToExecutionChange =
            capellaSchema.getSignedBlsToExecutionChangeSchema().sszDeserialize(operationData);
        // Try Capella schema first, then Deneb if needed
        try {
          final BeaconBlockBodySchemaCapella<?> capellaBodySchema =
              BeaconBlockBodySchemaCapella.required(
                  schemaDefinitions.getBeaconBlockBodySchema());
          blockProcessor.processBlsToExecutionChanges(
              state,
              capellaBodySchema.getBlsToExecutionChangesSchema().of(blsToExecutionChange));
        } catch (final IllegalArgumentException e) {
          // If Capella schema not available, try Deneb
          final BeaconBlockBodySchemaDeneb<?> denebBodySchema =
              BeaconBlockBodySchemaDeneb.required(
                  schemaDefinitions.getBeaconBlockBodySchema());
          blockProcessor.processBlsToExecutionChanges(
              state,
              denebBodySchema.getBlsToExecutionChangesSchema().of(blsToExecutionChange));
        }
      }
      case "withdrawal" -> {
        // Support both Capella and Deneb (SchemaDefinitionsDeneb extends SchemaDefinitionsCapella)
        final SchemaDefinitionsCapella capellaSchema =
            SchemaDefinitionsCapella.required(schemaDefinitions);
        final ExecutionPayload executionPayload =
            capellaSchema.getExecutionPayloadSchema().sszDeserialize(operationData);
        blockProcessor.processWithdrawals(state, Optional.of(executionPayload));
      }
      case "withdrawals" -> {
        final SchemaDefinitionsCapella capellaSchema =
            SchemaDefinitionsCapella.required(schemaDefinitions);
        final ExecutionPayload executionPayload =
            capellaSchema.getExecutionPayloadSchema().sszDeserialize(operationData);
        blockProcessor.processWithdrawals(state, Optional.of(executionPayload));
      }
      case "deposit_request" -> {
        final SchemaDefinitionsElectra electraSchema =
            SchemaDefinitionsElectra.required(schemaDefinitions);
        final DepositRequest depositRequest =
            electraSchema.getDepositRequestSchema().sszDeserialize(operationData);
        final ExecutionRequestsProcessor executionRequestsProcessor =
            spec.getExecutionRequestsProcessor(state.getSlot());
        executionRequestsProcessor.processDepositRequests(state, List.of(depositRequest));
      }
      case "withdrawal_request" -> {
        final SchemaDefinitionsElectra electraSchema =
            SchemaDefinitionsElectra.required(schemaDefinitions);
        final WithdrawalRequest withdrawalRequest =
            electraSchema.getWithdrawalRequestSchema().sszDeserialize(operationData);
        final ExecutionRequestsProcessor executionRequestsProcessor =
            spec.getExecutionRequestsProcessor(state.getSlot());
        final Supplier<ValidatorExitContext> validatorExitContextSupplier =
            spec.atSlot(state.getSlot())
                .beaconStateMutators()
                .createValidatorExitContextSupplier(state);
        executionRequestsProcessor.processWithdrawalRequests(
            state,
            List.of(withdrawalRequest),
            validatorExitContextSupplier);
      }
      case "consolidation_request" -> {
        final SchemaDefinitionsElectra electraSchema =
            SchemaDefinitionsElectra.required(schemaDefinitions);
        final ConsolidationRequest consolidationRequest =
            electraSchema.getConsolidationRequestSchema().sszDeserialize(operationData);
        final ExecutionRequestsProcessor executionRequestsProcessor =
            spec.getExecutionRequestsProcessor(state.getSlot());
        executionRequestsProcessor.processConsolidationRequests(state, List.of(consolidationRequest));
      }
      default ->
          throw new IllegalArgumentException("Unknown operation type: " + operationType);
    }
  }

  private void processEpochOperation(
      final MutableBeaconState state,
      final EpochProcessor epochProcessor,
      final ValidatorStatusFactory validatorStatusFactory,
      final String epochOperationType)
      throws EpochProcessingException {
    switch (epochOperationType) {
      case "justification_and_finalization" -> {
        epochProcessor.processJustificationAndFinalization(
            state, validatorStatusFactory.createValidatorStatuses(state).getTotalBalances());
      }
      case "rewards_and_penalties" -> {
        epochProcessor.processRewardsAndPenalties(
            state, validatorStatusFactory.createValidatorStatuses(state));
      }
      case "registry_updates" -> {
        epochProcessor.processRegistryUpdates(
            state, validatorStatusFactory.createValidatorStatuses(state).getStatuses());
      }
      case "slashings" -> {
        epochProcessor.processSlashings(
            state, validatorStatusFactory.createValidatorStatuses(state));
      }
      case "effective_balance_updates" -> {
        epochProcessor.processEffectiveBalanceUpdates(
            state, validatorStatusFactory.createValidatorStatuses(state).getStatuses());
      }
      case "participation_flag_updates" -> {
        epochProcessor.processParticipationUpdates(state);
      }
      case "eth1_data_reset" -> {
        epochProcessor.processEth1DataReset(state);
      }
      case "slashings_reset" -> {
        epochProcessor.processSlashingsReset(state);
      }
      case "randao_mixes_reset" -> {
        epochProcessor.processRandaoMixesReset(state);
      }
      case "historical_summaries_update" -> {
        epochProcessor.processHistoricalSummariesUpdate(state);
      }
      case "historical_roots_update" -> {
        epochProcessor.processHistoricalRootsUpdate(state);
      }
      case "participation_record_updates" -> {
        epochProcessor.processParticipationUpdates(state);
      }
      case "sync_committee_updates" -> {
        epochProcessor.processSyncCommitteeUpdates(state);
      }
      case "inactivity_updates" -> {
        epochProcessor.processInactivityUpdates(
            state, validatorStatusFactory.createValidatorStatuses(state));
      }
      case "pending_deposits" -> {
        epochProcessor.processPendingDeposits(state);
      }
      case "pending_consolidations" -> {
        epochProcessor.processPendingConsolidations(state);
      }
      default ->
          throw new IllegalArgumentException("Unknown epoch operation type: " + epochOperationType);
    }
  }


  @Override
  public void run() {
    CommandLine.usage(this, System.out);
  }

  public static class InAndOutParams {

    @Option(
        names = {"--post", "-o"},
        description = "Post (Output) path. If none is specified, output is written to STDOUT")
    private String post;

    @Option(
        names = {"--pre", "-i"},
        description = "Pre (Input) path. If none is specified, input is read from STDIN")
    private String pre;

    @Mixin private Eth2NetworkOptions eth2NetworkOptions;

    @Override
    public String toString() {
      return MoreObjects.toStringHelper(this).add("post", post).add("pre", pre).toString();
    }
  }

  private interface StateTransitionFunction {
    BeaconState applyTransition(final Spec spec, BeaconState state)
        throws StateTransitionException,
            EpochProcessingException,
            SlotProcessingException,
            IOException;
  }
}
