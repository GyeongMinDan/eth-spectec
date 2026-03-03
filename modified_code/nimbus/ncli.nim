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
  ../beacon_chain/spec/datatypes/[phase0, altair, bellatrix, capella, deneb, constants]

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

proc doTransition(conf: NcliConf) =
  type
    Timers = enum
      tLoadState = "Load state from file"
      tTransition = "Apply slot"
      tSaveState = "Save state to file"
  var timers: array[Timers, RunningStat]

  let
    cfgBase = getRuntimeConfig(conf.eth2Network)
    # Get fork version from environment variable (set by diff_testing.py)
    # Default to "capella" if not set
    forkVersionEnv = getEnv("FORK_VERSION", "capella")
    isDeneb = forkVersionEnv == "deneb"
    # Set config based on fork version
    cfg = block:
      var c = cfgBase
      c.ALTAIR_FORK_EPOCH = Epoch(0)
      c.BELLATRIX_FORK_EPOCH = Epoch(0)
      c.CAPELLA_FORK_EPOCH = Epoch(0)
      if isDeneb:
        # Pure Deneb config: DENEB_FORK_EPOCH = 0
        c.DENEB_FORK_EPOCH = Epoch(0)
      else:
        # Pure Capella config: CAPELLA_FORK_EPOCH = 0, DENEB_FORK_EPOCH = 75520
        c.DENEB_FORK_EPOCH = Epoch(75520)
      c
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
    # Get fork version from environment variable (set by diff_testing.py)
    # Default to "capella" if not set
    forkVersionEnv = getEnv("FORK_VERSION", "capella")
    isDeneb = forkVersionEnv == "deneb"
    # Set config based on fork version
    cfg = block:
      var c = cfgBase
      c.ALTAIR_FORK_EPOCH = Epoch(0)
      c.BELLATRIX_FORK_EPOCH = Epoch(0)
      c.CAPELLA_FORK_EPOCH = Epoch(0)
      if isDeneb:
        # Pure Deneb config: DENEB_FORK_EPOCH = 0
        c.DENEB_FORK_EPOCH = Epoch(0)
      else:
        # Pure Capella config: CAPELLA_FORK_EPOCH = 0, DENEB_FORK_EPOCH = 75520
        c.DENEB_FORK_EPOCH = Epoch(75520)
      c
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
    # Get fork version from environment variable (set by diff_testing.py)
    # Default to "capella" if not set
    forkVersionEnv = getEnv("FORK_VERSION", "capella")
    isDeneb = forkVersionEnv == "deneb"
    # Set config based on fork version
    cfg = block:
      var c = cfgBase
      c.ALTAIR_FORK_EPOCH = Epoch(0)
      c.BELLATRIX_FORK_EPOCH = Epoch(0)
      c.CAPELLA_FORK_EPOCH = Epoch(0)
      if isDeneb:
        # Pure Deneb config: DENEB_FORK_EPOCH = 0
        c.DENEB_FORK_EPOCH = Epoch(0)
      else:
        # Pure Capella config: CAPELLA_FORK_EPOCH = 0, DENEB_FORK_EPOCH = 75520
        c.DENEB_FORK_EPOCH = Epoch(75520)
      c
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

  # Get fork version from environment variable (set by diff_testing.py)
  # Default to "capella" if not set
  let cfgBase = getRuntimeConfig(conf.eth2Network)
  let forkVersionEnv = getEnv("FORK_VERSION", "capella")
  let isDeneb = forkVersionEnv == "deneb"
  # Set config based on fork version
  let cfg = block:
    var c = cfgBase
    c.ALTAIR_FORK_EPOCH = Epoch(0)
    c.BELLATRIX_FORK_EPOCH = Epoch(0)
    c.CAPELLA_FORK_EPOCH = Epoch(0)
    if isDeneb:
      # Pure Deneb config: DENEB_FORK_EPOCH = 0
      c.DENEB_FORK_EPOCH = Epoch(0)
    else:
      # Pure Capella config: CAPELLA_FORK_EPOCH = 0, DENEB_FORK_EPOCH = 75520
      c.DENEB_FORK_EPOCH = Epoch(75520)
    c
  
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
  # Support both Capella and Deneb (isDeneb already defined above)
  
  proc doOperation(): Result[void, cstring] {.raises: [].} =
    try:
      case conf.operationType:
      of "attestation":
        let attestation = if isSnappy:
          SSZ.decode(snappy.decode(operationBytes), phase0.Attestation)
        else:
          SSZ.decode(operationBytes, phase0.Attestation)
        if isDeneb:
          var denebState = addr stateY[].denebData.data
          let
            total_active_balance = get_total_active_balance(denebState[], cache)
            base_reward_per_increment = get_base_reward_per_increment(total_active_balance)
          let attestRes = process_attestation(
            denebState[], attestation, {}, base_reward_per_increment, cache)
          if attestRes.isErr():
            return err(attestRes.error())
        else:
          var capellaState = addr stateY[].capellaData.data
          let
            total_active_balance = get_total_active_balance(capellaState[], cache)
            base_reward_per_increment = get_base_reward_per_increment(total_active_balance)
          let attestRes = process_attestation(
            capellaState[], attestation, {}, base_reward_per_increment, cache)
          if attestRes.isErr():
            return err(attestRes.error())
        ok()
      of "attester_slashing":
        let attesterSlashing = if isSnappy:
          SSZ.decode(snappy.decode(operationBytes), phase0.AttesterSlashing)
        else:
          SSZ.decode(operationBytes, phase0.AttesterSlashing)
        if isDeneb:
          var denebState = addr stateY[].denebData.data
          doAssert (? process_attester_slashing(
            cfg, denebState[], attesterSlashing, {strictVerification},
            get_state_exit_queue_info(denebState[]), cache))[0] > 0.Gwei
        else:
          var capellaState = addr stateY[].capellaData.data
          doAssert (? process_attester_slashing(
            cfg, capellaState[], attesterSlashing, {strictVerification},
            get_state_exit_queue_info(capellaState[]), cache))[0] > 0.Gwei
        ok()
      of "proposer_slashing":
        let proposerSlashing = if isSnappy:
          SSZ.decode(snappy.decode(operationBytes), ProposerSlashing)
        else:
          SSZ.decode(operationBytes, ProposerSlashing)
        if isDeneb:
          var denebState = addr stateY[].denebData.data
          doAssert (? process_proposer_slashing(
            cfg, denebState[], proposerSlashing, {},
            get_state_exit_queue_info(denebState[]), cache))[0] > 0.Gwei
        else:
          var capellaState = addr stateY[].capellaData.data
          doAssert (? process_proposer_slashing(
            cfg, capellaState[], proposerSlashing, {},
            get_state_exit_queue_info(capellaState[]), cache))[0] > 0.Gwei
        ok()
      of "block_header":
        if isDeneb:
          let blck = if isSnappy:
            SSZ.decode(snappy.decode(operationBytes), deneb.BeaconBlock)
          else:
            SSZ.decode(operationBytes, deneb.BeaconBlock)
          var denebState = addr stateY[].denebData.data
          #if blck.is_execution_block:
          # doAssert blck.body.execution_payload.block_hash == blck.compute_execution_block_hash()
          # Note: Official test runner uses 'check' (non-fatal), but we skip this validation
          # for block_header operation as some test cases have invalid block_hash intentionally
          let headerRes = process_block_header(denebState[], blck, {}, cache)
          if headerRes.isErr():
            return err(headerRes.error())
        else:
          let blck = if isSnappy:
            SSZ.decode(snappy.decode(operationBytes), capella.BeaconBlock)
          else:
            SSZ.decode(operationBytes, capella.BeaconBlock)
          var capellaState = addr stateY[].capellaData.data
          #if blck.is_execution_block:
          #  doAssert blck.body.execution_payload.block_hash == blck.compute_execution_block_hash()
          # Note: Official test runner uses 'check' (non-fatal), but we skip this validation
          # for block_header operation as some test cases have invalid block_hash intentionally
          let headerRes = process_block_header(capellaState[], blck, {}, cache)
          if headerRes.isErr():
            return err(headerRes.error())
        ok()
      of "deposit":
        let deposit = if isSnappy:
          SSZ.decode(snappy.decode(operationBytes), Deposit)
        else:
          SSZ.decode(operationBytes, Deposit)
        if isDeneb:
          var denebState = addr stateY[].denebData.data
          let depositRes = process_deposit(
            cfg, denebState[],
            sortValidatorBuckets(denebState[].validators.asSeq)[], deposit, {})
          if depositRes.isErr():
            return err(depositRes.error())
        else:
          var capellaState = addr stateY[].capellaData.data
          let depositRes = process_deposit(
            cfg, capellaState[],
            sortValidatorBuckets(capellaState[].validators.asSeq)[], deposit, {})
          if depositRes.isErr():
            return err(depositRes.error())
        ok()
      of "voluntary_exit":
        let voluntaryExit = if isSnappy:
          SSZ.decode(snappy.decode(operationBytes), SignedVoluntaryExit)
        else:
          SSZ.decode(operationBytes, SignedVoluntaryExit)
        if isDeneb:
          var denebState = addr stateY[].denebData.data
          if process_voluntary_exit(
              cfg, denebState[], voluntaryExit, {},
              get_state_exit_queue_info(denebState[]), cache).isOk:
            ok()
          else:
            err("")
        else:
          var capellaState = addr stateY[].capellaData.data
          if process_voluntary_exit(
              cfg, capellaState[], voluntaryExit, {},
              get_state_exit_queue_info(capellaState[]), cache).isOk:
            ok()
          else:
            err("")
      of "sync_aggregate":
        let syncAggregate = if isSnappy:
          SSZ.decode(snappy.decode(operationBytes), SyncAggregate)
        else:
          SSZ.decode(operationBytes, SyncAggregate)
        if isDeneb:
          var denebState = addr stateY[].denebData.data
          let syncRes = process_sync_aggregate(
            denebState[], syncAggregate, get_total_active_balance(denebState[], cache),
            {}, cache)
          if syncRes.isErr():
            return err(syncRes.error())
        else:
          var capellaState = addr stateY[].capellaData.data
          let syncRes = process_sync_aggregate(
            capellaState[], syncAggregate, get_total_active_balance(capellaState[], cache),
            {}, cache)
          if syncRes.isErr():
            return err(syncRes.error())
        ok()
      of "execution_payload":
        # Parse execution_valid flag (default to true if not provided)
        # Parse execution_valid flag from environment variable (default to true if not provided)
        let executionValidEnv = getEnv("EXECUTION_VALID", "true")
        let payloadValid = executionValidEnv == "true"
        if isDeneb:
          let body = if isSnappy:
            SSZ.decode(snappy.decode(operationBytes), deneb.BeaconBlockBody)
          else:
            SSZ.decode(operationBytes, deneb.BeaconBlockBody)
          var denebState = addr stateY[].denebData.data
          func executePayload(_: deneb.ExecutionPayload): bool = payloadValid
          let execRes = process_execution_payload(
            cfg, denebState[], body, executePayload)
          if execRes.isErr():
            return err(execRes.error())
        else:
          let body = if isSnappy:
            SSZ.decode(snappy.decode(operationBytes), capella.BeaconBlockBody)
          else:
            SSZ.decode(operationBytes, capella.BeaconBlockBody)
          var capellaState = addr stateY[].capellaData.data
          func executePayload(_: capella.ExecutionPayload): bool = payloadValid
          let execRes = process_execution_payload(
            cfg, capellaState[], body.execution_payload, executePayload)
          if execRes.isErr():
            return err(execRes.error())
        ok()
      of "bls_to_execution_change":
        let signed_address_change = if isSnappy:
          SSZ.decode(snappy.decode(operationBytes), SignedBLSToExecutionChange)
        else:
          SSZ.decode(operationBytes, SignedBLSToExecutionChange)
        if isDeneb:
          var denebState = addr stateY[].denebData.data
          let blsRes = process_bls_to_execution_change(
            cfg, denebState[], signed_address_change)
          if blsRes.isErr():
            return err(blsRes.error())
        else:
          var capellaState = addr stateY[].capellaData.data
          let blsRes = process_bls_to_execution_change(
            cfg, capellaState[], signed_address_change)
          if blsRes.isErr():
            return err(blsRes.error())
        ok()
      of "withdrawal":
        if isDeneb:
          let executionPayload = if isSnappy:
            SSZ.decode(snappy.decode(operationBytes), deneb.ExecutionPayload)
          else:
            SSZ.decode(operationBytes, deneb.ExecutionPayload)
          var denebState = addr stateY[].denebData.data
          let withdrawalRes = process_withdrawals(denebState[], executionPayload)
          if withdrawalRes.isErr():
            return err(withdrawalRes.error())
        else:
          let executionPayload = if isSnappy:
            SSZ.decode(snappy.decode(operationBytes), capella.ExecutionPayload)
          else:
            SSZ.decode(operationBytes, capella.ExecutionPayload)
          var capellaState = addr stateY[].capellaData.data
          let withdrawalRes = process_withdrawals(capellaState[], executionPayload)
          if withdrawalRes.isErr():
            return err(withdrawalRes.error())
        ok()
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

  # Get fork version from environment variable (set by diff_testing.py)
  # Default to "capella" if not set
  let cfgBase = getRuntimeConfig(conf.eth2Network)
  let forkVersionEnv = getEnv("FORK_VERSION", "capella")
  let isDeneb = forkVersionEnv == "deneb"
  # Set config based on fork version
  let cfg = block:
    var c = cfgBase
    c.ALTAIR_FORK_EPOCH = Epoch(0)
    c.BELLATRIX_FORK_EPOCH = Epoch(0)
    c.CAPELLA_FORK_EPOCH = Epoch(0)
    if isDeneb:
      # Pure Deneb config: DENEB_FORK_EPOCH = 0
      c.DENEB_FORK_EPOCH = Epoch(0)
    else:
      # Pure Capella config: CAPELLA_FORK_EPOCH = 0, DENEB_FORK_EPOCH = 75520
      c.DENEB_FORK_EPOCH = Epoch(75520)
    c
  
  # Load state with correct config
  let stateY = withTimerRet(timers[tLoadState]):
    try:
      newClone(readSszForkedHashedBeaconState(
        cfg, readAllBytes(conf.preState4).tryGet()))
    except CatchableError as e:
      raiseAssert "error reading hashed beacon state: " & $e.msg

  var cache = StateCache()
  # Support both Capella and Deneb (isDeneb already defined above)
  
  proc processEpochOp(): Result[void, cstring] =
    if isDeneb:
      var denebState = addr stateY[].denebData.data
      case conf.epochOperationType:
      of "justification_and_finalization":
        let info = altair.EpochInfo.init(denebState[])
        process_justification_and_finalization(denebState[], info.balances)
        ok()
      of "inactivity_updates":
        let info = altair.EpochInfo.init(denebState[])
        process_inactivity_updates(cfg, denebState[], info)
        ok()
      of "rewards_and_penalties":
        var info = altair.EpochInfo.init(denebState[])
        process_rewards_and_penalties(cfg, denebState[], info)
        ok()
      of "registry_updates":
        let regRes = process_registry_updates(cfg, denebState[], cache)
        if regRes.isErr():
          return err(regRes.error())
        ok()
      of "slashings":
        let info = altair.EpochInfo.init(denebState[])
        process_slashings(denebState[], info.balances.current_epoch)
        ok()
      of "eth1_data_reset":
        process_eth1_data_reset(denebState[])
        ok()
      of "effective_balance_updates":
        process_effective_balance_updates(denebState[])
        ok()
      of "slashings_reset":
        process_slashings_reset(denebState[])
        ok()
      of "randao_mixes_reset":
        process_randao_mixes_reset(denebState[])
        ok()
      of "historical_summaries_update":
        let histRes = process_historical_summaries_update(denebState[])
        if histRes.isErr():
          return err(histRes.error())
        ok()
      of "participation_flag_updates":
        process_participation_flag_updates(denebState[])
        ok()
      of "sync_committee_updates":
        process_sync_committee_updates(denebState[])
        ok()
      else:
        raiseAssert "Unknown epoch operation type: " & conf.epochOperationType
    else:
      var capellaState = addr stateY[].capellaData.data
      case conf.epochOperationType:
      of "justification_and_finalization":
        let info = altair.EpochInfo.init(capellaState[])
        process_justification_and_finalization(capellaState[], info.balances)
        ok()
      of "inactivity_updates":
        let info = altair.EpochInfo.init(capellaState[])
        process_inactivity_updates(cfg, capellaState[], info)
        ok()
      of "rewards_and_penalties":
        var info = altair.EpochInfo.init(capellaState[])
        process_rewards_and_penalties(cfg, capellaState[], info)
        ok()
      of "registry_updates":
        let regRes = process_registry_updates(cfg, capellaState[], cache)
        if regRes.isErr():
          return err(regRes.error())
        ok()
      of "slashings":
        let info = altair.EpochInfo.init(capellaState[])
        process_slashings(capellaState[], info.balances.current_epoch)
        ok()
      of "eth1_data_reset":
        process_eth1_data_reset(capellaState[])
        ok()
      of "effective_balance_updates":
        process_effective_balance_updates(capellaState[])
        ok()
      of "slashings_reset":
        process_slashings_reset(capellaState[])
        ok()
      of "randao_mixes_reset":
        process_randao_mixes_reset(capellaState[])
        ok()
      of "historical_summaries_update":
        let histRes = process_historical_summaries_update(capellaState[])
        if histRes.isErr():
          return err(histRes.error())
        ok()
      of "participation_flag_updates":
        process_participation_flag_updates(capellaState[])
        ok()
      of "sync_committee_updates":
        process_sync_committee_updates(capellaState[])
        ok()
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
