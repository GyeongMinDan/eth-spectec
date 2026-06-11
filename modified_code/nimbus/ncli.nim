# beacon_chain
# Copyright (c) 2020-2025 Status Research & Development GmbH
# Licensed and distributed under either of
#   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
#   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.push raises: [], gcsafe.}

import
  confutils, json_serialization,
  snappy,
  ../beacon_chain/spec/eth2_apis/eth2_rest_serialization,
  ../beacon_chain/spec/[eth2_ssz_serialization, state_transition, state_transition_block, state_transition_epoch, forks],
  ../beacon_chain/spec/datatypes/[phase0, altair, bellatrix, capella, deneb, electra, constants]

from serialization import SerializationError

from std/os import splitFile, getEnv
from std/stats import RunningStat
from std/strutils import cmpIgnoreCase
from stew/byteutils import toHex
from stew/io2 import readAllBytes
from ../beacon_chain/networking/network_metadata import getRuntimeConfig
from ../research/simutils import printTimers, withTimer, withTimerRet
from ../beacon_chain/spec/beaconstate import
  get_base_reward_per_increment, get_state_exit_queue_info,
  get_total_active_balance, process_attestation
from ../beacon_chain/validator_bucket_sort import sortValidatorBuckets

type
  Cmd* = enum
    hash_tree_root = "Compute hash tree root of SSZ object"
    pretty = "Pretty-print SSZ object"
    transition = "Run state transition function"
    slots = "Apply empty slots"
    sanity_slots = "Process slots (matches official test runner sanity_slots behavior)"
    operation = "Process an operation on the pre-state"
    epoch_processing = "Process an epoch operation on the pre-state"

  NcliConf* = object
    eth2Network* {.
      desc: "The Eth2 network preset to use"
      name: "network" }: Option[string]

    printTimes* {.
      defaultValue: false # false to avoid polluting minimal output
      name: "print-times"
      desc: "Print timing information".}: bool

    # TODO confutils argument pragma doesn't seem to do much; also, the cases
    # are largely equivalent, but this helps create command line usage text
    case cmd* {.command}: Cmd
    of hash_tree_root:
      htrKind* {.
        argument
        desc: "kind of SSZ object: attester_slashing, attestation, signed_block, block, block_body, block_header, deposit, deposit_data, eth1_data, state, proposer_slashing, or voluntary_exit"}: string

      htrFile* {.
        argument
        desc: "filename of SSZ or JSON-encoded object of which to compute hash tree root"}: string

    of pretty:
      prettyKind* {.
        argument
        desc: "kind of SSZ object: attester_slashing, attestation, signed_block, block, block_body, block_header, deposit, deposit_data, eth1_data, state, proposer_slashing, or voluntary_exit"}: string

      prettyFile* {.
        argument
        desc: "filename of SSZ or JSON-encoded object to pretty-print"}: string

    of transition:
      preState* {.
        argument
        desc: "State to which to apply specified block"}: string

      blck* {.
        argument
        desc: "Block to apply to preState"}: string

      postState* {.
        argument
        desc: "Filename of state resulting from applying blck to preState"}: string

      verifyStateRoot* {.
        argument
        desc: "Verify state root (default true)"
        defaultValue: true}: bool

    of slots:
      preState2* {.
        argument
        desc: "State to which to apply specified empty slots"}: string

      slot* {.
        argument
        desc: "Empty slots to apply to preState"}: uint64

      postState2* {.
        argument
        desc: "Filename of state resulting from empty slots to preState"}: string

    of sanity_slots:
      preStateSanity* {.
        argument
        desc: "State to which to apply specified number of slots"}: string

      slotSanity* {.
        argument
        desc: "Number of slots to process"}: uint64

      postStateSanity* {.
        argument
        desc: "Filename of state resulting from processing slots"}: string

    of operation:
      preState3* {.
        argument
        desc: "Pre-state to which to apply operation"}: string

      operationType* {.
        argument
        desc: "Operation type: attestation, attester_slashing, proposer_slashing, block_header, deposit, voluntary_exit, sync_aggregate, execution_payload, bls_to_execution_change, withdrawal"}: string

      operationData* {.
        argument
        desc: "Path to operation SSZ file"}: string

      postState3* {.
        argument
        desc: "Filename of state resulting from applying operation"}: string

    of epoch_processing:
      preState4* {.
        argument
        desc: "Pre-state to which to apply epoch processing"}: string

      epochOperationType* {.
        argument
        desc: "Epoch operation type: justification_and_finalization, rewards_and_penalties, registry_updates, slashings, effective_balance_updates, participation_flag_updates, eth1_data_reset, slashings_reset, randao_mixes_reset, historical_summaries_update, sync_committee_updates, inactivity_updates"}: string

      postState4* {.
        argument
        desc: "Filename of state resulting from epoch processing"}: string

