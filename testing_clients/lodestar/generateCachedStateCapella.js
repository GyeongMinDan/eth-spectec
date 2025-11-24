import fs from 'fs';
import { ssz } from '@lodestar/types';
// import { createCachedBeaconState, PubkeyIndexMap } from '@lodestar/state-transition';
import { createCachedBeaconState, newFilledArray } from '@lodestar/state-transition';
// import { PublicKey } from '@chainsafe/blst';
import { createBeaconConfig } from '@lodestar/config';
import { mainnetChainConfig } from '@lodestar/config/networks';

// Pure Capella network config (CAPELLA_FORK_EPOCH = 0)
const pureCapellaChainConfig = {
  ...mainnetChainConfig,
  ALTAIR_FORK_EPOCH: 0,
  BELLATRIX_FORK_EPOCH: 0,
  CAPELLA_FORK_EPOCH: 0,
  DENEB_FORK_EPOCH: 75520,
};
import {PublicKey} from '@chainsafe/blst' //lodestar v 1.22 changed
import { PubkeyIndexMap } from "@chainsafe/pubkey-index-map"; // lodestar v 1.23 changed


// import pkg from '@chainsafe/blst'
// const { CoordType } = pkg;
// import bls from "@chainsafe/blst";

// import { randomBytes } from 'crypto';
// import { ZERO_HASH } from '@lodestar/state-transition';
// import { GENESIS_EPOCH, GENESIS_SLOT, SLOTS_PER_HISTORICAL_ROOT, EPOCHS_PER_HISTORICAL_VECTOR, EPOCHS_PER_SLASHINGS_VECTOR, SYNC_COMMITTEE_SIZE } from "@lodestar/params";
/**
 * 이미 로드된 `beaconstate`를 사용하여 캐시된 상태를 생성합니다.
 * @param {import("@lodestar/types").capella.BeaconState} beaconstate
 * @param {object} config - 네트워크 설정
 * @returns {import("@lodestar/state-transition").BeaconStateCapella}
 */



export function generateCachedState(beaconstate, config = pureCapellaChainConfig) {
  try {
    // BeaconConfig 생성
    const beaconConfig = createBeaconConfig(config, beaconstate.genesisValidatorsRoot);

    const validatorCount = beaconstate.validators.length;

    const pubkey2index = new PubkeyIndexMap();  // lodestar v1.23 changed
    const index2pubkey = [];

    if (pubkey2index.size !== index2pubkey.length) {
        throw new Error(`Pubkey indices have fallen out of sync: ${pubkey2index.size} != ${index2pubkey.length}`);
    }

    for (let i = pubkey2index.size; i < validatorCount; i++) {
        // View object (from deserializeToView) uses getReadonly method
        // createCachedBeaconState expects View object with getAllReadonlyValues method
        const pubkey = beaconstate.validators.getReadonly(i).pubkey;
        pubkey2index.set(pubkey, i);
        index2pubkey[i] = PublicKey.fromBytes(pubkey) // lodestar v1.22 changed // v1.23 changed

    }   

    return createCachedBeaconState(beaconstate, {
        config: beaconConfig,
        pubkey2index: pubkey2index,
        index2pubkey: index2pubkey,
        //pubkey2index: new Map(),
        //index2pubkey: [],
    }, options);
  } catch (e) {
    // Re-throw error with context
    throw e;
  }
}

const options = {
    skipSyncCommitteeCache: false,
    skipSyncPubkeys: false,
    //shufflingGetter: undefined,
};