template saveSSZFile(filename: string, value: ForkedHashedBeaconState) =
  try:
    case value.kind:
    of ConsensusFork.Phase0:    SSZ.saveFile(filename, value.phase0Data.data)
    of ConsensusFork.Altair:    SSZ.saveFile(filename, value.altairData.data)
    of ConsensusFork.Bellatrix: SSZ.saveFile(filename, value.bellatrixData.data)
    of ConsensusFork.Capella:   SSZ.saveFile(filename, value.capellaData.data)
    of ConsensusFork.Deneb:     SSZ.saveFile(filename, value.denebData.data)
    of ConsensusFork.Electra:   SSZ.saveFile(filename, value.electraData.data)
    of ConsensusFork.Fulu:      SSZ.saveFile(filename, value.fuluData.data)
    of ConsensusFork.Gloas:     SSZ.saveFile(filename, value.gloasData.data)
  except IOError:
    raiseAssert "error saving SSZ file"

proc loadFile(filename: string, bytes: openArray[byte], T: type): T =
  let
    ext = splitFile(filename).ext

  try:
    if cmpIgnoreCase(ext, ".ssz") == 0:
      SSZ.decode(bytes, T)
    elif cmpIgnoreCase(ext, ".ssz_snappy") == 0:
      SSZ.decode(snappy.decode(bytes), T)
    elif cmpIgnoreCase(ext, ".json") == 0:
      # JSON.loadFile(file, t)
      echo "TODO needs porting to RestJson"
      quit 1
    else:
      echo "Unknown file type: ", ext
      quit 1
  except CatchableError:
    echo "failed to load SSZ file"
    quit 1

proc pureForkConfig(cfgBase: RuntimeConfig, forkVersion: string): RuntimeConfig =
  result = cfgBase
  case forkVersion
  of "phase0":
    result.ALTAIR_FORK_EPOCH = FAR_FUTURE_EPOCH
    result.BELLATRIX_FORK_EPOCH = FAR_FUTURE_EPOCH
    result.CAPELLA_FORK_EPOCH = FAR_FUTURE_EPOCH
    result.DENEB_FORK_EPOCH = FAR_FUTURE_EPOCH
    result.ELECTRA_FORK_EPOCH = FAR_FUTURE_EPOCH
  of "altair":
    result.ALTAIR_FORK_EPOCH = Epoch(0)
    result.BELLATRIX_FORK_EPOCH = FAR_FUTURE_EPOCH
    result.CAPELLA_FORK_EPOCH = FAR_FUTURE_EPOCH
    result.DENEB_FORK_EPOCH = FAR_FUTURE_EPOCH
    result.ELECTRA_FORK_EPOCH = FAR_FUTURE_EPOCH
  of "bellatrix":
    result.ALTAIR_FORK_EPOCH = Epoch(0)
    result.BELLATRIX_FORK_EPOCH = Epoch(0)
    result.CAPELLA_FORK_EPOCH = FAR_FUTURE_EPOCH
    result.DENEB_FORK_EPOCH = FAR_FUTURE_EPOCH
    result.ELECTRA_FORK_EPOCH = FAR_FUTURE_EPOCH
  of "capella":
    result.ALTAIR_FORK_EPOCH = Epoch(0)
    result.BELLATRIX_FORK_EPOCH = Epoch(0)
    result.CAPELLA_FORK_EPOCH = Epoch(0)
    result.DENEB_FORK_EPOCH = Epoch(75520)
    result.ELECTRA_FORK_EPOCH = Epoch(364032)
  of "deneb":
    result.ALTAIR_FORK_EPOCH = Epoch(0)
    result.BELLATRIX_FORK_EPOCH = Epoch(0)
    result.CAPELLA_FORK_EPOCH = Epoch(0)
    result.DENEB_FORK_EPOCH = Epoch(0)
    result.ELECTRA_FORK_EPOCH = Epoch(364032)
  of "electra":
    result.ALTAIR_FORK_EPOCH = Epoch(0)
    result.BELLATRIX_FORK_EPOCH = Epoch(0)
    result.CAPELLA_FORK_EPOCH = Epoch(0)
    result.DENEB_FORK_EPOCH = Epoch(0)
    result.ELECTRA_FORK_EPOCH = Epoch(0)
  else:
    raiseAssert "unsupported FORK_VERSION: " & forkVersion

proc doTransition(conf: NcliConf) =
  type
    Timers = enum
      tLoadState = "Load state from file"
      tTransition = "Apply slot"
      tSaveState = "Save state to file"
  var timers: array[Timers, RunningStat]

  let
    cfgBase = getRuntimeConfig(conf.eth2Network)
    forkVersionEnv = getEnv("FORK_VERSION", "capella")
    cfg = pureForkConfig(cfgBase, forkVersionEnv)
    # Load state with correct config
    stateY = withTimerRet(timers[tLoadState]):
      try:
        newClone(readSszForkedHashedBeaconState(
          cfg, readAllBytes(conf.preState).tryGet()))
      except CatchableError as e:
        raiseAssert "error reading hashed beacon state: " & $e.msg
    blckX =
      try:
        readSszForkedSignedBeaconBlock(
          cfg, readAllBytes(conf.blck).tryGet())
      except CatchableError:
        raiseAssert "error reading signed beacon block"
    # validate_result = false behavior:
    # - Skip block proposer signature verification only
    # - Skip block state root verification
    # - Keep other signature checks (RANDAO, attestations, slashings, exits)
    flags = if not conf.verifyStateRoot:
              {skipBlockSignatureValidation, skipStateRootValidation}
            else:
              {}

  var
    cache = StateCache()
    info = ForkedEpochInfo()
  let res = withTimerRet(timers[tTransition]): withBlck(blckX):
    state_transition(
      cfg, stateY[], forkyBlck, cache, info, flags, noRollback)
  if res.isErr():
    error "State transition failed", error = res.error()
    quit 1
  else:
    withTimer(timers[tSaveState]):
      saveSSZFile(conf.postState, stateY[])

  if conf.printTimes:
    printTimers(false, timers)

proc doSlots(conf: NcliConf) =
  type
    Timers = enum
      tLoadState = "Load state from file"
      tApplySlot = "Apply slot"
      tApplyEpochSlot = "Apply epoch slot"
      tSaveState = "Save state to file"

  var timers: array[Timers, RunningStat]
  let
    cfgBase = getRuntimeConfig(conf.eth2Network)
    forkVersionEnv = getEnv("FORK_VERSION", "capella")
    cfg = pureForkConfig(cfgBase, forkVersionEnv)
    # Load state with correct config
    stateY = withTimerRet(timers[tLoadState]):
      try:
        newClone(readSszForkedHashedBeaconState(
          cfg, readAllBytes(conf.preState2).tryGet()))
      except CatchableError as e:
        raiseAssert "error reading hashed beacon state: " & $e.msg
  var
    cache = StateCache()
    info = ForkedEpochInfo()
  for i in 0'u64..<conf.slot:
    let isEpoch = (getStateField(stateY[], slot) + 1).is_epoch
    withTimer(timers[if isEpoch: tApplyEpochSlot else: tApplySlot]):
      process_slots(
        cfg, stateY[], getStateField(stateY[], slot) + 1,
        cache, info, {}).expect("should be able to advance slot")

  withTimer(timers[tSaveState]):
    saveSSZFile(conf.postState2, stateY[])

  if conf.printTimes:
    printTimers(false, timers)

proc doSanitySlots(conf: NcliConf) =
  # Process slots in one call (same as official test runner)
  # process_slots(cfg, fhPreState[], getStateField(fhPreState[], slot) + num_slots, cache, info, {})
  type
    Timers = enum
      tLoadState = "Load state from file"
      tProcessSlots = "Process slots"
      tSaveState = "Save state to file"

  var timers: array[Timers, RunningStat]
  let
    cfgBase = getRuntimeConfig(conf.eth2Network)
    forkVersionEnv = getEnv("FORK_VERSION", "capella")
    cfg = pureForkConfig(cfgBase, forkVersionEnv)
    # Load state with correct config
    stateY = withTimerRet(timers[tLoadState]):
      try:
        newClone(readSszForkedHashedBeaconState(
          cfg, readAllBytes(conf.preStateSanity).tryGet()))
      except CatchableError as e:
        raiseAssert "error reading hashed beacon state: " & $e.msg
  var
    cache = StateCache()
    info = ForkedEpochInfo()
  # Process slots in one call (same as official test runner)
  # process_slots(cfg, fhPreState[], getStateField(fhPreState[], slot) + num_slots, cache, info, {})
  let targetSlot = getStateField(stateY[], slot) + conf.slotSanity
  withTimer(timers[tProcessSlots]):
    process_slots(
      cfg, stateY[], targetSlot,
      cache, info, {}).expect("should be able to advance slots")

  withTimer(timers[tSaveState]):
    saveSSZFile(conf.postStateSanity, stateY[])

  if conf.printTimes:
    printTimers(false, timers)

proc doSSZ(conf: NcliConf) =
  type Timers = enum
    tLoad = "Load file"
    tCompute = "Compute"
  var timers: array[Timers, RunningStat]

  let (kind, file) =
    case conf.cmd:
    of hash_tree_root: (conf.htrKind, conf.htrFile)
    of pretty: (conf.prettyKind, conf.prettyFile)
    else:
      raiseAssert "doSSZ() only implements hashTreeRoot and pretty commands"
  let bytes = readAllBytes(file).expect("file exists")

  template printit(t: untyped) {.dirty.} =

    let v = withTimerRet(timers[tLoad]):
      newClone(loadFile(file, bytes, t))

    case conf.cmd:
    of hash_tree_root:
      let root = withTimerRet(timers[tCompute]):
        when t is ForkySignedBeaconBlock:
          hash_tree_root(v[].message)
        else:
          hash_tree_root(v[])

      echo root.data.toHex()
    of pretty:
      echo RestJson.encode(v[], pretty = true)
    else:
      raiseAssert "doSSZ() only implements hashTreeRoot and pretty commands"

    if conf.printTimes:
      printTimers(false, timers)

  case kind
  of "attester_slashing": printit(phase0.AttesterSlashing)
  of "attestation": printit(phase0.Attestation)
  of "phase0_signed_block": printit(phase0.SignedBeaconBlock)
  of "altair_signed_block": printit(altair.SignedBeaconBlock)
  of "bellatrix_signed_block": printit(bellatrix.SignedBeaconBlock)
  of "capella_signed_block": printit(capella.SignedBeaconBlock)
  of "deneb_signed_block": printit(deneb.SignedBeaconBlock)
  of "electra_signed_block": printit(electra.SignedBeaconBlock)
  of "fulu_signed_block": printit(fulu.SignedBeaconBlock)
  of "gloas_signed_block": printit(gloas.SignedBeaconBlock)
  of "phase0_block": printit(phase0.BeaconBlock)
  of "altair_block": printit(altair.BeaconBlock)
  of "bellatrix_block": printit(bellatrix.BeaconBlock)
  of "capella_block": printit(capella.BeaconBlock)
  of "deneb_block": printit(deneb.BeaconBlock)
  of "electra_block": printit(electra.BeaconBlock)
  of "fulu_block": printit(fulu.BeaconBlock)
  of "gloas_block": printit(gloas.BeaconBlock)
  of "phase0_block_body": printit(phase0.BeaconBlockBody)
  of "altair_block_body": printit(altair.BeaconBlockBody)
  of "bellatrix_block_body": printit(bellatrix.BeaconBlockBody)
  of "capella_block_body": printit(capella.BeaconBlockBody)
  of "deneb_block_body": printit(deneb.BeaconBlockBody)
  of "electra_block_body": printit(electra.BeaconBlockBody)
  of "fulu_block_body": printit(fulu.BeaconBlockBody)
  of "gloas_block_body": printit(gloas.BeaconBlockBody)
  of "block_header": printit(BeaconBlockHeader)
  of "deposit": printit(Deposit)
  of "deposit_data": printit(DepositData)
  of "eth1_data": printit(Eth1Data)
  of "phase0_state": printit(phase0.BeaconState)
  of "altair_state": printit(altair.BeaconState)
  of "bellatrix_state": printit(bellatrix.BeaconState)
  of "capella_state": printit(capella.BeaconState)
  of "deneb_state": printit(deneb.BeaconState)
  of "electra_state": printit(electra.BeaconState)
  of "fulu_state": printit(fulu.BeaconState)
  of "gloas_state": printit(gloas.BeaconState)
  of "proposer_slashing": printit(ProposerSlashing)
  of "voluntary_exit": printit(VoluntaryExit)

proc doOperation(conf: NcliConf) =
  type
    Timers = enum
      tLoadState = "Load state from file"
      tLoadOperation = "Load operation from file"
      tProcess = "Process operation"
      tSaveState = "Save state to file"
  var timers: array[Timers, RunningStat]

  let cfgBase = getRuntimeConfig(conf.eth2Network)
  let forkVersionEnv = getEnv("FORK_VERSION", "capella")
  let cfg = pureForkConfig(cfgBase, forkVersionEnv)
  
  # Load state with correct config
  let stateY = withTimerRet(timers[tLoadState]):
    try:
      newClone(readSszForkedHashedBeaconState(
        cfg, readAllBytes(conf.preState3).tryGet()))
    except CatchableError as e:
      raiseAssert "error reading hashed beacon state: " & $e.msg
  let operationBytes = withTimerRet(timers[tLoadOperation]):
    try:
      readAllBytes(conf.operationData).tryGet()
    except CatchableError:
      raiseAssert "error reading operation data"
  # Check if operation file is .ssz (decompressed) or .ssz_snappy (compressed)
  let operationFileExt = splitFile(conf.operationData).ext
  let isSnappy = cmpIgnoreCase(operationFileExt, ".ssz_snappy") == 0

  var cache = StateCache()

  template decodeOperation(T: typedesc): untyped =
    if isSnappy:
      SSZ.decode(snappy.decode(operationBytes), T)
    else:
      SSZ.decode(operationBytes, T)
  
  proc doOperation(): Result[void, cstring] {.raises: [].} =
    try:
      withState(stateY[]):
        template processBlockHeader(T: typedesc): untyped =
          let blck = decodeOperation(T)
          let headerRes = process_block_header(forkyState.data, blck, {}, cache)
          if headerRes.isErr():
            return err(headerRes.error())

        case conf.operationType:
        of "attestation":
          when consensusFork >= ConsensusFork.Electra:
            let attestation = decodeOperation(electra.Attestation)
          else:
            let attestation = decodeOperation(phase0.Attestation)
          let total_active_balance = get_total_active_balance(forkyState.data, cache)
          let base_reward_per_increment =
            when consensusFork == ConsensusFork.Phase0:
              0.Gwei
            else:
              get_base_reward_per_increment(total_active_balance)
          let attestRes = process_attestation(
            forkyState.data, attestation, {}, base_reward_per_increment, cache)
          if attestRes.isErr():
            return err(attestRes.error())
          return ok()
        of "attester_slashing":
          when consensusFork >= ConsensusFork.Electra:
            let attesterSlashing = decodeOperation(electra.AttesterSlashing)
          else:
            let attesterSlashing = decodeOperation(phase0.AttesterSlashing)
          doAssert (? process_attester_slashing(
            cfg, forkyState.data, attesterSlashing, {strictVerification},
            get_state_exit_queue_info(forkyState.data), cache))[0] > 0.Gwei
          return ok()
        of "proposer_slashing":
          let proposerSlashing = decodeOperation(ProposerSlashing)
          doAssert (? process_proposer_slashing(
            cfg, forkyState.data, proposerSlashing, {},
            get_state_exit_queue_info(forkyState.data), cache))[0] > 0.Gwei
          return ok()
        of "block_header":
          when consensusFork == ConsensusFork.Phase0:
            processBlockHeader(phase0.BeaconBlock)
          elif consensusFork == ConsensusFork.Altair:
            processBlockHeader(altair.BeaconBlock)
          elif consensusFork == ConsensusFork.Bellatrix:
            processBlockHeader(bellatrix.BeaconBlock)
          elif consensusFork == ConsensusFork.Capella:
            processBlockHeader(capella.BeaconBlock)
          elif consensusFork == ConsensusFork.Deneb:
            processBlockHeader(deneb.BeaconBlock)
          elif consensusFork == ConsensusFork.Electra:
            processBlockHeader(electra.BeaconBlock)
          else:
            return err("unsupported fork for block_header operation")
          return ok()
        of "deposit":
          let deposit = decodeOperation(Deposit)
          let depositRes = process_deposit(
            cfg, forkyState.data,
            sortValidatorBuckets(forkyState.data.validators.asSeq)[], deposit, {})
          if depositRes.isErr():
            return err(depositRes.error())
          return ok()
        of "voluntary_exit":
          let voluntaryExit = decodeOperation(SignedVoluntaryExit)
          let exitRes = process_voluntary_exit(
            cfg, forkyState.data, voluntaryExit, {},
            get_state_exit_queue_info(forkyState.data), cache)
          if exitRes.isErr():
            return err(exitRes.error())
          return ok()
        of "sync_aggregate":
          when consensusFork >= ConsensusFork.Altair:
            let syncAggregate = decodeOperation(SyncAggregate)
            let syncRes = process_sync_aggregate(
              forkyState.data, syncAggregate,
              get_total_active_balance(forkyState.data, cache), {}, cache)
            if syncRes.isErr():
              return err(syncRes.error())
            return ok()
          else:
            return err("sync_aggregate is not available before Altair")
        of "execution_payload":
          let executionValidEnv = getEnv("EXECUTION_VALID", "true")
          let payloadValid = executionValidEnv == "true"
          when consensusFork == ConsensusFork.Bellatrix:
            let body = decodeOperation(bellatrix.BeaconBlockBody)
            func executePayload(_: bellatrix.ExecutionPayload): bool = payloadValid
            let execRes = process_execution_payload(
              cfg, forkyState.data, body.execution_payload, executePayload)
            if execRes.isErr():
              return err(execRes.error())
            return ok()
          elif consensusFork == ConsensusFork.Capella:
            let body = decodeOperation(capella.BeaconBlockBody)
            func executePayload(_: capella.ExecutionPayload): bool = payloadValid
            let execRes = process_execution_payload(
              cfg, forkyState.data, body.execution_payload, executePayload)
            if execRes.isErr():
              return err(execRes.error())
            return ok()
          elif consensusFork == ConsensusFork.Deneb:
            let body = decodeOperation(deneb.BeaconBlockBody)
            func executePayload(_: deneb.ExecutionPayload): bool = payloadValid
            let execRes = process_execution_payload(
              cfg, forkyState.data, body, executePayload)
            if execRes.isErr():
              return err(execRes.error())
            return ok()
          elif consensusFork == ConsensusFork.Electra:
            let body = decodeOperation(electra.BeaconBlockBody)
            func executePayload(_: deneb.ExecutionPayload): bool = payloadValid
            let execRes = process_execution_payload(
              cfg, forkyState.data, body, executePayload)
            if execRes.isErr():
              return err(execRes.error())
            return ok()
          else:
            return err("execution_payload is not available before Bellatrix")
        of "bls_to_execution_change":
          when consensusFork >= ConsensusFork.Capella:
            let signed_address_change = decodeOperation(SignedBLSToExecutionChange)
            let blsRes = process_bls_to_execution_change(
              cfg, forkyState.data, signed_address_change)
            if blsRes.isErr():
              return err(blsRes.error())
            return ok()
          else:
            return err("bls_to_execution_change is not available before Capella")
        of "withdrawal", "withdrawals":
          when consensusFork == ConsensusFork.Capella:
            let executionPayload = decodeOperation(capella.ExecutionPayload)
            let withdrawalRes = process_withdrawals(forkyState.data, executionPayload)
            if withdrawalRes.isErr():
              return err(withdrawalRes.error())
            return ok()
          elif consensusFork == ConsensusFork.Deneb or consensusFork == ConsensusFork.Electra:
            let executionPayload = decodeOperation(deneb.ExecutionPayload)
            let withdrawalRes = process_withdrawals(forkyState.data, executionPayload)
            if withdrawalRes.isErr():
              return err(withdrawalRes.error())
            return ok()
          else:
            return err("withdrawals are not available before Capella")
        of "deposit_request":
          when consensusFork >= ConsensusFork.Electra:
            let depositRequest = decodeOperation(electra.DepositRequest)
            let requestRes = process_deposit_request(
              cfg, forkyState.data, depositRequest, {})
            if requestRes.isErr():
              return err(requestRes.error())
            return ok()
          else:
            return err("deposit_request is not available before Electra")
        of "withdrawal_request":
          when consensusFork >= ConsensusFork.Electra:
            let withdrawalRequest = decodeOperation(electra.WithdrawalRequest)
            process_withdrawal_request(
              cfg, forkyState.data,
              sortValidatorBuckets(forkyState.data.validators.asSeq)[],
              withdrawalRequest, cache)
            return ok()
          else:
            return err("withdrawal_request is not available before Electra")
        of "consolidation_request":
          when consensusFork >= ConsensusFork.Electra:
            let consolidationRequest = decodeOperation(electra.ConsolidationRequest)
            process_consolidation_request(
              cfg, forkyState.data,
              sortValidatorBuckets(forkyState.data.validators.asSeq)[],
              consolidationRequest, cache)
            return ok()
          else:
            return err("consolidation_request is not available before Electra")
        else:
          raiseAssert "Unknown operation type: " & conf.operationType
    except SerializationError:
      return err("SSZ decode error")
  
  let res = withTimerRet(timers[tProcess]): doOperation()
  if res.isErr():
    error "Operation processing failed", error = res.error()
    quit 1
  else:
    withTimer(timers[tSaveState]):
      saveSSZFile(conf.postState3, stateY[])

  if conf.printTimes:
    printTimers(false, timers)

proc doEpochProcessing(conf: NcliConf) =
  type
    Timers = enum
      tLoadState = "Load state from file"
      tProcess = "Process epoch operation"
      tSaveState = "Save state to file"
  var timers: array[Timers, RunningStat]

  let cfgBase = getRuntimeConfig(conf.eth2Network)
  let forkVersionEnv = getEnv("FORK_VERSION", "capella")
  let cfg = pureForkConfig(cfgBase, forkVersionEnv)
  
  # Load state with correct config
  let stateY = withTimerRet(timers[tLoadState]):
    try:
      newClone(readSszForkedHashedBeaconState(
        cfg, readAllBytes(conf.preState4).tryGet()))
    except CatchableError as e:
      raiseAssert "error reading hashed beacon state: " & $e.msg

  var cache = StateCache()
  
  proc processEpochOp(): Result[void, cstring] =
    withState(stateY[]):
      case conf.epochOperationType:
      of "justification_and_finalization":
        when consensusFork == ConsensusFork.Phase0:
          var info: phase0.EpochInfo
          info.init(forkyState.data)
          info.process_attestations(forkyState.data, cache)
          process_justification_and_finalization(forkyState.data, info.balances)
        else:
          let info = altair.EpochInfo.init(forkyState.data)
          process_justification_and_finalization(forkyState.data, info.balances)
        return ok()
      of "inactivity_updates":
        when consensusFork >= ConsensusFork.Altair:
          let info = altair.EpochInfo.init(forkyState.data)
          process_inactivity_updates(cfg, forkyState.data, info)
          return ok()
        else:
          return err("inactivity_updates is not available before Altair")
      of "rewards_and_penalties":
        when consensusFork == ConsensusFork.Phase0:
          var info: phase0.EpochInfo
          info.init(forkyState.data)
          info.process_attestations(forkyState.data, cache)
          process_rewards_and_penalties(forkyState.data, info)
        else:
          var info = altair.EpochInfo.init(forkyState.data)
          process_rewards_and_penalties(cfg, forkyState.data, info)
        return ok()
      of "registry_updates":
        let regRes = process_registry_updates(cfg, forkyState.data, cache)
        if regRes.isErr():
          return err(regRes.error())
        return ok()
      of "slashings":
        when consensusFork == ConsensusFork.Phase0:
          var info: phase0.EpochInfo
          info.init(forkyState.data)
          process_slashings(forkyState.data, info.balances.current_epoch)
        else:
          let info = altair.EpochInfo.init(forkyState.data)
          process_slashings(forkyState.data, info.balances.current_epoch)
        return ok()
      of "eth1_data_reset":
        process_eth1_data_reset(forkyState.data)
        return ok()
      of "effective_balance_updates":
        process_effective_balance_updates(forkyState.data)
        return ok()
      of "slashings_reset":
        process_slashings_reset(forkyState.data)
        return ok()
      of "randao_mixes_reset":
        process_randao_mixes_reset(forkyState.data)
        return ok()
      of "historical_roots_update":
        when consensusFork < ConsensusFork.Capella:
          process_historical_roots_update(forkyState.data)
          return ok()
        else:
          return err("historical_roots_update is replaced by historical_summaries_update from Capella")
      of "historical_summaries_update":
        when consensusFork >= ConsensusFork.Capella:
          let histRes = process_historical_summaries_update(forkyState.data)
          if histRes.isErr():
            return err(histRes.error())
          return ok()
        else:
          return err("historical_summaries_update is not available before Capella")
      of "participation_record_updates":
        when consensusFork == ConsensusFork.Phase0:
          process_participation_record_updates(forkyState.data)
          return ok()
        else:
          return err("participation_record_updates is only available in Phase0")
      of "participation_flag_updates":
        when consensusFork >= ConsensusFork.Altair:
          process_participation_flag_updates(forkyState.data)
          return ok()
        else:
          return err("participation_flag_updates is not available before Altair")
      of "sync_committee_updates":
        when consensusFork >= ConsensusFork.Altair:
          process_sync_committee_updates(forkyState.data)
          return ok()
        else:
          return err("sync_committee_updates is not available before Altair")
      of "pending_deposits":
        when consensusFork >= ConsensusFork.Electra:
          let pendingRes = process_pending_deposits(cfg, forkyState.data, cache)
          if pendingRes.isErr():
            return err(pendingRes.error())
          return ok()
        else:
          return err("pending_deposits is not available before Electra")
      of "pending_consolidations":
        when consensusFork >= ConsensusFork.Electra:
          let pendingRes = process_pending_consolidations(cfg, forkyState.data)
          if pendingRes.isErr():
            return err(pendingRes.error())
          return ok()
        else:
          return err("pending_consolidations is not available before Electra")
      else:
        raiseAssert "Unknown epoch operation type: " & conf.epochOperationType
  
  let res = withTimerRet(timers[tProcess]): processEpochOp()
  if res.isErr():
    error "Epoch processing failed", error = res.error()
    quit 1
  else:
    withTimer(timers[tSaveState]):
      saveSSZFile(conf.postState4, stateY[])

  if conf.printTimes:
    printTimers(false, timers)

when isMainModule:
  let
    conf = NcliConf.load()

  case conf.cmd:
  of hash_tree_root: doSSZ(conf)
  of pretty: doSSZ(conf)
  of transition: doTransition(conf)
  of slots: doSlots(conf)
  of sanity_slots: doSanitySlots(conf)
  of operation: doOperation(conf)
  of epoch_processing: doEpochProcessing(conf)
