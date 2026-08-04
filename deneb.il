;; spec/spec_deneb/00-types.spectec:5:16-5:19:
syntax bytes = int

;; spec/spec_deneb/00-types.spectec:6:17-6:20:
syntax bytes4 = int

;; spec/spec_deneb/00-types.spectec:7:18-7:21:
syntax bytes32 = int

;; spec/spec_deneb/00-types.spectec:8:17-8:20:
syntax bytes1 = int

;; spec/spec_deneb/00-types.spectec:9:17-9:20:
syntax bytes8 = int

;; spec/spec_deneb/00-types.spectec:10:18-10:21:
syntax bytes20 = int

;; spec/spec_deneb/00-types.spectec:11:18-11:21:
syntax bytes28 = int

;; spec/spec_deneb/00-types.spectec:12:18-12:21:
syntax bytes31 = int

;; spec/spec_deneb/00-types.spectec:13:18-13:21:
syntax bytes48 = int

;; spec/spec_deneb/00-types.spectec:14:18-14:21:
syntax bytes96 = int

;; spec/spec_deneb/00-types.spectec:15:19-15:22:
syntax bytes256 = int

;; spec/spec_deneb/00-types.spectec:16:15-16:18:
syntax uint = nat

;; spec/spec_deneb/00-types.spectec:17:16-17:19:
syntax uint8 = nat

;; spec/spec_deneb/00-types.spectec:18:17-18:20:
syntax uint32 = nat

;; spec/spec_deneb/00-types.spectec:19:17-19:20:
syntax uint64 = nat

;; spec/spec_deneb/00-types.spectec:20:18-20:21:
syntax uint256 = nat

;; spec/spec_deneb/00-types.spectec:27:15-27:21:
syntax slot = uint64

;; spec/spec_deneb/00-types.spectec:28:16-28:22:
syntax epoch = uint64

;; spec/spec_deneb/00-types.spectec:29:25-29:31:
syntax validatorIndex = uint64

;; spec/spec_deneb/00-types.spectec:30:15-30:21:
syntax gwei = uint64

;; spec/spec_deneb/00-types.spectec:31:15-31:22:
syntax root = bytes32

;; spec/spec_deneb/00-types.spectec:32:17-32:24:
syntax hash32 = bytes32

;; spec/spec_deneb/00-types.spectec:33:18-33:24:
syntax version = bytes4

;; spec/spec_deneb/00-types.spectec:34:25-34:31:
syntax committeeIndex = uint64

;; spec/spec_deneb/00-types.spectec:35:18-35:22:
syntax boolean = bool

;; spec/spec_deneb/00-types.spectec:36:21-36:27:
syntax domainType = bytes4

;; spec/spec_deneb/00-types.spectec:37:21-37:27:
syntax forkDigest = bytes4

;; spec/spec_deneb/00-types.spectec:38:17-38:24:
syntax domain = bytes32

;; spec/spec_deneb/00-types.spectec:39:20-39:27:
syntax blsPubkey = bytes48

;; spec/spec_deneb/00-types.spectec:40:23-40:30:
syntax blsSignature = bytes96

;; spec/spec_deneb/00-types.spectec:41:17-41:25:
syntax nodeID = bytes256

;; spec/spec_deneb/00-types.spectec:42:19-42:25:
syntax subnetID = uint64

;; spec/spec_deneb/00-types.spectec:43:16-43:22:
syntax ether = uint64

;; spec/spec_deneb/00-types.spectec:44:29-44:34:
syntax participationFlags = uint8

;; spec/spec_deneb/00-types.spectec:45:27-45:34:
syntax executionAddress = bytes20

;; spec/spec_deneb/00-types.spectec:46:20-46:26:
syntax payloadId = bytes8

;; spec/spec_deneb/00-types.spectec:47:26-47:32:
syntax withdrawalIndex = uint64

;; spec/spec_deneb/00-types.spectec:54:24-54:31:
syntax kzgCommitment = bytes48

;; spec/spec_deneb/00-types.spectec:55:24-55:31:
syntax versionedHash = bytes32

;; spec/spec_deneb/00-types.spectec:56:20-56:26:
syntax blobIndex = uint64

;; spec/spec_deneb/00.1-constants.spectec:4:1-4:25:
def $UINT64_MAX : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:5:1-5:39:
   clause 0 = 18446744073709551615

;; spec/spec_deneb/00.1-constants.spectec:7:1-7:30:
def $UINT64_MAX_SQRT : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:8:1-8:34:
   clause 0 = 4294967295

;; spec/spec_deneb/00.1-constants.spectec:10:1-10:25:
def $GENESIS_SLOT : slot =

   ;; spec/spec_deneb/00.1-constants.spectec:11:1-11:22:
   clause 0 = 0

;; spec/spec_deneb/00.1-constants.spectec:13:1-13:27:
def $GENESIS_EPOCH : epoch =

   ;; spec/spec_deneb/00.1-constants.spectec:14:1-14:23:
   clause 0 = 0

;; spec/spec_deneb/00.1-constants.spectec:16:1-16:30:
def $FAR_FUTURE_EPOCH : epoch =

   ;; spec/spec_deneb/00.1-constants.spectec:17:1-17:45:
   clause 0 = 18446744073709551615

;; spec/spec_deneb/00.1-constants.spectec:19:1-19:37:
def $BASE_REWARDS_PER_EPOCH : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:20:1-20:32:
   clause 0 = 4

;; spec/spec_deneb/00.1-constants.spectec:22:1-22:42:
def $DEPOSIT_CONTRACT_TREE_DEPTH : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:23:1-23:38:
   clause 0 = 32

;; spec/spec_deneb/00.1-constants.spectec:25:1-25:40:
def $JUSTIFICATION_BITS_LENGTH : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:26:1-26:35:
   clause 0 = 4

;; spec/spec_deneb/00.1-constants.spectec:29:1-29:36:
def $BLS_WITHDRAWAL_PREFIX : bytes1 =

   ;; spec/spec_deneb/00.1-constants.spectec:30:1-30:31:
   clause 0 = 0 as bytes1

;; spec/spec_deneb/00.1-constants.spectec:32:1-32:45:
def $ETH1_ADDRESS_WITHDRAWAL_PREFIX : bytes1 =

   ;; spec/spec_deneb/00.1-constants.spectec:33:1-33:40:
   clause 0 = 1 as bytes1

;; spec/spec_deneb/00.1-constants.spectec:35:1-35:41:
def $DOMAIN_BEACON_PROPOSER : domainType =

   ;; spec/spec_deneb/00.1-constants.spectec:36:1-36:32:
   clause 0 = 0 as domainType

;; spec/spec_deneb/00.1-constants.spectec:38:1-38:41:
def $DOMAIN_BEACON_ATTESTER : domainType =

   ;; spec/spec_deneb/00.1-constants.spectec:39:1-39:39:
   clause 0 = 16777216 as domainType

;; spec/spec_deneb/00.1-constants.spectec:41:1-41:32:
def $DOMAIN_RANDAO : domainType =

   ;; spec/spec_deneb/00.1-constants.spectec:42:1-42:30:
   clause 0 = 33554432 as domainType

;; spec/spec_deneb/00.1-constants.spectec:44:1-44:33:
def $DOMAIN_DEPOSIT : domainType =

   ;; spec/spec_deneb/00.1-constants.spectec:45:1-45:31:
   clause 0 = 50331648 as domainType

;; spec/spec_deneb/00.1-constants.spectec:47:1-47:40:
def $DOMAIN_VOLUNTARY_EXIT : domainType =

   ;; spec/spec_deneb/00.1-constants.spectec:48:1-48:38:
   clause 0 = 67108864 as domainType

;; spec/spec_deneb/00.1-constants.spectec:50:1-50:41:
def $DOMAIN_SELECTION_PROOF : domainType =

   ;; spec/spec_deneb/00.1-constants.spectec:51:1-51:39:
   clause 0 = 83886080 as domainType

;; spec/spec_deneb/00.1-constants.spectec:53:1-53:45:
def $DOMAIN_AGGREGATE_AND_PROOF : domainType =

   ;; spec/spec_deneb/00.1-constants.spectec:54:1-54:44:
   clause 0 = 100663296 as domainType

;; spec/spec_deneb/00.1-constants.spectec:56:1-56:42:
def $DOMAIN_APPLICATION_MASK : domainType =

   ;; spec/spec_deneb/00.1-constants.spectec:57:1-57:33:
   clause 0 = 1 as domainType

;; spec/spec_deneb/00.1-constants.spectec:59:1-59:33:
def $INTERVALS_PER_SLOT : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:60:1-60:28:
   clause 0 = 3

;; spec/spec_deneb/00.1-constants.spectec:62:1-62:27:
def $BASIS_POINTS : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:63:1-63:26:
   clause 0 = 10000

;; spec/spec_deneb/00.1-constants.spectec:65:1-65:24:
def $NODE_ID_BITS : nat =

   ;; spec/spec_deneb/00.1-constants.spectec:66:1-66:24:
   clause 0 = 256

;; spec/spec_deneb/00.1-constants.spectec:68:1-68:35:
def $MAX_CONCURRENT_REQUESTS : nat =

   ;; spec/spec_deneb/00.1-constants.spectec:69:1-69:33:
   clause 0 = 2

;; spec/spec_deneb/00.1-constants.spectec:71:1-71:50:
def $TARGET_AGGREGATORS_PER_COMMITTEE_CONST : nat =

   ;; spec/spec_deneb/00.1-constants.spectec:72:1-72:49:
   clause 0 = 16

;; spec/spec_deneb/00.1-constants.spectec:74:1-74:26:
def $ETH_TO_GWEI : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:75:1-75:30:
   clause 0 = 1000000000

;; spec/spec_deneb/00.1-constants.spectec:77:1-77:27:
def $SAFETY_DECAY : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:78:1-78:23:
   clause 0 = 10

;; spec/spec_deneb/00.1-constants.spectec:80:1-80:36:
def $TIMELY_SOURCE_FLAG_INDEX : nat =

   ;; spec/spec_deneb/00.1-constants.spectec:81:1-81:34:
   clause 0 = 0

;; spec/spec_deneb/00.1-constants.spectec:83:1-83:36:
def $TIMELY_TARGET_FLAG_INDEX : nat =

   ;; spec/spec_deneb/00.1-constants.spectec:84:1-84:34:
   clause 0 = 1

;; spec/spec_deneb/00.1-constants.spectec:86:1-86:34:
def $TIMELY_HEAD_FLAG_INDEX : nat =

   ;; spec/spec_deneb/00.1-constants.spectec:87:1-87:32:
   clause 0 = 2

;; spec/spec_deneb/00.1-constants.spectec:89:1-89:35:
def $TIMELY_SOURCE_WEIGHT : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:90:1-90:31:
   clause 0 = 14

;; spec/spec_deneb/00.1-constants.spectec:92:1-92:35:
def $TIMELY_TARGET_WEIGHT : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:93:1-93:31:
   clause 0 = 26

;; spec/spec_deneb/00.1-constants.spectec:95:1-95:33:
def $TIMELY_HEAD_WEIGHT : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:96:1-96:29:
   clause 0 = 14

;; spec/spec_deneb/00.1-constants.spectec:98:1-98:33:
def $SYNC_REWARD_WEIGHT : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:99:1-99:28:
   clause 0 = 2

;; spec/spec_deneb/00.1-constants.spectec:101:1-101:30:
def $PROPOSER_WEIGHT : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:102:1-102:25:
   clause 0 = 8

;; spec/spec_deneb/00.1-constants.spectec:104:1-104:33:
def $WEIGHT_DENOMINATOR : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:105:1-105:29:
   clause 0 = 64

;; spec/spec_deneb/00.1-constants.spectec:107:1-107:40:
def $DOMAIN_SYNC_COMMITTEE : domainType =

   ;; spec/spec_deneb/00.1-constants.spectec:108:1-108:39:
   clause 0 = 117440512 as domainType

;; spec/spec_deneb/00.1-constants.spectec:110:1-110:56:
def $DOMAIN_SYNC_COMMITTEE_SELECTION_PROOF : domainType =

   ;; spec/spec_deneb/00.1-constants.spectec:111:1-111:55:
   clause 0 = 134217728 as domainType

;; spec/spec_deneb/00.1-constants.spectec:113:1-113:48:
def $DOMAIN_CONTRIBUTION_AND_PROOF : domainType =

   ;; spec/spec_deneb/00.1-constants.spectec:114:1-114:47:
   clause 0 = 150994944 as domainType

;; spec/spec_deneb/00.1-constants.spectec:116:1-116:42:
def $PARTICIPATION_FLAG_WEIGHTS : uint64* =

   ;; spec/spec_deneb/00.1-constants.spectec:117:1-117:104:
   clause 0 = [$TIMELY_SOURCE_WEIGHT, $TIMELY_TARGET_WEIGHT, $TIMELY_HEAD_WEIGHT]

;; spec/spec_deneb/00.1-constants.spectec:120:1-120:41:
def $G2_POINT_AT_INFINITY : blsSignature =

   ;; spec/spec_deneb/00.1-constants.spectec:121:1-121:261:
   clause 0 = 1164388569225531701361734616346876916442664512837522458354289028519538214514782664748158806621484858462865798022848304904628685033086110793583215456280885854403341232015637429162698964223698833618947249395287351563169635140362043392 as blsSignature

;; spec/spec_deneb/00.1-constants.spectec:123:1-123:52:
def $TARGET_AGGREGATORS_PER_SYNC_SUBCOMMITTEE : nat =

   ;; spec/spec_deneb/00.1-constants.spectec:124:1-124:51:
   clause 0 = 16

;; spec/spec_deneb/00.1-constants.spectec:126:1-126:39:
def $SYNC_COMMITTEE_SUBNET_COUNT : nat =

   ;; spec/spec_deneb/00.1-constants.spectec:127:1-127:37:
   clause 0 = 4

;; spec/spec_deneb/00.1-constants.spectec:129:1-129:44:
def $MAX_REQUEST_LIGHT_CLIENT_UPDATES : nat =

   ;; spec/spec_deneb/00.1-constants.spectec:130:1-130:44:
   clause 0 = 128

;; spec/spec_deneb/00.1-constants.spectec:132:1-132:47:
def $SAFE_SLOTS_TO_IMPORT_OPTIMISTICALLY : nat =

   ;; spec/spec_deneb/00.1-constants.spectec:133:1-133:47:
   clause 0 = 128

;; spec/spec_deneb/00.1-constants.spectec:135:1-135:49:
def $DOMAIN_BLS_TO_EXECUTION_CHANGE : domainType =

   ;; spec/spec_deneb/00.1-constants.spectec:136:1-136:48:
   clause 0 = 167772160 as domainType

;; spec/spec_deneb/00.1-constants.spectec:143:1-143:38:
def $MAX_COMMITTEES_PER_SLOT : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:144:1-144:34:
   clause 0 = 64

;; spec/spec_deneb/00.1-constants.spectec:146:1-146:36:
def $TARGET_COMMITTEE_SIZE : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:147:1-147:33:
   clause 0 = 128

;; spec/spec_deneb/00.1-constants.spectec:149:1-149:43:
def $MAX_VALIDATORS_PER_COMMITTEE : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:150:1-150:41:
   clause 0 = 2048

;; spec/spec_deneb/00.1-constants.spectec:152:1-152:34:
def $SHUFFLE_ROUND_COUNT : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:153:1-153:30:
   clause 0 = 90

;; spec/spec_deneb/00.1-constants.spectec:155:1-155:34:
def $HYSTERESIS_QUOTIENT : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:156:1-156:29:
   clause 0 = 4

;; spec/spec_deneb/00.1-constants.spectec:158:1-158:45:
def $HYSTERESIS_DOWNWARD_MULTIPLIER : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:159:1-159:40:
   clause 0 = 1

;; spec/spec_deneb/00.1-constants.spectec:161:1-161:43:
def $HYSTERESIS_UPWARD_MULTIPLIER : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:162:1-162:38:
   clause 0 = 5

;; spec/spec_deneb/00.1-constants.spectec:164:1-164:31:
def $MIN_DEPOSIT_AMOUNT : gwei =

   ;; spec/spec_deneb/00.1-constants.spectec:165:1-165:37:
   clause 0 = 1000000000

;; spec/spec_deneb/00.1-constants.spectec:167:1-167:34:
def $MAX_EFFECTIVE_BALANCE : gwei =

   ;; spec/spec_deneb/00.1-constants.spectec:168:1-168:41:
   clause 0 = 32000000000

;; spec/spec_deneb/00.1-constants.spectec:170:1-170:40:
def $EFFECTIVE_BALANCE_INCREMENT : gwei =

   ;; spec/spec_deneb/00.1-constants.spectec:171:1-171:46:
   clause 0 = 1000000000

;; spec/spec_deneb/00.1-constants.spectec:173:1-173:46:
def $MIN_ATTESTATION_INCLUSION_DELAY : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:174:1-174:41:
   clause 0 = 1

;; spec/spec_deneb/00.1-constants.spectec:176:1-176:30:
def $SLOTS_PER_EPOCH : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:177:1-177:26:
   clause 0 = 32

;; spec/spec_deneb/00.1-constants.spectec:179:1-179:33:
def $MIN_SEED_LOOKAHEAD : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:180:1-180:28:
   clause 0 = 1

;; spec/spec_deneb/00.1-constants.spectec:182:1-182:33:
def $MAX_SEED_LOOKAHEAD : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:183:1-183:28:
   clause 0 = 4

;; spec/spec_deneb/00.1-constants.spectec:185:1-185:47:
def $MIN_EPOCHS_TO_INACTIVITY_PENALTY : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:186:1-186:42:
   clause 0 = 4

;; spec/spec_deneb/00.1-constants.spectec:188:1-188:44:
def $EPOCHS_PER_ETH1_VOTING_PERIOD : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:189:1-189:40:
   clause 0 = 64

;; spec/spec_deneb/00.1-constants.spectec:191:1-191:40:
def $SLOTS_PER_HISTORICAL_ROOT : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:192:1-192:38:
   clause 0 = 8192

;; spec/spec_deneb/00.1-constants.spectec:194:1-194:43:
def $EPOCHS_PER_HISTORICAL_VECTOR : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:195:1-195:42:
   clause 0 = 65536

;; spec/spec_deneb/00.1-constants.spectec:197:1-197:42:
def $EPOCHS_PER_SLASHINGS_VECTOR : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:198:1-198:40:
   clause 0 = 8192

;; spec/spec_deneb/00.1-constants.spectec:200:1-200:37:
def $HISTORICAL_ROOTS_LIMIT : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:201:1-201:39:
   clause 0 = 16777216

;; spec/spec_deneb/00.1-constants.spectec:203:1-203:39:
def $VALIDATOR_REGISTRY_LIMIT : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:204:1-204:46:
   clause 0 = 1099511627776

;; spec/spec_deneb/00.1-constants.spectec:206:1-206:33:
def $BASE_REWARD_FACTOR : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:207:1-207:29:
   clause 0 = 64

;; spec/spec_deneb/00.1-constants.spectec:209:1-209:44:
def $WHISTLEBLOWER_REWARD_QUOTIENT : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:210:1-210:41:
   clause 0 = 512

;; spec/spec_deneb/00.1-constants.spectec:212:1-212:39:
def $PROPOSER_REWARD_QUOTIENT : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:213:1-213:34:
   clause 0 = 8

;; spec/spec_deneb/00.1-constants.spectec:215:1-215:42:
def $INACTIVITY_PENALTY_QUOTIENT : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:216:1-216:44:
   clause 0 = 67108864

;; spec/spec_deneb/00.1-constants.spectec:218:1-218:44:
def $MIN_SLASHING_PENALTY_QUOTIENT : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:219:1-219:41:
   clause 0 = 128

;; spec/spec_deneb/00.1-constants.spectec:221:1-221:47:
def $PROPORTIONAL_SLASHING_MULTIPLIER : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:222:1-222:42:
   clause 0 = 1

;; spec/spec_deneb/00.1-constants.spectec:224:1-224:34:
def $MAX_PROPOSER_SLASHINGS : nat =

   ;; spec/spec_deneb/00.1-constants.spectec:225:1-225:33:
   clause 0 = 16

;; spec/spec_deneb/00.1-constants.spectec:227:1-227:34:
def $MAX_ATTESTER_SLASHINGS : nat =

   ;; spec/spec_deneb/00.1-constants.spectec:228:1-228:32:
   clause 0 = 2

;; spec/spec_deneb/00.1-constants.spectec:230:1-230:28:
def $MAX_ATTESTATIONS : nat =

   ;; spec/spec_deneb/00.1-constants.spectec:231:1-231:28:
   clause 0 = 128

;; spec/spec_deneb/00.1-constants.spectec:233:1-233:24:
def $MAX_DEPOSITS : nat =

   ;; spec/spec_deneb/00.1-constants.spectec:234:1-234:23:
   clause 0 = 16

;; spec/spec_deneb/00.1-constants.spectec:236:1-236:31:
def $MAX_VOLUNTARY_EXITS : nat =

   ;; spec/spec_deneb/00.1-constants.spectec:237:1-237:30:
   clause 0 = 16

;; spec/spec_deneb/00.1-constants.spectec:239:1-239:49:
def $INACTIVITY_PENALTY_QUOTIENT_ALTAIR : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:240:1-240:51:
   clause 0 = 50331648

;; spec/spec_deneb/00.1-constants.spectec:242:1-242:51:
def $MIN_SLASHING_PENALTY_QUOTIENT_ALTAIR : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:243:1-243:47:
   clause 0 = 64

;; spec/spec_deneb/00.1-constants.spectec:245:1-245:54:
def $PROPORTIONAL_SLASHING_MULTIPLIER_ALTAIR : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:246:1-246:49:
   clause 0 = 2

;; spec/spec_deneb/00.1-constants.spectec:248:1-248:34:
def $SYNC_COMMITTEE_SIZE : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:249:1-249:31:
   clause 0 = 512

;; spec/spec_deneb/00.1-constants.spectec:251:1-251:47:
def $EPOCHS_PER_SYNC_COMMITTEE_PERIOD : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:252:1-252:44:
   clause 0 = 256

;; spec/spec_deneb/00.1-constants.spectec:254:1-254:43:
def $MIN_SYNC_COMMITTEE_PARTICIPANTS : nat =

   ;; spec/spec_deneb/00.1-constants.spectec:255:1-255:41:
   clause 0 = 1

;; spec/spec_deneb/00.1-constants.spectec:257:1-257:26:
def $UPDATE_TIMEOUT : nat =

   ;; spec/spec_deneb/00.1-constants.spectec:258:1-258:27:
   clause 0 = 8192

;; spec/spec_deneb/00.1-constants.spectec:260:1-260:52:
def $INACTIVITY_PENALTY_QUOTIENT_BELLATRIX : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:261:1-261:54:
   clause 0 = 16777216

;; spec/spec_deneb/00.1-constants.spectec:263:1-263:54:
def $MIN_SLASHING_PENALTY_QUOTIENT_BELLATRIX : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:264:1-264:50:
   clause 0 = 32

;; spec/spec_deneb/00.1-constants.spectec:266:1-266:57:
def $PROPORTIONAL_SLASHING_MULTIPLIER_BELLATRIX : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:267:1-267:52:
   clause 0 = 3

;; spec/spec_deneb/00.1-constants.spectec:269:1-269:40:
def $MAX_BYTES_PER_TRANSACTION : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:270:1-270:44:
   clause 0 = 1073741824

;; spec/spec_deneb/00.1-constants.spectec:272:1-272:43:
def $MAX_TRANSACTIONS_PER_PAYLOAD : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:273:1-273:44:
   clause 0 = 1048576

;; spec/spec_deneb/00.1-constants.spectec:275:1-275:35:
def $BYTES_PER_LOGS_BLOOM : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:276:1-276:32:
   clause 0 = 256

;; spec/spec_deneb/00.1-constants.spectec:278:1-278:32:
def $MAX_EXTRA_DATA_BYTES : nat =

   ;; spec/spec_deneb/00.1-constants.spectec:279:1-279:31:
   clause 0 = 32

;; spec/spec_deneb/00.1-constants.spectec:281:1-281:43:
def $MAX_BLS_TO_EXECUTION_CHANGES : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:282:1-282:39:
   clause 0 = 16

;; spec/spec_deneb/00.1-constants.spectec:284:1-284:42:
def $MAX_WITHDRAWALS_PER_PAYLOAD : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:285:1-285:38:
   clause 0 = 16

;; spec/spec_deneb/00.1-constants.spectec:287:1-287:51:
def $MAX_VALIDATORS_PER_WITHDRAWALS_SWEEP : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:288:1-288:50:
   clause 0 = 16384

;; spec/spec_deneb/00.1-constants.spectec:292:1-292:49:
def $MIN_GENESIS_ACTIVE_VALIDATOR_COUNT : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:293:1-293:48:
   clause 0 = 16384

;; spec/spec_deneb/00.1-constants.spectec:295:1-295:31:
def $MIN_GENESIS_TIME : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:296:1-296:35:
   clause 0 = 1606824000

;; spec/spec_deneb/00.1-constants.spectec:298:1-298:36:
def $GENESIS_FORK_VERSION : version =

   ;; spec/spec_deneb/00.1-constants.spectec:299:1-299:30:
   clause 0 = 0 as version

;; spec/spec_deneb/00.1-constants.spectec:301:1-301:28:
def $GENESIS_DELAY : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:302:1-302:28:
   clause 0 = 604800

;; spec/spec_deneb/00.1-constants.spectec:304:1-304:31:
def $SECONDS_PER_SLOT : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:305:1-305:27:
   clause 0 = 12

;; spec/spec_deneb/00.1-constants.spectec:307:1-307:31:
def $SLOT_DURATION_MS : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:308:1-308:30:
   clause 0 = 12000

;; spec/spec_deneb/00.1-constants.spectec:310:1-310:37:
def $SECONDS_PER_ETH1_BLOCK : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:311:1-311:33:
   clause 0 = 14

;; spec/spec_deneb/00.1-constants.spectec:313:1-313:50:
def $MIN_VALIDATOR_WITHDRAWABILITY_DELAY : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:314:1-314:47:
   clause 0 = 256

;; spec/spec_deneb/00.1-constants.spectec:316:1-316:37:
def $SHARD_COMMITTEE_PERIOD : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:317:1-317:34:
   clause 0 = 256

;; spec/spec_deneb/00.1-constants.spectec:319:1-319:35:
def $ETH1_FOLLOW_DISTANCE : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:320:1-320:33:
   clause 0 = 2048

;; spec/spec_deneb/00.1-constants.spectec:322:1-322:29:
def $EJECTION_BALANCE : gwei =

   ;; spec/spec_deneb/00.1-constants.spectec:323:1-323:36:
   clause 0 = 16000000000

;; spec/spec_deneb/00.1-constants.spectec:325:1-325:40:
def $MIN_PER_EPOCH_CHURN_LIMIT : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:326:1-326:35:
   clause 0 = 4

;; spec/spec_deneb/00.1-constants.spectec:328:1-328:35:
def $CHURN_LIMIT_QUOTIENT : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:329:1-329:34:
   clause 0 = 65536

;; spec/spec_deneb/00.1-constants.spectec:331:1-331:35:
def $PROPOSER_SCORE_BOOST : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:332:1-332:31:
   clause 0 = 40

;; spec/spec_deneb/00.1-constants.spectec:334:1-334:42:
def $REORG_HEAD_WEIGHT_THRESHOLD : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:335:1-335:38:
   clause 0 = 20

;; spec/spec_deneb/00.1-constants.spectec:337:1-337:44:
def $REORG_PARENT_WEIGHT_THRESHOLD : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:338:1-338:41:
   clause 0 = 160

;; spec/spec_deneb/00.1-constants.spectec:340:1-340:49:
def $REORG_MAX_EPOCHS_SINCE_FINALIZATION : epoch =

   ;; spec/spec_deneb/00.1-constants.spectec:341:1-341:45:
   clause 0 = 2

;; spec/spec_deneb/00.1-constants.spectec:343:1-343:40:
def $PROPOSER_REORG_CUTOFF_BPS : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:344:1-344:38:
   clause 0 = 1667

;; spec/spec_deneb/00.1-constants.spectec:346:1-346:28:
def $MAX_PAYLOAD_SIZE : nat =

   ;; spec/spec_deneb/00.1-constants.spectec:347:1-347:33:
   clause 0 = 10485760

;; spec/spec_deneb/00.1-constants.spectec:349:1-349:30:
def $MAX_REQUEST_BLOCKS : nat =

   ;; spec/spec_deneb/00.1-constants.spectec:350:1-350:31:
   clause 0 = 1024

;; spec/spec_deneb/00.1-constants.spectec:352:1-352:42:
def $EPOCHS_PER_SUBNET_SUBSCRIPTION : nat =

   ;; spec/spec_deneb/00.1-constants.spectec:353:1-353:42:
   clause 0 = 256

;; spec/spec_deneb/00.1-constants.spectec:355:1-355:41:
def $MIN_EPOCHS_FOR_BLOCK_REQUESTS : nat =

   ;; spec/spec_deneb/00.1-constants.spectec:356:1-356:43:
   clause 0 = 33024

;; spec/spec_deneb/00.1-constants.spectec:358:1-358:46:
def $ATTESTATION_PROPAGATION_SLOT_RANGE : nat =

   ;; spec/spec_deneb/00.1-constants.spectec:359:1-359:45:
   clause 0 = 32

;; spec/spec_deneb/00.1-constants.spectec:361:1-361:42:
def $MAXIMUM_GOSSIP_CLOCK_DISPARITY : nat =

   ;; spec/spec_deneb/00.1-constants.spectec:362:1-362:42:
   clause 0 = 500

;; spec/spec_deneb/00.1-constants.spectec:364:1-364:48:
def $MESSAGE_DOMAIN_INVALID_SNAPPY : domainType =

   ;; spec/spec_deneb/00.1-constants.spectec:365:1-365:39:
   clause 0 = 0 as domainType

;; spec/spec_deneb/00.1-constants.spectec:367:1-367:46:
def $MESSAGE_DOMAIN_VALID_SNAPPY : domainType =

   ;; spec/spec_deneb/00.1-constants.spectec:368:1-368:44:
   clause 0 = 16777216 as domainType

;; spec/spec_deneb/00.1-constants.spectec:370:1-370:28:
def $SUBNETS_PER_NODE : nat =

   ;; spec/spec_deneb/00.1-constants.spectec:371:1-371:26:
   clause 0 = 2

;; spec/spec_deneb/00.1-constants.spectec:373:1-373:36:
def $ATTESTATION_SUBNET_COUNT : nat =

   ;; spec/spec_deneb/00.1-constants.spectec:374:1-374:35:
   clause 0 = 64

;; spec/spec_deneb/00.1-constants.spectec:376:1-376:41:
def $ATTESTATION_SUBNET_EXTRA_BITS : nat =

   ;; spec/spec_deneb/00.1-constants.spectec:377:1-377:39:
   clause 0 = 0

;; spec/spec_deneb/00.1-constants.spectec:379:1-379:42:
def $ATTESTATION_SUBNET_PREFIX_BITS : nat =

   ;; spec/spec_deneb/00.1-constants.spectec:380:1-380:40:
   clause 0 = 6

;; spec/spec_deneb/00.1-constants.spectec:382:1-382:34:
def $ATTESTATION_DUE_BPS : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:383:1-383:32:
   clause 0 = 3333

;; spec/spec_deneb/00.1-constants.spectec:385:1-385:32:
def $AGGREGATE_DUE_BPS : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:386:1-386:30:
   clause 0 = 6667

;; spec/spec_deneb/00.1-constants.spectec:388:1-388:36:
def $INACTIVITY_SCORE_BIAS : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:389:1-389:31:
   clause 0 = 4

;; spec/spec_deneb/00.1-constants.spectec:391:1-391:45:
def $INACTIVITY_SCORE_RECOVERY_RATE : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:392:1-392:41:
   clause 0 = 16

;; spec/spec_deneb/00.1-constants.spectec:394:1-394:35:
def $ALTAIR_FORK_VERSION : version =

   ;; spec/spec_deneb/00.1-constants.spectec:395:1-395:36:
   clause 0 = 16777216 as version

;; spec/spec_deneb/00.1-constants.spectec:397:1-397:31:
def $ALTAIR_FORK_EPOCH : epoch =

   ;; spec/spec_deneb/00.1-constants.spectec:398:1-398:31:
   clause 0 = 74240

;; spec/spec_deneb/00.1-constants.spectec:400:1-400:35:
def $SYNC_MESSAGE_DUE_BPS : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:401:1-401:33:
   clause 0 = 3333

;; spec/spec_deneb/00.1-constants.spectec:403:1-403:35:
def $CONTRIBUTION_DUE_BPS : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:404:1-404:33:
   clause 0 = 6667

;; spec/spec_deneb/00.1-constants.spectec:406:1-406:41:
def $TERMINAL_TOTAL_DIFFICULTY : uint256 =

   ;; spec/spec_deneb/00.1-constants.spectec:407:1-407:57:
   clause 0 = 58750000000000000000000

;; spec/spec_deneb/00.1-constants.spectec:409:1-409:34:
def $TERMINAL_BLOCK_HASH : hash32 =

   ;; spec/spec_deneb/00.1-constants.spectec:410:1-410:29:
   clause 0 = 0 as hash32

;; spec/spec_deneb/00.1-constants.spectec:412:1-412:50:
def $TERMINAL_BLOCK_HASH_ACTIVATION_EPOCH : epoch =

   ;; spec/spec_deneb/00.1-constants.spectec:413:1-413:62:
   clause 0 = $FAR_FUTURE_EPOCH

;; spec/spec_deneb/00.1-constants.spectec:415:1-415:38:
def $BELLATRIX_FORK_VERSION : version =

   ;; spec/spec_deneb/00.1-constants.spectec:416:1-416:39:
   clause 0 = 33554432 as version

;; spec/spec_deneb/00.1-constants.spectec:418:1-418:34:
def $BELLATRIX_FORK_EPOCH : epoch =

   ;; spec/spec_deneb/00.1-constants.spectec:419:1-419:35:
   clause 0 = 144896

;; spec/spec_deneb/00.1-constants.spectec:421:1-421:36:
def $CAPELLA_FORK_VERSION : version =

   ;; spec/spec_deneb/00.1-constants.spectec:422:1-422:37:
   clause 0 = 50331648 as version

;; spec/spec_deneb/00.1-constants.spectec:424:1-424:32:
def $CAPELLA_FORK_EPOCH : epoch =

   ;; spec/spec_deneb/00.1-constants.spectec:425:1-425:33:
   clause 0 = 194048

;; spec/spec_deneb/00.1-constants.spectec:429:1-429:22:
def $ZERO_ROOT : root =

   ;; spec/spec_deneb/00.1-constants.spectec:430:1-430:19:
   clause 0 = 0 as root

;; spec/spec_deneb/00.1-constants.spectec:435:1-435:30:
def $MAX_RANDOM_BYTE : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:436:1-436:27:
   clause 0 = 255

;; spec/spec_deneb/00.1-constants.spectec:440:1-440:41:
def $VERSIONED_HASH_VERSION_KZG : bytes1 =

   ;; spec/spec_deneb/00.1-constants.spectec:441:1-441:36:
   clause 0 = 1 as bytes1

;; spec/spec_deneb/00.1-constants.spectec:443:1-443:45:
def $MAX_BLOB_COMMITMENTS_PER_BLOCK : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:444:1-444:43:
   clause 0 = 4096

;; spec/spec_deneb/00.1-constants.spectec:446:1-446:34:
def $MAX_BLOBS_PER_BLOCK : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:447:1-447:29:
   clause 0 = 6

;; spec/spec_deneb/00.1-constants.spectec:449:1-449:51:
def $MAX_PER_EPOCH_ACTIVATION_CHURN_LIMIT : uint64 =

   ;; spec/spec_deneb/00.1-constants.spectec:450:1-450:46:
   clause 0 = 8

;; spec/spec_deneb/00.2-containers.spectec:8:3-10:18:
syntax fork = {PREVIOUS_VERSION version, CURRENT_VERSION version, EPOCH epoch}

;; spec/spec_deneb/00.2-containers.spectec:13:3-17:21:
syntax beaconBlockHeader = {SLOT slot, PROPOSER_INDEX validatorIndex, PARENT_ROOT root, STATE_ROOT root, BODY_ROOT root}

;; spec/spec_deneb/00.2-containers.spectec:20:3-22:24:
syntax eth1Data = {DEPOSIT_ROOT root, DEPOSIT_COUNT uint64, BLOCK_HASH hash32}

;; spec/spec_deneb/00.2-containers.spectec:25:3-32:31:
syntax validator = {PUBKEY blsPubkey, WITHDRAWAL_CREDENTIALS bytes32, EFFECTIVE_BALANCE gwei, SLASHED bool, ACTIVATION_ELIGIBILITY_EPOCH epoch, ACTIVATION_EPOCH epoch, EXIT_EPOCH epoch, WITHDRAWABLE_EPOCH epoch}

;; spec/spec_deneb/00.2-containers.spectec:35:3-36:16:
syntax checkpoint = {EPOCH epoch, ROOT root}

;; spec/spec_deneb/00.2-containers.spectec:39:3-40:33:
syntax syncCommittee = {PUBKEYS blsPubkey*, AGGREGATE_PUBKEY blsPubkey}

;; spec/spec_deneb/00.2-containers.spectec:43:3-60:29:
syntax executionPayloadHeader = {PARENT_HASH hash32, FEE_RECIPIENT executionAddress, STATE_ROOT bytes32, RECEIPTS_ROOT bytes32, LOGS_BLOOM bytes256, PREV_RANDAO bytes32, BLOCK_NUMBER uint64, GAS_LIMIT uint64, GAS_USED uint64, TIMESTAMP uint64, EXTRA_DATA bytes, BASE_FEE_PER_GAS uint256, BLOCK_HASH hash32, TRANSACTIONS_ROOT root, WITHDRAWALS_ROOT root, BLOB_GAS_USED uint64, EXCESS_BLOB_GAS uint64}

;; spec/spec_deneb/00.2-containers.spectec:63:3-64:30:
syntax historicalSummary = {BLOCK_SUMMARY_ROOT root, STATE_SUMMARY_ROOT root}

;; spec/spec_deneb/00.2-containers.spectec:67:3-94:46:
syntax beaconState = {GENESIS_TIME uint64, GENESIS_VALIDATORS_ROOT bytes32, SLOT slot, FORK fork, LATEST_BLOCK_HEADER beaconBlockHeader, BLOCK_ROOTS root*, STATE_ROOTS root*, HISTORICAL_ROOTS root*, ETH1_DATA eth1Data, ETH1_DATA_VOTES eth1Data*, ETH1_DEPOSIT_INDEX uint64, VALIDATORS validator*, BALANCES gwei*, RANDAO_MIXES bytes32*, SLASHINGS gwei*, PREVIOUS_EPOCH_PARTICIPATION participationFlags*, CURRENT_EPOCH_PARTICIPATION participationFlags*, JUSTIFICATION_BITS bool*, PREVIOUS_JUSTIFIED_CHECKPOINT checkpoint, CURRENT_JUSTIFIED_CHECKPOINT checkpoint, FINALIZED_CHECKPOINT checkpoint, INACTIVITY_SCORES uint64*, CURRENT_SYNC_COMMITTEE syncCommittee, NEXT_SYNC_COMMITTEE syncCommittee, LATEST_EXECUTION_PAYLOAD_HEADER executionPayloadHeader, NEXT_WITHDRAWAL_INDEX withdrawalIndex, NEXT_WITHDRAWAL_VALIDATOR_INDEX validatorIndex, HISTORICAL_SUMMARIES historicalSummary*}

;; spec/spec_deneb/00.2-containers.spectec:101:3-102:29:
syntax signedBeaconBlockHeader = {MESSAGE beaconBlockHeader, SIGNATURE blsSignature}

;; spec/spec_deneb/00.2-containers.spectec:105:3-106:46:
syntax proposerSlashing = {SIGNED_HEADER_1 signedBeaconBlockHeader, SIGNED_HEADER_2 signedBeaconBlockHeader}

;; spec/spec_deneb/00.2-containers.spectec:111:3-115:24:
syntax attestationData = {SLOT slot, INDEX committeeIndex, BEACON_BLOCK_ROOT root, SOURCE checkpoint, TARGET checkpoint}

;; spec/spec_deneb/00.2-containers.spectec:118:3-120:29:
syntax indexedAttestation = {ATTESTING_INDICES validatorIndex*, DATA attestationData, SIGNATURE blsSignature}

;; spec/spec_deneb/00.2-containers.spectec:123:3-124:39:
syntax attesterSlashing = {ATTESTATION_1 indexedAttestation, ATTESTATION_2 indexedAttestation}

;; spec/spec_deneb/00.2-containers.spectec:129:3-131:29:
syntax attestation = {AGGREGATION_BITS bool*, DATA attestationData, SIGNATURE blsSignature}

;; spec/spec_deneb/00.2-containers.spectec:136:3-139:29:
syntax depositData = {PUBKEY blsPubkey, WITHDRAWAL_CREDENTIALS bytes32, AMOUNT gwei, SIGNATURE blsSignature}

;; spec/spec_deneb/00.2-containers.spectec:142:3-143:23:
syntax deposit = {PROOF bytes32*, DATA depositData}

;; spec/spec_deneb/00.2-containers.spectec:148:3-149:37:
syntax voluntaryExit = {EPOCH epoch, VALIDATOR_INDEX validatorIndex}

;; spec/spec_deneb/00.2-containers.spectec:152:3-153:29:
syntax signedVoluntaryExit = {MESSAGE voluntaryExit, SIGNATURE blsSignature}

;; spec/spec_deneb/00.2-containers.spectec:158:3-159:44:
syntax syncAggregate = {SYNC_COMMITTEE_BITS bool*, SYNC_COMMITTEE_SIGNATURE blsSignature}

;; spec/spec_deneb/00.2-containers.spectec:164:3-167:18:
syntax withdrawal = {INDEX withdrawalIndex, VALIDATOR_INDEX validatorIndex, ADDRESS executionAddress, AMOUNT gwei}

;; spec/spec_deneb/00.2-containers.spectec:170:3-187:29:
syntax executionPayload = {PARENT_HASH hash32, FEE_RECIPIENT executionAddress, STATE_ROOT bytes32, RECEIPTS_ROOT bytes32, LOGS_BLOOM bytes256, PREV_RANDAO bytes32, BLOCK_NUMBER uint64, GAS_LIMIT uint64, GAS_USED uint64, TIMESTAMP uint64, EXTRA_DATA bytes, BASE_FEE_PER_GAS uint256, BLOCK_HASH hash32, TRANSACTIONS bytes*, WITHDRAWALS withdrawal*, BLOB_GAS_USED uint64, EXCESS_BLOB_GAS uint64}

;; spec/spec_deneb/00.2-containers.spectec:192:3-194:44:
syntax blsToExecutionChange = {VALIDATOR_INDEX validatorIndex, FROM_BLS_PUBKEY blsPubkey, TO_EXECUTION_ADDRESS executionAddress}

;; spec/spec_deneb/00.2-containers.spectec:197:3-198:29:
syntax signedBlsToExecutionChange = {MESSAGE blsToExecutionChange, SIGNATURE blsSignature}

;; spec/spec_deneb/00.2-containers.spectec:201:3-218:4:
syntax beaconBlockBody = {RANDAO_REVEAL blsSignature, ETH1_DATA eth1Data, GRAFFITI bytes32, PROPOSER_SLASHINGS proposerSlashing*, ATTESTER_SLASHINGS attesterSlashing*, ATTESTATIONS attestation*, DEPOSITS deposit*, VOLUNTARY_EXITS signedVoluntaryExit*, SYNC_AGGREGATE syncAggregate, EXECUTION_PAYLOAD executionPayload, BLS_TO_EXECUTION_CHANGES signedBlsToExecutionChange*, BLOB_KZG_COMMITMENTS kzgCommitment*}

;; spec/spec_deneb/00.2-containers.spectec:221:3-225:27:
syntax beaconBlock = {SLOT slot, PROPOSER_INDEX validatorIndex, PARENT_ROOT root, STATE_ROOT root, BODY beaconBlockBody}

;; spec/spec_deneb/00.2-containers.spectec:228:3-229:29:
syntax signedBeaconBlock = {MESSAGE beaconBlock, SIGNATURE blsSignature}

;; spec/spec_deneb/00.2-containers.spectec:233:3-234:35:
syntax forkdata = {CURRENT_VERSION version, GENESIS_VALIDATORS_ROOT root}

;; spec/spec_deneb/00.2-containers.spectec:237:3-239:18:
syntax depositMessage = {PUBKEY blsPubkey, WITHDRAWAL_CREDENTIALS bytes32, AMOUNT gwei}

;; spec/spec_deneb/00.2-containers.spectec:242:3-244:18:
syntax seedInput = {DOMAIN domainType, BYTES bytes, MIX bytes32}

;; spec/spec_deneb/00.2-containers.spectec:246:25-246:33:
syntax enumerated_<X> = (nat, X)

;; spec/spec_deneb/02-builtins-dec-only.spectec:6:1-6:57:
def $bls_verify(blsPubkey, root, blsSignature) : boolean =

;; spec/spec_deneb/02-builtins-dec-only.spectec:7:1-7:73:
def $bls_fast_aggregate_verify(blsPubkey*, root, blsSignature) : boolean =

;; spec/spec_deneb/02-builtins-dec-only.spectec:8:1-8:51:
def $eth_aggregate_pubkeys(blsPubkey*) : blsPubkey =

;; spec/spec_deneb/02-builtins-dec-only.spectec:11:1-11:27:
def $hash_<X>(X) : bytes32 =

;; spec/spec_deneb/02-builtins-dec-only.spectec:14:1-14:28:
def $debug_print_<X>(X) : X =

;; spec/spec_deneb/02-builtins-dec-only.spectec:15:1-15:40:
def $debug_print_label_<X>(text, X) : X =

;; spec/spec_deneb/02-builtins-dec-only.spectec:18:1-18:64:
def $hash_tree_root_beaconBlockHeader(beaconBlockHeader) : root =

;; spec/spec_deneb/02-builtins-dec-only.spectec:19:1-19:60:
def $hash_tree_root_beaconBlockBody(beaconBlockBody) : root =

;; spec/spec_deneb/02-builtins-dec-only.spectec:20:1-20:52:
def $hash_tree_root_depositData(depositData) : root =

;; spec/spec_deneb/02-builtins-dec-only.spectec:21:1-21:46:
def $hash_tree_root_forkdata(forkdata) : root =

;; spec/spec_deneb/02-builtins-dec-only.spectec:22:1-22:52:
def $hash_tree_root_beaconState(beaconState) : root =

;; spec/spec_deneb/02-builtins-dec-only.spectec:23:1-23:52:
def $hash_tree_root_withdrawals(withdrawal*) : root =

;; spec/spec_deneb/02-builtins-dec-only.spectec:24:1-24:52:
def $hash_tree_root_beaconBlock(beaconBlock) : root =

;; spec/spec_deneb/02-builtins-dec-only.spectec:26:1-26:40:
def $hash_tree_root_roots(root*) : root =

;; spec/spec_deneb/02-builtins-dec-only.spectec:27:1-27:38:
def $hash_tree_root_tx(bytes*) : root =

;; spec/spec_deneb/02-builtins-dec-only.spectec:31:1-31:54:
def $compute_signing_root_epoch(epoch, domain) : root =

;; spec/spec_deneb/02-builtins-dec-only.spectec:32:1-32:71:
def $compute_signing_root_voluntary_exit(voluntaryExit, domain) : root =

;; spec/spec_deneb/02-builtins-dec-only.spectec:33:1-33:87:
def $compute_signing_root_bls_to_execution_change(blsToExecutionChange, domain) : root =

;; spec/spec_deneb/02-builtins-dec-only.spectec:34:1-34:78:
def $compute_signing_root_beaconBlockHeader(beaconBlockHeader, domain) : root =

;; spec/spec_deneb/02-builtins-dec-only.spectec:35:1-35:74:
def $compute_signing_root_attestationData(attestationData, domain) : root =

;; spec/spec_deneb/02-builtins-dec-only.spectec:36:1-36:72:
def $compute_signing_root_depositMessage(depositMessage, domain) : root =

;; spec/spec_deneb/02-builtins-dec-only.spectec:37:1-37:61:
def $compute_signing_root_block_root(bytes32, domain) : root =

;; spec/spec_deneb/02-builtins-dec-only.spectec:38:1-38:66:
def $compute_signing_root_beaconBlock(beaconBlock, domain) : root =

;; spec/spec_deneb/02-builtins-dec-only.spectec:41:1-41:79:
def $is_valid_merkle_branch(bytes32, bytes32*, uint64, uint64, root) : boolean =

;; spec/spec_deneb/02-builtins-dec-only.spectec:43:1-43:42:
def $integer_square_root(uint64) : uint64 =

;; spec/spec_deneb/02-builtins-dec-only.spectec:46:1-46:40:
def $count_occurrences_<X>(X*, X) : nat =

;; spec/spec_deneb/02-builtins-dec-only.spectec:49:1-49:21:
def $pow2(nat) : nat =

;; spec/spec_deneb/02-builtins-dec-only.spectec:52:1-52:25:
def $to_set_<X>(X*) : X* =

;; spec/spec_deneb/02-builtins-dec-only.spectec:55:1-55:21:
def $sum_<X>(X*) : X =

;; spec/spec_deneb/02-builtins-dec-only.spectec:58:1-58:29:
def $repeat_<X>(X, nat) : X* =

;; spec/spec_deneb/02-builtins-dec-only.spectec:61:1-61:23:
def $sort_<X>(X*) : X* =

;; spec/spec_deneb/02-builtins-dec-only.spectec:64:1-64:39:
def $set_intersection_<X>(X*, X*) : X* =

;; spec/spec_deneb/02-builtins-dec-only.spectec:69:1-69:45:
def $set_or_append_list_<X>(X*, nat, X) : X* =

;; spec/spec_deneb/02-builtins-dec-only.spectec:73:1-73:23:
def $range(nat) : nat* =

;; spec/spec_deneb/02-builtins-dec-only.spectec:76:1-76:41:
def $enumerate_<X>(X*) : enumerated_<X>* =

;; spec/spec_deneb/02-builtins-dec-only.spectec:80:1-80:39:
def $bytes_to_uint64(bytes32) : uint64 =

;; spec/spec_deneb/02-builtins-dec-only.spectec:81:1-81:33:
def $uint_to_bytes(uint) : bytes =

;; spec/spec_deneb/02-builtins-dec-only.spectec:82:1-82:37:
def $xor(bytes32, bytes32) : bytes32 =

;; spec/spec_deneb/02-builtins-dec-only.spectec:83:1-83:39:
def $first_28_bytes(bytes32) : bytes28 =

;; spec/spec_deneb/02-builtins-dec-only.spectec:84:1-84:38:
def $get_first_byte(bytes32) : bytes1 =

;; spec/spec_deneb/02-builtins-dec-only.spectec:85:1-85:41:
def $strip_first_byte(bytes32) : bytes31 =

;; spec/spec_deneb/02-builtins-dec-only.spectec:86:1-86:49:
def $concat_domain(domainType, bytes28) : domain =

;; spec/spec_deneb/02-builtins-dec-only.spectec:87:1-87:66:
def $make_withdrawal_credentials_eth1(executionAddress) : bytes32 =

;; spec/spec_deneb/02-builtins-dec-only.spectec:90:1-90:52:
def $make_versioned_hash(bytes1, bytes31) : bytes32 =

;; spec/spec_deneb/02-builtins-dec-only.spectec:93:1-93:38:
def $uint8_to_bytes_le(uint8) : bytes =

;; spec/spec_deneb/02-builtins-dec-only.spectec:94:1-94:40:
def $uint32_to_bytes_le(uint32) : bytes =

;; spec/spec_deneb/02-builtins-dec-only.spectec:95:1-95:40:
def $uint64_to_bytes_le(uint64) : bytes =

;; spec/spec_deneb/02-builtins-dec-only.spectec:96:1-96:38:
def $bytes32_prefix8(bytes32) : bytes =

;; spec/spec_deneb/02-builtins-dec-only.spectec:97:1-97:41:
def $bytes8_to_uint64_le(bytes) : uint64 =

;; spec/spec_deneb/02-builtins-dec-only.spectec:100:1-100:38:
def $shr_uint64(uint64, nat) : uint64 =

;; spec/spec_deneb/02-builtins-dec-only.spectec:101:1-101:41:
def $and_uint64(uint64, uint64) : uint64 =

;; spec/spec_deneb/02-builtins-dec-only.spectec:104:1-104:47:
def $bytes32_to_bytes1_list(bytes32) : bytes1* =

;; spec/spec_deneb/02-builtins-dec-only.spectec:105:1-105:39:
def $bytes1_to_uint64(bytes1) : uint64 =

;; spec/spec_deneb/02-builtins-dec-only.spectec:107:1-107:40:
def $concat_bytes(bytes, bytes) : bytes =

;; spec/spec_deneb/02-builtins-dec-only.spectec:109:1-109:39:
def $bytes32_to_bytes(bytes32) : bytes =

;; spec/spec_deneb/02-builtins-dec-only.spectec:110:1-110:37:
def $bytes4_to_bytes(bytes4) : bytes =

;; spec/spec_deneb/02-builtins-dec-only.spectec:114:1-114:59:
def $extract_execution_address(bytes32) : executionAddress =

;; spec/spec_deneb/03-generic-helpers.spectec:8:1-9:7:
def $filter_list_<X>(X*, $cond(X) : bool) : X* =

   ;; spec/spec_deneb/03-generic-helpers.spectec:10:1-10:43:
   clause 0(X*{X <- X*}, $cond) = []
      -- if X*{X <- X*} matches []

   ;; spec/spec_deneb/03-generic-helpers.spectec:11:1-13:26:
   clause 1(X*{X <- X*}, $cond) = X_h :: $filter_list_<X>(X_t*{X_t <- X_t*}, $cond)
      -- if X*{X <- X*} matches _ :: _
      -- let X_h :: X_t*{X_t <- X_t*} = X*{X <- X*}
      -- if ($cond(X_h) = true)

   ;; spec/spec_deneb/03-generic-helpers.spectec:14:1-16:27:
   clause 2(X*{X <- X*}, $cond) = $filter_list_<X>(X_t*{X_t <- X_t*}, $cond)
      -- if X*{X <- X*} matches _ :: _
      -- let X_h :: X_t*{X_t <- X_t*} = X*{X <- X*}
      -- if ($cond(X_h) = false)

;; spec/spec_deneb/03-generic-helpers.spectec:18:1-18:62:
def $filter_list_2_<X, Y>(X*, Y, $cond(X, Y) : bool) : X* =

   ;; spec/spec_deneb/03-generic-helpers.spectec:19:1-19:51:
   clause 0(X*{X <- X*}, Y, $cond) = []
      -- if X*{X <- X*} matches []

   ;; spec/spec_deneb/03-generic-helpers.spectec:20:1-22:29:
   clause 1(X*{X <- X*}, Y, $cond) = X_h :: $filter_list_2_<X, Y>(X_t*{X_t <- X_t*}, Y, $cond)
      -- if X*{X <- X*} matches _ :: _
      -- let X_h :: X_t*{X_t <- X_t*} = X*{X <- X*}
      -- if ($cond(X_h, Y) = true)

   ;; spec/spec_deneb/03-generic-helpers.spectec:23:1-25:30:
   clause 2(X*{X <- X*}, Y, $cond) = $filter_list_2_<X, Y>(X_t*{X_t <- X_t*}, Y, $cond)
      -- if X*{X <- X*} matches _ :: _
      -- let X_h :: X_t*{X_t <- X_t*} = X*{X <- X*}
      -- if ($cond(X_h, Y) = false)

;; spec/spec_deneb/03-generic-helpers.spectec:30:1-30:53:
def $fold_<X, Y>($fold_func(X, Y) : X, X, Y*) : X =

   ;; spec/spec_deneb/03-generic-helpers.spectec:31:1-31:45:
   clause 0($fold_func, X, Y*{Y <- Y*}) = X
      -- if Y*{Y <- Y*} matches []

   ;; spec/spec_deneb/03-generic-helpers.spectec:32:1-33:57:
   clause 1($fold_func, X, Y*{Y <- Y*}) = $fold_<X, Y>($fold_func, $fold_func(X, Y_h), Y_t*{Y_t <- Y_t*})
      -- if Y*{Y <- Y*} matches _ :: _
      -- let Y_h :: Y_t*{Y_t <- Y_t*} = Y*{Y <- Y*}

;; spec/spec_deneb/03-generic-helpers.spectec:40:1-40:49:
def $has_flag(participationFlags, nat) : boolean =

   ;; spec/spec_deneb/03-generic-helpers.spectec:43:1-44:20:
   clause 0(participationFlags, n) = false
      -- if (n >= 8)

   ;; spec/spec_deneb/03-generic-helpers.spectec:45:1-46:55:
   clause 1(participationFlags, n) = true
      -- if (((participationFlags / $pow2(n)) \ 2) = 1)

   ;; spec/spec_deneb/03-generic-helpers.spectec:47:1-48:15:
   clause 2(participationFlags, n) = false
      -- otherwise

;; spec/spec_deneb/03-generic-helpers.spectec:51:1-51:60:
def $add_flag(participationFlags, nat) : participationFlags =

   ;; spec/spec_deneb/03-generic-helpers.spectec:54:1-55:20:
   clause 0(participationFlags, n) = participationFlags
      -- if (n >= 8)

   ;; spec/spec_deneb/03-generic-helpers.spectec:56:1-57:55:
   clause 1(participationFlags, n) = participationFlags
      -- if (((participationFlags / $pow2(n)) \ 2) = 1)

   ;; spec/spec_deneb/03-generic-helpers.spectec:58:1-59:15:
   clause 2(participationFlags, n) = (participationFlags + $pow2(n))
      -- otherwise

;; spec/spec_deneb/03-generic-helpers.spectec:66:1-66:41:
def $max_uint64(uint64, uint64) : uint64 =

   ;; spec/spec_deneb/03-generic-helpers.spectec:67:1-68:18:
   clause 0(x, y) = x
      -- if (x >= y)

   ;; spec/spec_deneb/03-generic-helpers.spectec:69:1-70:15:
   clause 1(x, y) = y
      -- otherwise

;; spec/spec_deneb/03-generic-helpers.spectec:73:1-73:41:
def $min_uint64(uint64, uint64) : uint64 =

   ;; spec/spec_deneb/03-generic-helpers.spectec:74:1-75:18:
   clause 0(x, y) = x
      -- if (x <= y)

   ;; spec/spec_deneb/03-generic-helpers.spectec:76:1-77:15:
   clause 1(x, y) = y
      -- otherwise

;; spec/spec_deneb/03-generic-helpers.spectec:80:1-80:76:
def $eth_fast_aggregate_verify(blsPubkey*, bytes32, blsSignature) : boolean =

   ;; spec/spec_deneb/03-generic-helpers.spectec:82:1-84:45:
   clause 0(blsPubkey*{blsPubkey <- blsPubkey*}, bytes32_msg, blsSignature) = true
      -- if (|blsPubkey*{blsPubkey <- blsPubkey*}| = 0)
      -- if (blsSignature = $G2_POINT_AT_INFINITY)

   ;; spec/spec_deneb/03-generic-helpers.spectec:86:1-88:15:
   clause 1(blsPubkey*{blsPubkey <- blsPubkey*}, bytes32_msg, blsSignature) = $bls_fast_aggregate_verify(blsPubkey*{blsPubkey <- blsPubkey*}, bytes32_msg, blsSignature)
      -- otherwise

;; spec/spec_deneb/03-generic-helpers.spectec:91:1-91:63:
def $ee_verify_and_notify_new_payload(executionPayload) : bool =

;; spec/spec_deneb/03-generic-helpers.spectec:94:1-94:79:
def $index_of_pubkey((validatorIndex, blsPubkey)*, blsPubkey) : validatorIndex =

   ;; spec/spec_deneb/03-generic-helpers.spectec:96:1-97:42:
   clause 0((validatorIndex, blsPubkey)*{(validatorIndex, blsPubkey) <- (validatorIndex, blsPubkey)*}, blsPubkey_committee) = vid_h
      -- if (validatorIndex, blsPubkey)*{(validatorIndex, blsPubkey) <- (validatorIndex, blsPubkey)*} matches _ :: _
      -- let (vid_h, blsPubkey_h) :: (vid_t, blsPubkey_t)*{blsPubkey_t <- blsPubkey_t*, vid_t <- vid_t*} = (validatorIndex, blsPubkey)*{(validatorIndex, blsPubkey) <- (validatorIndex, blsPubkey)*}
      -- if (blsPubkey_h = blsPubkey_committee)

   ;; spec/spec_deneb/03-generic-helpers.spectec:99:1-101:15:
   clause 1((validatorIndex, blsPubkey)*{(validatorIndex, blsPubkey) <- (validatorIndex, blsPubkey)*}, blsPubkey_committee) = $index_of_pubkey((vid_t, blsPubkey_t)*{blsPubkey_t <- blsPubkey_t*, vid_t <- vid_t*}, blsPubkey_committee)
      -- if (validatorIndex, blsPubkey)*{(validatorIndex, blsPubkey) <- (validatorIndex, blsPubkey)*} matches _ :: _
      -- let (vid_h, blsPubkey_h) :: (vid_t, blsPubkey_t)*{blsPubkey_t <- blsPubkey_t*, vid_t <- vid_t*} = (validatorIndex, blsPubkey)*{(validatorIndex, blsPubkey) <- (validatorIndex, blsPubkey)*}
      -- otherwise

;; spec/spec_deneb/03-generic-helpers.spectec:106:1-106:69:
def $kzg_commitment_to_versioned_hash(kzgCommitment) : versionedHash =

   ;; spec/spec_deneb/03-generic-helpers.spectec:108:1-113:46:
   clause 0(kzgCommitment_in) = versionedHash_result
      -- let bytes32_hash = $hash_<kzgCommitment>(kzgCommitment_in)
      -- let bytes31_tail = $strip_first_byte(bytes32_hash)
      -- let bytes1_version = $VERSIONED_HASH_VERSION_KZG
      -- let bytes32_result = $make_versioned_hash(bytes1_version, bytes31_tail)
      -- let versionedHash_result = bytes32_result

;; spec/spec_deneb/04-helpers-slot-epoch-time.spectec:6:1-6:41:
def $compute_epoch_at_slot(slot) : epoch =

   ;; spec/spec_deneb/04-helpers-slot-epoch-time.spectec:7:1-7:62:
   clause 0(slot) = (slot / $SLOTS_PER_EPOCH)

;; spec/spec_deneb/04-helpers-slot-epoch-time.spectec:10:1-10:47:
def $compute_start_slot_at_epoch(epoch) : slot =

   ;; spec/spec_deneb/04-helpers-slot-epoch-time.spectec:11:1-11:70:
   clause 0(epoch) = (epoch * $SLOTS_PER_EPOCH)

;; spec/spec_deneb/04-helpers-slot-epoch-time.spectec:14:1-14:44:
def $get_current_epoch(beaconState) : epoch =

   ;; spec/spec_deneb/04-helpers-slot-epoch-time.spectec:15:1-15:67:
   clause 0(state) = $compute_epoch_at_slot(state.SLOT)

;; spec/spec_deneb/04-helpers-slot-epoch-time.spectec:18:1-18:45:
def $get_previous_epoch(beaconState) : epoch =

   ;; spec/spec_deneb/04-helpers-slot-epoch-time.spectec:20:1-21:51:
   clause 0(state) = $GENESIS_EPOCH
      -- if ($get_current_epoch(state) = $GENESIS_EPOCH)

   ;; spec/spec_deneb/04-helpers-slot-epoch-time.spectec:22:1-23:15:
   clause 1(state) = ($get_current_epoch(state) - 1)
      -- otherwise

;; spec/spec_deneb/04-helpers-slot-epoch-time.spectec:26:1-26:54:
def $compute_time_at_slot(beaconState, slot) : uint64 =

   ;; spec/spec_deneb/04-helpers-slot-epoch-time.spectec:27:1-28:69:
   clause 0(state, slot) = (state.GENESIS_TIME + ((slot - $GENESIS_SLOT) * $SECONDS_PER_SLOT))

;; spec/spec_deneb/04-helpers-slot-epoch-time.spectec:32:1-32:32:
def $get_prev_slot(slot) : slot =

   ;; spec/spec_deneb/04-helpers-slot-epoch-time.spectec:33:1-34:17:
   clause 0(slot) = 0
      -- if (slot = 0)

   ;; spec/spec_deneb/04-helpers-slot-epoch-time.spectec:35:1-36:15:
   clause 1(slot) = (slot - 1)
      -- otherwise

;; spec/spec_deneb/05-helpers-domain-fork.spectec:6:1-6:50:
def $compute_fork_data_root(version, root) : root =

   ;; spec/spec_deneb/05-helpers-domain-fork.spectec:7:1-8:86:
   clause 0(version, root) = $hash_tree_root_forkdata({CURRENT_VERSION version, GENESIS_VALIDATORS_ROOT root})

;; spec/spec_deneb/05-helpers-domain-fork.spectec:11:1-11:58:
def $compute_domain(domainType, version?, root?) : domain =

   ;; spec/spec_deneb/05-helpers-domain-fork.spectec:13:1-14:86:
   clause 0(domainType, version'?{version' <- version'?}, root'?{root' <- root'?}) = $concat_domain(domainType, $first_28_bytes($compute_fork_data_root(version, root)))
      -- if version'?{version' <- version'?} matches (_)
      -- let ?(version) = version'?{version' <- version'?}
      -- if root'?{root' <- root'?} matches (_)
      -- let ?(root) = root'?{root' <- root'?}

   ;; spec/spec_deneb/05-helpers-domain-fork.spectec:16:1-17:106:
   clause 1(domainType, version?{version <- version?}, root?{root <- root?}) = $concat_domain(domainType, $first_28_bytes($compute_fork_data_root($GENESIS_FORK_VERSION, $ZERO_ROOT)))
      -- if version?{version <- version?} matches ()
      -- if root?{root <- root?} matches ()

   ;; spec/spec_deneb/05-helpers-domain-fork.spectec:19:1-20:92:
   clause 2(domainType, version'?{version' <- version'?}, root?{root <- root?}) = $concat_domain(domainType, $first_28_bytes($compute_fork_data_root(version, $ZERO_ROOT)))
      -- if version'?{version' <- version'?} matches (_)
      -- let ?(version) = version'?{version' <- version'?}
      -- if root?{root <- root?} matches ()

   ;; spec/spec_deneb/05-helpers-domain-fork.spectec:22:1-23:100:
   clause 3(domainType, version?{version <- version?}, root'?{root' <- root'?}) = $concat_domain(domainType, $first_28_bytes($compute_fork_data_root($GENESIS_FORK_VERSION, root)))
      -- if version?{version <- version?} matches ()
      -- if root'?{root' <- root'?} matches (_)
      -- let ?(root) = root'?{root' <- root'?}

;; spec/spec_deneb/05-helpers-domain-fork.spectec:26:1-26:58:
def $get_domain(beaconState, domainType, epoch?) : domain =

   ;; spec/spec_deneb/05-helpers-domain-fork.spectec:28:1-31:40:
   clause 0(state, domainType, epoch?{epoch <- epoch?}) = $compute_domain(domainType, ?(state.FORK.PREVIOUS_VERSION), ?(state.GENESIS_VALIDATORS_ROOT))
      -- if epoch?{epoch <- epoch?} matches ()
      -- let epoch_cur = $get_current_epoch(state)
      -- if (epoch_cur < state.FORK.EPOCH)

   ;; spec/spec_deneb/05-helpers-domain-fork.spectec:33:1-36:15:
   clause 1(state, domainType, epoch?{epoch <- epoch?}) = $compute_domain(domainType, ?(state.FORK.CURRENT_VERSION), ?(state.GENESIS_VALIDATORS_ROOT))
      -- if epoch?{epoch <- epoch?} matches ()
      -- let epoch_cur = $get_current_epoch(state)
      -- otherwise

   ;; spec/spec_deneb/05-helpers-domain-fork.spectec:38:1-40:36:
   clause 2(state, domainType, epoch'?{epoch' <- epoch'?}) = $compute_domain(domainType, ?(state.FORK.PREVIOUS_VERSION), ?(state.GENESIS_VALIDATORS_ROOT))
      -- if epoch'?{epoch' <- epoch'?} matches (_)
      -- let ?(epoch) = epoch'?{epoch' <- epoch'?}
      -- if (epoch < state.FORK.EPOCH)

   ;; spec/spec_deneb/05-helpers-domain-fork.spectec:42:1-44:15:
   clause 3(state, domainType, epoch'?{epoch' <- epoch'?}) = $compute_domain(domainType, ?(state.FORK.CURRENT_VERSION), ?(state.GENESIS_VALIDATORS_ROOT))
      -- if epoch'?{epoch' <- epoch'?} matches (_)
      -- let ?(epoch) = epoch'?{epoch' <- epoch'?}
      -- otherwise

;; spec/spec_deneb/05-helpers-domain-fork.spectec:47:1-47:70:
def $verify_block_signature(beaconState, signedBeaconBlock) : boolean =

   ;; spec/spec_deneb/05-helpers-domain-fork.spectec:49:1-54:90:
   clause 0(state, signedBeaconBlock) = true
      -- if (signedBeaconBlock.MESSAGE.PROPOSER_INDEX < |state.VALIDATORS|)   ;; [ins:bounds]
      -- let validator_proposer = state.VALIDATORS[signedBeaconBlock.MESSAGE.PROPOSER_INDEX]
      -- let root_signing = $compute_signing_root_beaconBlock(signedBeaconBlock.MESSAGE, $get_domain(state, $DOMAIN_BEACON_PROPOSER, ?()))
      -- if $bls_verify(validator_proposer.PUBKEY, root_signing, signedBeaconBlock.SIGNATURE)

   ;; spec/spec_deneb/05-helpers-domain-fork.spectec:56:1-57:15:
   clause 1(state, signedBeaconBlock) = false
      -- otherwise

;; spec/spec_deneb/06-helpers-validator.spectec:6:1-6:50:
def $compute_activation_exit_epoch(epoch) : epoch =

   ;; spec/spec_deneb/06-helpers-validator.spectec:7:1-7:79:
   clause 0(epoch) = ((epoch + 1) + $MAX_SEED_LOOKAHEAD)

;; spec/spec_deneb/06-helpers-validator.spectec:10:1-10:53:
def $is_active_validator(validator, epoch) : boolean =

   ;; spec/spec_deneb/06-helpers-validator.spectec:12:1-14:40:
   clause 0(validator, epoch) = true
      -- if (validator.ACTIVATION_EPOCH <= epoch)
      -- if (epoch < validator.EXIT_EPOCH)

   ;; spec/spec_deneb/06-helpers-validator.spectec:16:1-17:15:
   clause 1(validator, epoch) = false
      -- otherwise

;; spec/spec_deneb/06-helpers-validator.spectec:20:1-20:59:
def $is_eligible_for_activation_queue(validator) : boolean =

   ;; spec/spec_deneb/06-helpers-validator.spectec:22:1-24:61:
   clause 0(validator) = true
      -- if (validator.ACTIVATION_ELIGIBILITY_EPOCH = $FAR_FUTURE_EPOCH)
      -- if (validator.EFFECTIVE_BALANCE = $MAX_EFFECTIVE_BALANCE)

   ;; spec/spec_deneb/06-helpers-validator.spectec:26:1-27:15:
   clause 1(validator) = false
      -- otherwise

;; spec/spec_deneb/06-helpers-validator.spectec:30:1-30:66:
def $is_eligible_for_activation(beaconState, validator) : boolean =

   ;; spec/spec_deneb/06-helpers-validator.spectec:32:1-34:55:
   clause 0(state, validator) = true
      -- if (validator.ACTIVATION_ELIGIBILITY_EPOCH <= state.FINALIZED_CHECKPOINT.EPOCH)
      -- if (validator.ACTIVATION_EPOCH = $FAR_FUTURE_EPOCH)

   ;; spec/spec_deneb/06-helpers-validator.spectec:36:1-37:15:
   clause 1(state, validator) = false
      -- otherwise

;; spec/spec_deneb/06-helpers-validator.spectec:40:1-40:56:
def $is_slashable_validator(validator, epoch) : boolean =

   ;; spec/spec_deneb/06-helpers-validator.spectec:42:1-45:48:
   clause 0(validator, epoch) = true
      -- if ~validator.SLASHED
      -- if (validator.ACTIVATION_EPOCH <= epoch)
      -- if (epoch < validator.WITHDRAWABLE_EPOCH)

   ;; spec/spec_deneb/06-helpers-validator.spectec:47:1-48:15:
   clause 1(validator, epoch) = false
      -- otherwise

;; spec/spec_deneb/06-helpers-validator.spectec:51:1-51:57:
def $has_eth1_withdrawal_credential(validator) : boolean =

   ;; spec/spec_deneb/06-helpers-validator.spectec:53:1-53:135:
   clause 0(validator) = ($get_first_byte(validator.WITHDRAWAL_CREDENTIALS) = $ETH1_ADDRESS_WITHDRAWAL_PREFIX)

;; spec/spec_deneb/06-helpers-validator.spectec:56:1-56:71:
def $is_fully_withdrawable_validator(validator, gwei, epoch) : boolean =

   ;; spec/spec_deneb/06-helpers-validator.spectec:58:1-61:23:
   clause 0(validator, balance, epoch) = true
      -- if ($has_eth1_withdrawal_credential(validator) = true)
      -- if (validator.WITHDRAWABLE_EPOCH <= epoch)
      -- if (balance > 0)

   ;; spec/spec_deneb/06-helpers-validator.spectec:63:1-64:15:
   clause 1(validator, balance, epoch) = false
      -- otherwise

;; spec/spec_deneb/06-helpers-validator.spectec:67:1-67:68:
def $is_partially_withdrawable_validator(validator, gwei) : boolean =

   ;; spec/spec_deneb/06-helpers-validator.spectec:69:1-72:44:
   clause 0(validator, balance) = true
      -- if ($has_eth1_withdrawal_credential(validator) = true)
      -- if (validator.EFFECTIVE_BALANCE = $MAX_EFFECTIVE_BALANCE)
      -- if (balance > $MAX_EFFECTIVE_BALANCE)

   ;; spec/spec_deneb/06-helpers-validator.spectec:74:1-75:15:
   clause 1(validator, balance) = false
      -- otherwise

;; spec/spec_deneb/06-helpers-validator.spectec:78:1-78:74:
def $is_active_validator_enumerated(enumerated_<validator>, epoch) : bool =

   ;; spec/spec_deneb/06-helpers-validator.spectec:79:1-79:100:
   clause 0((_nat, validator), epoch) = $is_active_validator(validator, epoch)

;; spec/spec_deneb/06-helpers-validator.spectec:82:1-82:72:
def $get_active_validator_indices(beaconState, epoch) : validatorIndex* =

   ;; spec/spec_deneb/06-helpers-validator.spectec:83:1-90:23:
   clause 0(state, epoch) = vid_active*{vid_active <- vid_active*}
      -- let (vid, validator)*{validator <- validator*, vid <- vid*} = $enumerate_<validator>(state.VALIDATORS)
      -- let (vid_active, _validator)*{_validator <- _validator*, vid_active <- vid_active*} = $filter_list_2_<(validatorIndex, validator), epoch>((vid, validator)*{validator <- validator*, vid <- vid*}, epoch, $is_active_validator_enumerated)

;; spec/spec_deneb/06-helpers-validator.spectec:93:1-93:53:
def $get_validator_churn_limit(beaconState) : uint64 =

   ;; spec/spec_deneb/06-helpers-validator.spectec:94:1-96:86:
   clause 0(state) = $max_uint64($MIN_PER_EPOCH_CHURN_LIMIT, (|vid_active*{vid_active <- vid_active*}| / $CHURN_LIMIT_QUOTIENT))
      -- let vid_active*{vid_active <- vid_active*} = $get_active_validator_indices(state, $get_current_epoch(state))

;; spec/spec_deneb/06-helpers-validator.spectec:103:1-103:72:
def $get_validator_from_deposit(blsPubkey, bytes32, uint64) : validator =

   ;; spec/spec_deneb/06-helpers-validator.spectec:105:1-114:129:
   clause 0(blsPubkey, bytes32_withdrawal, uint64_amount) = {PUBKEY blsPubkey, WITHDRAWAL_CREDENTIALS bytes32_withdrawal, EFFECTIVE_BALANCE balance_effective, SLASHED false, ACTIVATION_ELIGIBILITY_EPOCH $FAR_FUTURE_EPOCH, ACTIVATION_EPOCH $FAR_FUTURE_EPOCH, EXIT_EPOCH $FAR_FUTURE_EPOCH, WITHDRAWABLE_EPOCH $FAR_FUTURE_EPOCH}
      -- let balance_effective = $min_uint64((uint64_amount - (uint64_amount \ $EFFECTIVE_BALANCE_INCREMENT)), $MAX_EFFECTIVE_BALANCE)

;; spec/spec_deneb/06-helpers-validator.spectec:119:1-121:26:
relation AddValidatorToRegistry: beaconState .VALIDATORS++{ blsPubkey bytes32 uint64 }~> beaconState

   ;; spec/spec_deneb/06-helpers-validator.spectec:123:1-138:103:
   rule : state .VALIDATORS++{ blsPubkey bytes32_wc uint64_amount }~> state[VALIDATORS = validator_updated*{validator_updated <- validator_updated*}][BALANCES = balance_updated*{balance_updated <- balance_updated*}][PREVIOUS_EPOCH_PARTICIPATION = participationFlags_prev_updated*{participationFlags_prev_updated <- participationFlags_prev_updated*}][CURRENT_EPOCH_PARTICIPATION = participationFlags_cur_updated*{participationFlags_cur_updated <- participationFlags_cur_updated*}][INACTIVITY_SCORES = uint64_inactivity_updated*{uint64_inactivity_updated <- uint64_inactivity_updated*}]
      -- let vid_new = |state.VALIDATORS|
      -- let validator = $get_validator_from_deposit(blsPubkey, bytes32_wc, uint64_amount)
      -- let validator_updated*{validator_updated <- validator_updated*} = $set_or_append_list_<validator>(state.VALIDATORS, vid_new, validator)
      -- let balance_updated*{balance_updated <- balance_updated*} = $set_or_append_list_<gwei>(state.BALANCES, vid_new, uint64_amount)
      -- let participationFlags_prev_updated*{participationFlags_prev_updated <- participationFlags_prev_updated*} = $set_or_append_list_<participationFlags>(state.PREVIOUS_EPOCH_PARTICIPATION, vid_new, 0)
      -- let participationFlags_cur_updated*{participationFlags_cur_updated <- participationFlags_cur_updated*} = $set_or_append_list_<participationFlags>(state.CURRENT_EPOCH_PARTICIPATION, vid_new, 0)
      -- let uint64_inactivity_updated*{uint64_inactivity_updated <- uint64_inactivity_updated*} = $set_or_append_list_<uint64>(state.INACTIVITY_SCORES, vid_new, 0)

;; spec/spec_deneb/06-helpers-validator.spectec:142:1-142:76:
def $is_eligible_validator_enumerated(enumerated_<validator>, epoch) : bool =

   ;; spec/spec_deneb/06-helpers-validator.spectec:143:1-146:76:
   clause 0((_nat, validator), epoch_prev) = ($is_active_validator(validator, epoch_prev) \/ (validator.SLASHED /\ ((epoch_prev + 1) < validator.WITHDRAWABLE_EPOCH)))

;; spec/spec_deneb/06-helpers-validator.spectec:149:1-149:67:
def $get_eligible_validator_indices(beaconState) : validatorIndex* =

   ;; spec/spec_deneb/06-helpers-validator.spectec:151:1-158:28:
   clause 0(state) = vid_eligible*{vid_eligible <- vid_eligible*}
      -- let epoch_prev = $get_previous_epoch(state)
      -- let (vid, validator)*{validator <- validator*, vid <- vid*} = $enumerate_<validator>(state.VALIDATORS)
      -- let (vid_eligible, _validator)*{_validator <- _validator*, vid_eligible <- vid_eligible*} = $filter_list_2_<(validatorIndex, validator), epoch>((vid, validator)*{validator <- validator*, vid <- vid*}, epoch_prev, $is_eligible_validator_enumerated)

;; spec/spec_deneb/06-helpers-validator.spectec:161:1-161:75:
def $has_flag_for_index(validatorIndex, (participationFlags*, nat)) : bool =

   ;; spec/spec_deneb/06-helpers-validator.spectec:162:1-165:44:
   clause 0(vid, (participationFlags_list*{participationFlags_list <- participationFlags_list*}, nat_flag)) = $has_flag(participationFlags_list*{participationFlags_list <- participationFlags_list*}[vid], nat_flag)
      -- if (vid < |participationFlags_list*{participationFlags_list <- participationFlags_list*}|)   ;; [ins:bounds]

;; spec/spec_deneb/06-helpers-validator.spectec:168:1-168:54:
def $is_unslashed(validatorIndex, beaconState) : bool =

   ;; spec/spec_deneb/06-helpers-validator.spectec:169:1-172:37:
   clause 0(vid, state) = true
      -- if (vid < |state.VALIDATORS|)
      -- let validator = state.VALIDATORS[vid]
      -- if (validator.SLASHED = false)

   ;; spec/spec_deneb/06-helpers-validator.spectec:173:1-174:15:
   clause 1(vid, state) = false
      -- otherwise

;; spec/spec_deneb/06-helpers-validator.spectec:177:1-177:84:
def $get_unslashed_participating_indices(beaconState, nat, epoch) : validatorIndex* =

   ;; spec/spec_deneb/06-helpers-validator.spectec:179:1-192:26:
   clause 0(state, vid_flag, epoch) = $to_set_<validatorIndex>(vid_unslashed*{vid_unslashed <- vid_unslashed*})
      -- if ($get_current_epoch(state) = epoch)
      -- let vid_active*{vid_active <- vid_active*} = $get_active_validator_indices(state, epoch)
      -- let vid_participating*{vid_participating <- vid_participating*} = $filter_list_2_<validatorIndex, (participationFlags*, validatorIndex)>(vid_active*{vid_active <- vid_active*}, (state.CURRENT_EPOCH_PARTICIPATION, vid_flag), $has_flag_for_index)
      -- let vid_unslashed*{vid_unslashed <- vid_unslashed*} = $filter_list_2_<validatorIndex, beaconState>(vid_participating*{vid_participating <- vid_participating*}, state, $is_unslashed)

   ;; spec/spec_deneb/06-helpers-validator.spectec:195:1-208:26:
   clause 1(state, vid_flag, epoch) = $to_set_<validatorIndex>(vid_unslashed*{vid_unslashed <- vid_unslashed*})
      -- if ($get_previous_epoch(state) = epoch)
      -- let vid_active*{vid_active <- vid_active*} = $get_active_validator_indices(state, epoch)
      -- let vid_participating*{vid_participating <- vid_participating*} = $filter_list_2_<validatorIndex, (participationFlags*, nat)>(vid_active*{vid_active <- vid_active*}, (state.PREVIOUS_EPOCH_PARTICIPATION, vid_flag), $has_flag_for_index)
      -- let vid_unslashed*{vid_unslashed <- vid_unslashed*} = $filter_list_2_<validatorIndex, beaconState>(vid_participating*{vid_participating <- vid_participating*}, state, $is_unslashed)

;; spec/spec_deneb/06-helpers-validator.spectec:211:1-211:64:
def $get_validator_activation_churn_limit(beaconState) : uint64 =

   ;; spec/spec_deneb/06-helpers-validator.spectec:213:1-215:110:
   clause 0(state) = uint64_activation_churn_limit
      -- let uint64_churn_limit = $get_validator_churn_limit(state)
      -- let uint64_activation_churn_limit = $min_uint64($MAX_PER_EPOCH_ACTIVATION_CHURN_LIMIT, uint64_churn_limit)

;; spec/spec_deneb/07-helpers-history.spectec:6:1-6:54:
def $get_block_root_at_slot(beaconState, slot) : root =

   ;; spec/spec_deneb/07-helpers-history.spectec:8:1-15:68:
   clause 0(state, slot) = root
      -- if (slot < state.SLOT)
      -- if (slot <= ($UINT64_MAX - $SLOTS_PER_HISTORICAL_ROOT))   ;; [ins:overflow]
      -- if (state.SLOT <= (slot + $SLOTS_PER_HISTORICAL_ROOT))
      -- let root = state.BLOCK_ROOTS[(slot \ $SLOTS_PER_HISTORICAL_ROOT)]

;; spec/spec_deneb/07-helpers-history.spectec:18:1-18:47:
def $get_block_root(beaconState, epoch) : root =

   ;; spec/spec_deneb/07-helpers-history.spectec:20:1-21:72:
   clause 0(state, epoch) = $get_block_root_at_slot(state, $compute_start_slot_at_epoch(epoch))

;; spec/spec_deneb/07-helpers-history.spectec:24:1-24:50:
def $get_randao_mix(beaconState, epoch) : bytes32 =

   ;; spec/spec_deneb/07-helpers-history.spectec:26:1-27:62:
   clause 0(state, epoch) = state.RANDAO_MIXES[(epoch \ $EPOCHS_PER_HISTORICAL_VECTOR)]

;; spec/spec_deneb/07-helpers-history.spectec:30:1-30:46:
def $get_finality_delay(beaconState) : uint64 =

   ;; spec/spec_deneb/07-helpers-history.spectec:32:1-35:76:
   clause 0(state) = ($get_previous_epoch(state) - state.FINALIZED_CHECKPOINT.EPOCH)
      -- if ($get_previous_epoch(state) >= state.FINALIZED_CHECKPOINT.EPOCH)   ;; [ins:underflow]

;; spec/spec_deneb/07-helpers-history.spectec:38:1-38:50:
def $is_in_inactivity_leak(beaconState) : boolean =

   ;; spec/spec_deneb/07-helpers-history.spectec:40:1-41:72:
   clause 0(state) = ($get_finality_delay(state) > $MIN_EPOCHS_TO_INACTIVITY_PENALTY)

;; spec/spec_deneb/08-helpers-selection.spectec:6:1-6:48:
def $choose_index(uint64, uint64, nat) : uint64 =

   ;; spec/spec_deneb/08-helpers-selection.spectec:7:1-8:20:
   clause 0(i, uint64_flip, nat_bit) = uint64_flip
      -- if (nat_bit = 1)

   ;; spec/spec_deneb/08-helpers-selection.spectec:9:1-10:15:
   clause 1(i, uint64_flip, nat_bit) = i
      -- otherwise

;; spec/spec_deneb/08-helpers-selection.spectec:15:1-15:69:
def $apply_shuffle_round(uint64, (bytes32, uint64, uint64)) : uint64 =

   ;; spec/spec_deneb/08-helpers-selection.spectec:17:1-38:55:
   clause 0(i, (seed, i_count, uint64_round)) = i_out
      -- let bytes_seed = $bytes32_to_bytes(seed)
      -- let bytes_round8 = $uint8_to_bytes_le((uint64_round \ 256))
      -- let bytes32_round_hash = $hash_<bytes>($concat_bytes(bytes_seed, bytes_round8))
      -- let bytes8_prefix = $bytes32_prefix8(bytes32_round_hash)
      -- let uint64_pivot_raw = $bytes8_to_uint64_le(bytes8_prefix)
      -- let uint64_pivot = (uint64_pivot_raw \ i_count)
      -- let uint64_flip = (((uint64_pivot + i_count) - i) \ i_count)
      -- let uint64_position = $max_uint64(i, uint64_flip)
      -- let bytes_bucket = $uint32_to_bytes_le((uint64_position / 256))
      -- let bytes32_source = $hash_<bytes>($concat_bytes($concat_bytes(bytes_seed, bytes_round8), bytes_bucket))
      -- let uint64_byte = $bytes1_to_uint64($bytes32_to_bytes1_list(bytes32_source)[((uint64_position \ 256) / 8)])
      -- let nat_bit = ($and_uint64($shr_uint64(uint64_byte, (uint64_position \ 8)), 1) \ 2)
      -- let i_out = $choose_index(i, uint64_flip, nat_bit)

;; spec/spec_deneb/08-helpers-selection.spectec:43:1-43:62:
def $compute_shuffled_index(uint64, uint64, bytes32) : uint64 =

   ;; spec/spec_deneb/08-helpers-selection.spectec:45:1-53:22:
   clause 0(i, i_count, seed) = i_shuffled
      -- let uint64_round*{uint64_round <- uint64_round*} = $range($SHUFFLE_ROUND_COUNT)
      -- let uint64_round_first = uint64_round*{uint64_round <- uint64_round*}[0]
      -- let uint64_round_last = uint64_round*{uint64_round <- uint64_round*}[($SHUFFLE_ROUND_COUNT - 1)]
      -- let i_shuffled = $fold_<uint64, (bytes32, uint64, uint64)>($apply_shuffle_round, i, (seed, i_count, uint64_round)*{uint64_round <- uint64_round*})

;; spec/spec_deneb/08-helpers-selection.spectec:57:1-57:105:
def $compute_proposer_index_loop(beaconState, validatorIndex*, bytes32, uint64, uint64) : validatorIndex =

   ;; spec/spec_deneb/08-helpers-selection.spectec:60:1-70:97:
   clause 0(state, vid*{vid <- vid*}, seed, uint64_total, i) = vid_candidate
      -- let vid_candidate = vid*{vid <- vid*}[$compute_shuffled_index((i \ uint64_total), uint64_total, seed)]
      -- let bytes32_h = $hash_<bytes>($concat_bytes($bytes32_to_bytes(seed), $uint64_to_bytes_le((i / 32))))
      -- let uint64_random_byte = $bytes1_to_uint64($bytes32_to_bytes1_list(bytes32_h)[(i \ 32)])
      -- let balance_effective = state.VALIDATORS[vid_candidate].EFFECTIVE_BALANCE
      -- if (balance_effective <= ($UINT64_MAX / $MAX_RANDOM_BYTE))   ;; [ins:overflow]
      -- if ((balance_effective * $MAX_RANDOM_BYTE) >= ($MAX_EFFECTIVE_BALANCE * uint64_random_byte))

   ;; spec/spec_deneb/08-helpers-selection.spectec:73:1-89:96:
   clause 1(state, vid*{vid <- vid*}, seed, uint64_total, i) = $compute_proposer_index_loop(state, vid*{vid <- vid*}, seed, uint64_total, (i + 1))
      -- let vid_candidate = vid*{vid <- vid*}[$compute_shuffled_index((i \ uint64_total), uint64_total, seed)]
      -- let bytes32_h = $hash_<bytes>($concat_bytes($bytes32_to_bytes(seed), $uint64_to_bytes_le((i / 32))))
      -- let uint64_random_byte = $bytes1_to_uint64($bytes32_to_bytes1_list(bytes32_h)[(i \ 32)])
      -- let balance_effective = state.VALIDATORS[vid_candidate].EFFECTIVE_BALANCE
      -- if (balance_effective <= ($UINT64_MAX / $MAX_RANDOM_BYTE))   ;; [ins:overflow]
      -- if ((balance_effective * $MAX_RANDOM_BYTE) < ($MAX_EFFECTIVE_BALANCE * uint64_random_byte))

;; spec/spec_deneb/08-helpers-selection.spectec:92:1-92:84:
def $compute_proposer_index(beaconState, validatorIndex*, bytes32) : validatorIndex =

   ;; spec/spec_deneb/08-helpers-selection.spectec:94:1-97:24:
   clause 0(state, vid*{vid <- vid*}, seed) = $compute_proposer_index_loop(state, vid*{vid <- vid*}, seed, |vid*{vid <- vid*}|, 0)
      -- if (|vid*{vid <- vid*}| > 0)

;; spec/spec_deneb/08-helpers-selection.spectec:102:1-102:56:
def $get_seed(beaconState, epoch, domainType) : bytes32 =

   ;; spec/spec_deneb/08-helpers-selection.spectec:104:1-115:24:
   clause 0(state, epoch, domainType) = $hash_<bytes>($concat_bytes($concat_bytes($bytes4_to_bytes(domainType), $uint64_to_bytes_le(epoch)), $bytes32_to_bytes(bytes32_mix)))
      -- let bytes32_mix = $get_randao_mix(state, (((epoch + $EPOCHS_PER_HISTORICAL_VECTOR) - $MIN_SEED_LOOKAHEAD) - 1))

;; spec/spec_deneb/08-helpers-selection.spectec:118:1-118:61:
def $get_beacon_proposer_index(beaconState) : validatorIndex =

   ;; spec/spec_deneb/08-helpers-selection.spectec:120:1-129:63:
   clause 0(state) = $compute_proposer_index(state, vid*{vid <- vid*}, seed)
      -- let epoch_cur = $get_current_epoch(state)
      -- let seed = $hash_<bytes>($concat_bytes($bytes32_to_bytes($get_seed(state, epoch_cur, $DOMAIN_BEACON_PROPOSER)), $uint64_to_bytes_le(state.SLOT)))
      -- let vid*{vid <- vid*} = $get_active_validator_indices(state, epoch_cur)

;; spec/spec_deneb/09-helpers-balance.spectec:9:1-11:23:
relation IncreaseBalance: beaconState .BALANCES[ validatorIndex ]+ gwei ~> beaconState

   ;; spec/spec_deneb/09-helpers-balance.spectec:13:1-18:42:
   rule : state .BALANCES[ vid ]+ delta ~> state[BALANCES[vid] = (balance + delta)]
      -- if (vid < |state.BALANCES|)
      -- let balance = state.BALANCES[vid]
      -- if (balance <= ($UINT64_MAX - delta))   ;; [ins:overflow]

;; spec/spec_deneb/09-helpers-balance.spectec:24:1-26:23:
relation DecreaseBalance: beaconState .BALANCES[ validatorIndex ]- gwei ~> beaconState

   ;; spec/spec_deneb/09-helpers-balance.spectec:28:1-33:27:
   rule zero: state .BALANCES[ vid ]- delta ~> state[BALANCES[vid] = 0]
      -- if (vid < |state.BALANCES|)
      -- let balance = state.BALANCES[vid]
      -- if (delta > balance)

   ;; spec/spec_deneb/09-helpers-balance.spectec:35:1-40:28:
   rule remains: state .BALANCES[ vid ]- delta ~> state[BALANCES[vid] = (balance - delta)]
      -- if (vid < |state.BALANCES|)
      -- let balance = state.BALANCES[vid]
      -- if (delta <= balance)

;; spec/spec_deneb/09-helpers-balance.spectec:45:1-45:52:
def $exit_epoch_not_far_future(validator) : boolean =

   ;; spec/spec_deneb/09-helpers-balance.spectec:46:1-47:51:
   clause 0(validator) = true
      -- if (validator.EXIT_EPOCH =/= $FAR_FUTURE_EPOCH)

   ;; spec/spec_deneb/09-helpers-balance.spectec:48:1-49:15:
   clause 1(validator) = false
      -- otherwise

;; spec/spec_deneb/09-helpers-balance.spectec:51:1-51:47:
def $exit_epoch_eq(validator, epoch) : boolean =

   ;; spec/spec_deneb/09-helpers-balance.spectec:52:1-53:37:
   clause 0(validator, epoch) = true
      -- if (validator.EXIT_EPOCH = epoch)

   ;; spec/spec_deneb/09-helpers-balance.spectec:54:1-55:15:
   clause 1(validator, epoch) = false
      -- otherwise

;; spec/spec_deneb/09-helpers-balance.spectec:58:1-58:42:
def $fold_max_epoch(epoch, epoch) : epoch =

   ;; spec/spec_deneb/09-helpers-balance.spectec:59:1-59:74:
   clause 0(epoch_acc, epoch_x) = $max_uint64(epoch_acc, epoch_x)

;; spec/spec_deneb/09-helpers-balance.spectec:62:1-62:60:
def $select_epoch_exit_queue(epoch, uint64, uint64) : epoch =

   ;; spec/spec_deneb/09-helpers-balance.spectec:63:1-65:42:
   clause 0(epoch_exit_queue_0, uint64_churn, uint64_limit) = (epoch_exit_queue_0 + 1)
      -- if (uint64_churn >= uint64_limit)

   ;; spec/spec_deneb/09-helpers-balance.spectec:66:1-68:15:
   clause 1(epoch_exit_queue_0, uint64_churn, uint64_limit) = epoch_exit_queue_0
      -- otherwise

;; spec/spec_deneb/09-helpers-balance.spectec:74:1-76:20:
relation InitiateValidatorExit: beaconState .VALIDATORS[ validatorIndex ]~> beaconState

   ;; spec/spec_deneb/09-helpers-balance.spectec:79:1-85:51:
   rule skip: state .VALIDATORS[ vid ]~> state
      -- if (vid < |state.VALIDATORS|)   ;; [ins:bounds]
      -- let validator = state.VALIDATORS[vid]
      -- if (validator.EXIT_EPOCH =/= $FAR_FUTURE_EPOCH)

   ;; spec/spec_deneb/09-helpers-balance.spectec:88:1-106:90:
   rule main: state .VALIDATORS[ vid ]~> state[VALIDATORS[vid] = validator[EXIT_EPOCH = epoch_exit_queue][WITHDRAWABLE_EPOCH = epoch_withdrawable]]
      -- if (vid < |state.VALIDATORS|)
      -- let validator = state.VALIDATORS[vid]
      -- if (validator.EXIT_EPOCH = $FAR_FUTURE_EPOCH)
      -- let validator_exit*{validator_exit <- validator_exit*} = $filter_list_<validator>(state.VALIDATORS, $exit_epoch_not_far_future)
      -- (let epoch_exit = validator_exit.EXIT_EPOCH)*{epoch_exit <- epoch_exit*, validator_exit <- validator_exit*}
      -- let epoch_exit_queue_0 = $fold_<epoch, epoch>($fold_max_epoch, 0, epoch_exit*{epoch_exit <- epoch_exit*} ++ [$compute_activation_exit_epoch($get_current_epoch(state))])
      -- let validator_exit_queue*{validator_exit_queue <- validator_exit_queue*} = $filter_list_2_<validator, epoch>(validator_exit*{validator_exit <- validator_exit*}, epoch_exit_queue_0, $exit_epoch_eq)
      -- let uint64_exit_queue_churn = |validator_exit_queue*{validator_exit_queue <- validator_exit_queue*}|
      -- let uint64_churn_limit = $get_validator_churn_limit(state)
      -- let epoch_exit_queue = $select_epoch_exit_queue(epoch_exit_queue_0, uint64_exit_queue_churn, uint64_churn_limit)
      -- if (epoch_exit_queue <= ($UINT64_MAX - $MIN_VALIDATOR_WITHDRAWABILITY_DELAY))   ;; [ins:overflow]
      -- let epoch_withdrawable = (epoch_exit_queue + $MIN_VALIDATOR_WITHDRAWABILITY_DELAY)

;; spec/spec_deneb/09-helpers-balance.spectec:112:1-114:23:
relation SlashValidator: beaconState SLASH[ validatorIndex ]BY validatorIndex? ~> beaconState

   ;; spec/spec_deneb/09-helpers-balance.spectec:117:1-141:117:
   rule no_whistleblower: state SLASH[ vid_slashed ]BY validatorIndex?{validatorIndex <- validatorIndex?} ~> state_out
      -- if validatorIndex?{validatorIndex <- validatorIndex?} matches ()
      -- if (vid_slashed < |state.VALIDATORS|)
      -- let epoch = $get_current_epoch(state)
      -- rel InitiateValidatorExit: state .VALIDATORS[ vid_slashed ]~> state_init
      -- let validator = state_init.VALIDATORS[vid_slashed]
      -- let epoch_withdrawable = $max_uint64(validator.WITHDRAWABLE_EPOCH, (epoch + $EPOCHS_PER_SLASHINGS_VECTOR))
      -- let state_1 = state_init[VALIDATORS[vid_slashed] = validator[SLASHED = true][WITHDRAWABLE_EPOCH = epoch_withdrawable]]
      -- if (state_1.SLASHINGS[(epoch \ $EPOCHS_PER_SLASHINGS_VECTOR)] <= ($UINT64_MAX - validator.EFFECTIVE_BALANCE))   ;; [ins:overflow]
      -- let state_2 = state_1[SLASHINGS[(epoch \ $EPOCHS_PER_SLASHINGS_VECTOR)] = (state_1.SLASHINGS[(epoch \ $EPOCHS_PER_SLASHINGS_VECTOR)] + validator.EFFECTIVE_BALANCE)]
      -- let penalty_slashing = (validator.EFFECTIVE_BALANCE / $MIN_SLASHING_PENALTY_QUOTIENT_BELLATRIX)
      -- rel DecreaseBalance: state_2 .BALANCES[ vid_slashed ]- penalty_slashing ~> state_penalized
      -- let vid_proposer = $get_beacon_proposer_index(state_penalized)
      -- let reward_whistleblower = (validator.EFFECTIVE_BALANCE / $WHISTLEBLOWER_REWARD_QUOTIENT)
      -- let gwei_prop_num = (reward_whistleblower * $PROPOSER_WEIGHT)
      -- let reward_proposer = (gwei_prop_num / $WEIGHT_DENOMINATOR)
      -- rel IncreaseBalance: state_penalized .BALANCES[ vid_proposer ]+ reward_proposer ~> state_rewarded_proposer
      -- let reward_whistleblower_rest = (reward_whistleblower - reward_proposer)
      -- rel IncreaseBalance: state_rewarded_proposer .BALANCES[ vid_proposer ]+ reward_whistleblower_rest ~> state_out

   ;; spec/spec_deneb/09-helpers-balance.spectec:144:1-168:122:
   rule whistleblower: state SLASH[ vid_slashed ]BY validatorIndex?{validatorIndex <- validatorIndex?} ~> state_out
      -- if validatorIndex?{validatorIndex <- validatorIndex?} matches (_)
      -- let ?(vid_whistleblower) = validatorIndex?{validatorIndex <- validatorIndex?}
      -- if (vid_slashed < |state.VALIDATORS|)
      -- let epoch = $get_current_epoch(state)
      -- rel InitiateValidatorExit: state .VALIDATORS[ vid_slashed ]~> state_init
      -- let validator = state_init.VALIDATORS[vid_slashed]
      -- let epoch_withdrawable = $max_uint64(validator.WITHDRAWABLE_EPOCH, (epoch + $EPOCHS_PER_SLASHINGS_VECTOR))
      -- let state_1 = state_init[VALIDATORS[vid_slashed] = validator[SLASHED = true][WITHDRAWABLE_EPOCH = epoch_withdrawable]]
      -- if (state_1.SLASHINGS[(epoch \ $EPOCHS_PER_SLASHINGS_VECTOR)] <= ($UINT64_MAX - validator.EFFECTIVE_BALANCE))   ;; [ins:overflow]
      -- let state_2 = state_1[SLASHINGS[(epoch \ $EPOCHS_PER_SLASHINGS_VECTOR)] = (state_1.SLASHINGS[(epoch \ $EPOCHS_PER_SLASHINGS_VECTOR)] + validator.EFFECTIVE_BALANCE)]
      -- let penalty_slashing = (validator.EFFECTIVE_BALANCE / $MIN_SLASHING_PENALTY_QUOTIENT_BELLATRIX)
      -- rel DecreaseBalance: state_2 .BALANCES[ vid_slashed ]- penalty_slashing ~> state_penalized
      -- let vid_proposer = $get_beacon_proposer_index(state_penalized)
      -- let reward_whistleblower = (validator.EFFECTIVE_BALANCE / $WHISTLEBLOWER_REWARD_QUOTIENT)
      -- let gwei_prop_num = (reward_whistleblower * $PROPOSER_WEIGHT)
      -- let reward_proposer = (gwei_prop_num / $WEIGHT_DENOMINATOR)
      -- rel IncreaseBalance: state_penalized .BALANCES[ vid_proposer ]+ reward_proposer ~> state_rewarded_proposer
      -- let reward_whistleblower_rest = (reward_whistleblower - reward_proposer)
      -- rel IncreaseBalance: state_rewarded_proposer .BALANCES[ vid_whistleblower ]+ reward_whistleblower_rest ~> state_out

;; spec/spec_deneb/09-helpers-balance.spectec:175:1-177:29:
relation ApplyDeposit: beaconState .VALIDATORS++{ blsPubkey bytes32 gwei }SIGNED blsSignature ~> beaconState

   ;; spec/spec_deneb/09-helpers-balance.spectec:180:1-191:103:
   rule new_pubkey: state .VALIDATORS++{ blsPubkey bytes32_wc gwei_amount }SIGNED blsSignature ~> state_out
      -- let validator*{validator <- validator*} = state.VALIDATORS
      -- (let blsPubkey_existing = validator.PUBKEY)*{blsPubkey_existing <- blsPubkey_existing*, validator <- validator*}
      -- if ~blsPubkey <- blsPubkey_existing*{blsPubkey_existing <- blsPubkey_existing*}
      -- let depositMessage = {PUBKEY blsPubkey, WITHDRAWAL_CREDENTIALS bytes32_wc, AMOUNT gwei_amount}
      -- let domain = $compute_domain($DOMAIN_DEPOSIT, ?(), ?())
      -- if $bls_verify(blsPubkey, $compute_signing_root_depositMessage(depositMessage, domain), blsSignature)
      -- rel AddValidatorToRegistry: state .VALIDATORS++{ blsPubkey bytes32_wc gwei_amount }~> state_out

   ;; spec/spec_deneb/09-helpers-balance.spectec:194:1-204:108:
   rule new_pubkey_invalid_sig: state .VALIDATORS++{ blsPubkey bytes32_wc gwei_amount }SIGNED blsSignature ~> state
      -- let validator*{validator <- validator*} = state.VALIDATORS
      -- (let blsPubkey_existing = validator.PUBKEY)*{blsPubkey_existing <- blsPubkey_existing*, validator <- validator*}
      -- if ~blsPubkey <- blsPubkey_existing*{blsPubkey_existing <- blsPubkey_existing*}
      -- let depositMessage = {PUBKEY blsPubkey, WITHDRAWAL_CREDENTIALS bytes32_wc, AMOUNT gwei_amount}
      -- let domain = $compute_domain($DOMAIN_DEPOSIT, ?(), ?())
      -- if ~$bls_verify(blsPubkey, $compute_signing_root_depositMessage(depositMessage, domain), blsSignature)

   ;; spec/spec_deneb/09-helpers-balance.spectec:208:1-214:82:
   rule existing_pubkey: state .VALIDATORS++{ blsPubkey bytes32_wc gwei_amount }SIGNED blsSignature ~> state_out
      -- let (vid, validator)*{validator <- validator*, vid <- vid*} = $enumerate_<validator>(state.VALIDATORS)
      -- (let blsPubkey_existing = validator.PUBKEY)*{blsPubkey_existing <- blsPubkey_existing*, validator <- validator*}
      -- if blsPubkey <- blsPubkey_existing*{blsPubkey_existing <- blsPubkey_existing*}
      -- let vid_found = $index_of_pubkey((vid, blsPubkey_existing)*{blsPubkey_existing <- blsPubkey_existing*, vid <- vid*}, blsPubkey)
      -- rel IncreaseBalance: state .BALANCES[ vid_found ]+ gwei_amount ~> state_out

;; spec/spec_deneb/10-helpers-attestation.spectec:2:1-2:83:
def $compute_committee(validatorIndex*, bytes32, uint64, uint64) : validatorIndex* =

   ;; spec/spec_deneb/10-helpers-attestation.spectec:4:1-10:44:
   clause 0(vid*{vid <- vid*}, seed, i, count) = vid_committee*{vid_committee <- vid_committee*}
      -- let i_start = ((|vid*{vid <- vid*}| * i) / count)
      -- let i_end = ((|vid*{vid <- vid*}| * (i + 1)) / count)
      -- let n*{n <- n*} = $range((i_end - i_start))
      -- (let i_range = (n + i_start))*{i_range <- i_range*, n <- n*}
      -- (let i_shuffled = $compute_shuffled_index(i_range, |vid*{vid <- vid*}|, seed))*{i_range <- i_range*, i_shuffled <- i_shuffled*}
      -- (let vid_committee = vid*{vid <- vid*}[i_shuffled])*{i_shuffled <- i_shuffled*, vid_committee <- vid_committee*}

;; spec/spec_deneb/10-helpers-attestation.spectec:13:1-13:63:
def $get_committee_count_per_slot(beaconState, epoch) : uint64 =

   ;; spec/spec_deneb/10-helpers-attestation.spectec:14:1-23:6:
   clause 0(state, epoch) = $max_uint64(1, $min_uint64($MAX_COMMITTEES_PER_SLOT, ((|$get_active_validator_indices(state, epoch)| / $SLOTS_PER_EPOCH) / $TARGET_COMMITTEE_SIZE)))

;; spec/spec_deneb/10-helpers-attestation.spectec:26:1-26:79:
def $get_beacon_committee(beaconState, slot, committeeIndex) : validatorIndex* =

   ;; spec/spec_deneb/10-helpers-attestation.spectec:27:1-35:80:
   clause 0(state, slot, committeeIndex) = $compute_committee($get_active_validator_indices(state, epoch), $get_seed(state, epoch, $DOMAIN_BEACON_ATTESTER), (((slot \ $SLOTS_PER_EPOCH) * count_committees_per_slot) + committeeIndex), (count_committees_per_slot * $SLOTS_PER_EPOCH))
      -- let epoch = $compute_epoch_at_slot(slot)
      -- let count_committees_per_slot = $get_committee_count_per_slot(state, epoch)

;; spec/spec_deneb/10-helpers-attestation.spectec:38:1-38:65:
def $bit_is_one_at_index((nat, validatorIndex), boolean*) : bool =

   ;; spec/spec_deneb/10-helpers-attestation.spectec:40:1-43:22:
   clause 0((i, _validatorIndex), bit*{bit <- bit*}) = bit*{bit <- bit*}[i]
      -- if (i < |bit*{bit <- bit*}|)   ;; [ins:bounds]

;; spec/spec_deneb/10-helpers-attestation.spectec:46:1-46:71:
def $get_attesting_indices(beaconState, attestation) : validatorIndex* =

   ;; spec/spec_deneb/10-helpers-attestation.spectec:48:1-61:60:
   clause 0(state, attestation) = vid_set*{vid_set <- vid_set*}
      -- let vid_committee*{vid_committee <- vid_committee*} = $get_beacon_committee(state, attestation.DATA.SLOT, attestation.DATA.INDEX)
      -- let (i, vid)*{i <- i*, vid <- vid*} = $enumerate_<validatorIndex>(vid_committee*{vid_committee <- vid_committee*})
      -- let (_nat, vid_attesting)*{_nat <- _nat*, vid_attesting <- vid_attesting*} = $filter_list_2_<(nat, validatorIndex), boolean*>((i, vid)*{i <- i*, vid <- vid*}, attestation.AGGREGATION_BITS, $bit_is_one_at_index)
      -- let vid_set*{vid_set <- vid_set*} = $to_set_<validatorIndex>(vid_attesting*{vid_attesting <- vid_attesting*})

;; spec/spec_deneb/10-helpers-attestation.spectec:64:1-64:76:
def $is_slashable_attestation_data(attestationData, attestationData) : bool =

   ;; spec/spec_deneb/10-helpers-attestation.spectec:65:1-70:78:
   clause 0(attestationData_1, attestationData_2) = (((attestationData_1 =/= attestationData_2) /\ (attestationData_1.TARGET.EPOCH = attestationData_2.TARGET.EPOCH)) \/ ((attestationData_1.SOURCE.EPOCH < attestationData_2.SOURCE.EPOCH) /\ (attestationData_2.TARGET.EPOCH < attestationData_1.TARGET.EPOCH)))

;; spec/spec_deneb/10-helpers-attestation.spectec:73:1-73:77:
def $is_valid_indexed_attestation(beaconState, indexedAttestation) : boolean =

   ;; spec/spec_deneb/10-helpers-attestation.spectec:75:1-76:51:
   clause 0(state, indexedAttestation) = false
      -- if (|indexedAttestation.ATTESTING_INDICES| = 0)

   ;; spec/spec_deneb/10-helpers-attestation.spectec:78:1-80:43:
   clause 1(state, indexedAttestation) = false
      -- if ($sort_<validatorIndex>($to_set_<validatorIndex>(indexedAttestation.ATTESTING_INDICES)) =/= indexedAttestation.ATTESTING_INDICES)

   ;; spec/spec_deneb/10-helpers-attestation.spectec:82:1-92:94:
   clause 2(state, indexedAttestation) = $bls_fast_aggregate_verify(blsPubkey*{blsPubkey <- blsPubkey*}, root_signing, indexedAttestation.SIGNATURE)
      -- let vid*{vid <- vid*} = indexedAttestation.ATTESTING_INDICES
      -- if (|indexedAttestation.ATTESTING_INDICES| > 0)
      -- if ($sort_<validatorIndex>($to_set_<validatorIndex>(indexedAttestation.ATTESTING_INDICES)) = indexedAttestation.ATTESTING_INDICES)
      -- (if (vid < |state.VALIDATORS|))*{vid <- vid*}
      -- (let blsPubkey = state.VALIDATORS[vid].PUBKEY)*{blsPubkey <- blsPubkey*, vid <- vid*}
      -- let domain = $get_domain(state, $DOMAIN_BEACON_ATTESTER, ?(indexedAttestation.DATA.TARGET.EPOCH))
      -- let root_signing = $compute_signing_root_attestationData(indexedAttestation.DATA, domain)

;; spec/spec_deneb/10-helpers-attestation.spectec:96:1-98:20:
relation SlashIfEligible: beaconState SLASH?[ validatorIndex ]~> beaconState #SLASHED bool

   ;; spec/spec_deneb/10-helpers-attestation.spectec:100:1-104:66:
   rule true: state SLASH?[ vid ]~> state_slashed #SLASHED true
      -- if (vid < |state.VALIDATORS|)
      -- if $is_slashable_validator(state.VALIDATORS[vid], $get_current_epoch(state))
      -- rel SlashValidator: state SLASH[ vid ]BY ?() ~> state_slashed

   ;; spec/spec_deneb/10-helpers-attestation.spectec:106:1-109:83:
   rule false: state SLASH?[ vid ]~> state #SLASHED false
      -- if (vid < |state.VALIDATORS|)
      -- if ~$is_slashable_validator(state.VALIDATORS[vid], $get_current_epoch(state))

;; spec/spec_deneb/10-helpers-attestation.spectec:112:1-114:20:
relation SlashIfEligible_over_validators: beaconState SLASH?[ validatorIndex* ]~> beaconState #SLASHED bool

   ;; spec/spec_deneb/10-helpers-attestation.spectec:116:1-117:50:
   rule nil: state SLASH?[ validatorIndex*{validatorIndex <- validatorIndex*} ]~> state #SLASHED false
      -- if validatorIndex*{validatorIndex <- validatorIndex*} matches []

   ;; spec/spec_deneb/10-helpers-attestation.spectec:119:1-122:94:
   rule cons: state SLASH?[ validatorIndex*{validatorIndex <- validatorIndex*} ]~> state_t #SLASHED (bool_h \/ bool_t)
      -- if validatorIndex*{validatorIndex <- validatorIndex*} matches _ :: _
      -- let vid_h :: vid_t*{vid_t <- vid_t*} = validatorIndex*{validatorIndex <- validatorIndex*}
      -- rel SlashIfEligible: state SLASH?[ vid_h ]~> state_h #SLASHED bool_h
      -- rel SlashIfEligible_over_validators: state_h SLASH?[ vid_t*{vid_t <- vid_t*} ]~> state_t #SLASHED bool_t

;; spec/spec_deneb/10-helpers-attestation.spectec:125:1-125:37:
def $source_flag_list(uint64) : nat* =

   ;; spec/spec_deneb/10-helpers-attestation.spectec:127:1-129:76:
   clause 0(uint64_inclusion_delay) = [$TIMELY_SOURCE_FLAG_INDEX]
      -- if (uint64_inclusion_delay <= $integer_square_root($SLOTS_PER_EPOCH))

   ;; spec/spec_deneb/10-helpers-attestation.spectec:130:1-131:15:
   clause 1(_uint64) = []
      -- otherwise

;; spec/spec_deneb/10-helpers-attestation.spectec:133:1-133:35:
def $target_flag_list(bool) : nat* =

   ;; spec/spec_deneb/10-helpers-attestation.spectec:135:1-136:34:
   clause 0(bool_matching_target) = [$TIMELY_TARGET_FLAG_INDEX]

   ;; spec/spec_deneb/10-helpers-attestation.spectec:139:1-140:15:
   clause 1(_bool) = []
      -- otherwise

;; spec/spec_deneb/10-helpers-attestation.spectec:141:1-141:41:
def $head_flag_list(bool, uint64) : nat* =

   ;; spec/spec_deneb/10-helpers-attestation.spectec:143:1-145:69:
   clause 0(bool_matching_head, uint64_inclusion_delay) = [$TIMELY_HEAD_FLAG_INDEX]
      -- if (uint64_inclusion_delay = $MIN_ATTESTATION_INCLUSION_DELAY)

   ;; spec/spec_deneb/10-helpers-attestation.spectec:146:1-147:15:
   clause 1(_bool, _uint64) = []
      -- otherwise

;; spec/spec_deneb/10-helpers-attestation.spectec:150:1-150:93:
def $get_attestation_participation_flag_indices(beaconState, attestationData, uint64) : nat* =

   ;; spec/spec_deneb/10-helpers-attestation.spectec:152:1-171:67:
   clause 0(state, attestationData, uint64_inclusion_delay) = flag_indices*{flag_indices <- flag_indices*}
      -- if (attestationData.TARGET.EPOCH = $get_current_epoch(state))
      -- let checkpoint_justified = state.CURRENT_JUSTIFIED_CHECKPOINT
      -- if (attestationData.SOURCE.EPOCH = checkpoint_justified.EPOCH)
      -- if (attestationData.SOURCE.ROOT = checkpoint_justified.ROOT)
      -- let root_target = $get_block_root(state, attestationData.TARGET.EPOCH)
      -- let bool_target_root_matches = (attestationData.TARGET.ROOT = root_target)
      -- let root_head = $get_block_root_at_slot(state, attestationData.SLOT)
      -- let bool_head_root_matches = (attestationData.BEACON_BLOCK_ROOT = root_head)
      -- let flag_source*{flag_source <- flag_source*} = $source_flag_list(uint64_inclusion_delay)
      -- let flag_target*{flag_target <- flag_target*} = $target_flag_list(bool_target_root_matches)
      -- let flag_head*{flag_head <- flag_head*} = $head_flag_list((bool_target_root_matches /\ bool_head_root_matches), uint64_inclusion_delay)
      -- let flag_indices*{flag_indices <- flag_indices*} = flag_source*{flag_source <- flag_source*} ++ flag_target*{flag_target <- flag_target*} ++ flag_head*{flag_head <- flag_head*}

   ;; spec/spec_deneb/10-helpers-attestation.spectec:173:1-192:67:
   clause 1(state, attestationData, uint64_inclusion_delay) = flag_indices*{flag_indices <- flag_indices*}
      -- if (attestationData.TARGET.EPOCH =/= $get_current_epoch(state))
      -- let checkpoint_justified = state.PREVIOUS_JUSTIFIED_CHECKPOINT
      -- if (attestationData.SOURCE.EPOCH = checkpoint_justified.EPOCH)
      -- if (attestationData.SOURCE.ROOT = checkpoint_justified.ROOT)
      -- let root_target = $get_block_root(state, attestationData.TARGET.EPOCH)
      -- let bool_target_root_matches = (attestationData.TARGET.ROOT = root_target)
      -- let root_head = $get_block_root_at_slot(state, attestationData.SLOT)
      -- let bool_head_root_matches = (attestationData.BEACON_BLOCK_ROOT = root_head)
      -- let flag_source*{flag_source <- flag_source*} = $source_flag_list(uint64_inclusion_delay)
      -- let flag_target*{flag_target <- flag_target*} = $target_flag_list(bool_target_root_matches)
      -- let flag_head*{flag_head <- flag_head*} = $head_flag_list((bool_target_root_matches /\ bool_head_root_matches), uint64_inclusion_delay)
      -- let flag_indices*{flag_indices <- flag_indices*} = flag_source*{flag_source <- flag_source*} ++ flag_target*{flag_target <- flag_target*} ++ flag_head*{flag_head <- flag_head*}

;; spec/spec_deneb/10-helpers-attestation.spectec:195:1-197:20:
def $next_sync_committee_indices_loop(beaconState, validatorIndex*, bytes32, uint64, uint64, validatorIndex*) : validatorIndex* =

   ;; spec/spec_deneb/10-helpers-attestation.spectec:200:1-202:57:
   clause 0(_beaconState, _validatorIndex*{_validatorIndex <- _validatorIndex*}, _bytes32, _uint64, _uint64', vid_sync_committee*{vid_sync_committee <- vid_sync_committee*}) = vid_sync_committee*{vid_sync_committee <- vid_sync_committee*}
      -- if (|vid_sync_committee*{vid_sync_committee <- vid_sync_committee*}| >= $SYNC_COMMITTEE_SIZE)

   ;; spec/spec_deneb/10-helpers-attestation.spectec:205:1-223:97:
   clause 1(state, vid_active*{vid_active <- vid_active*}, seed, count_active, vid, vid_sync_committee*{vid_sync_committee <- vid_sync_committee*}) = $next_sync_committee_indices_loop(state, vid_active*{vid_active <- vid_active*}, seed, count_active, (vid + 1), vid_sync_committee*{vid_sync_committee <- vid_sync_committee*} ++ [vid_candidate])
      -- if (|vid_sync_committee*{vid_sync_committee <- vid_sync_committee*}| < $SYNC_COMMITTEE_SIZE)
      -- let vid_candidate = vid_active*{vid_active <- vid_active*}[$compute_shuffled_index((vid \ count_active), count_active, seed)]
      -- let bytes32_h = $hash_<bytes>($concat_bytes($bytes32_to_bytes(seed), $uint_to_bytes((vid / 32))))
      -- let uint64_random_byte = $bytes1_to_uint64($bytes32_to_bytes1_list(bytes32_h)[(vid \ 32)])
      -- let balance_effective = state.VALIDATORS[vid_candidate].EFFECTIVE_BALANCE
      -- if (balance_effective <= ($UINT64_MAX / $MAX_RANDOM_BYTE))   ;; [ins:overflow]
      -- if ((balance_effective * $MAX_RANDOM_BYTE) >= ($MAX_EFFECTIVE_BALANCE * uint64_random_byte))   ;; [ins:overflow]

   ;; spec/spec_deneb/10-helpers-attestation.spectec:227:1-245:96:
   clause 2(state, vid_active*{vid_active <- vid_active*}, seed, count_active, vid, vid_sync_committee*{vid_sync_committee <- vid_sync_committee*}) = $next_sync_committee_indices_loop(state, vid_active*{vid_active <- vid_active*}, seed, count_active, (vid + 1), vid_sync_committee*{vid_sync_committee <- vid_sync_committee*})
      -- if (|vid_sync_committee*{vid_sync_committee <- vid_sync_committee*}| < $SYNC_COMMITTEE_SIZE)
      -- let vid_candidate = vid_active*{vid_active <- vid_active*}[$compute_shuffled_index((vid \ count_active), count_active, seed)]
      -- let bytes32_h = $hash_<bytes>($concat_bytes($bytes32_to_bytes(seed), $uint_to_bytes((vid / 32))))
      -- let uint64_random_byte = $bytes1_to_uint64($bytes32_to_bytes1_list(bytes32_h)[(vid \ 32)])
      -- let balance_effective = state.VALIDATORS[vid_candidate].EFFECTIVE_BALANCE
      -- if (balance_effective <= ($UINT64_MAX / $MAX_RANDOM_BYTE))   ;; [ins:overflow]
      -- if ((balance_effective * $MAX_RANDOM_BYTE) < ($MAX_EFFECTIVE_BALANCE * uint64_random_byte))   ;; [ins:overflow]

;; spec/spec_deneb/10-helpers-attestation.spectec:250:1-250:68:
def $get_next_sync_committee_indices(beaconState) : validatorIndex* =

   ;; spec/spec_deneb/10-helpers-attestation.spectec:252:1-266:20:
   clause 0(state) = vid_out*{vid_out <- vid_out*}
      -- let epoch_next = ($get_current_epoch(state) + 1)
      -- let vid_active*{vid_active <- vid_active*} = $get_active_validator_indices(state, epoch_next)
      -- let count_active = |vid_active*{vid_active <- vid_active*}|
      -- if (count_active > 0)   ;; [ins:divisor]
      -- let seed = $get_seed(state, epoch_next, $DOMAIN_SYNC_COMMITTEE)
      -- let vid_out*{vid_out <- vid_out*} = $next_sync_committee_indices_loop(state, vid_active*{vid_active <- vid_active*}, seed, count_active, 0, [])

;; spec/spec_deneb/10-helpers-attestation.spectec:269:1-269:58:
def $get_next_sync_committee(beaconState) : syncCommittee =

   ;; spec/spec_deneb/10-helpers-attestation.spectec:271:1-276:65:
   clause 0(state) = {PUBKEYS blsPubkey*{blsPubkey <- blsPubkey*}, AGGREGATE_PUBKEY blsPubkey_aggregate}
      -- let vid*{vid <- vid*} = $get_next_sync_committee_indices(state)
      -- (let blsPubkey = state.VALIDATORS[vid].PUBKEY)*{blsPubkey <- blsPubkey*, vid <- vid*}
      -- let blsPubkey_aggregate = $eth_aggregate_pubkeys(blsPubkey*{blsPubkey <- blsPubkey*})

;; spec/spec_deneb/10-helpers-attestation.spectec:280:1-280:76:
def $get_indexed_attestation(beaconState, attestation) : indexedAttestation =

   ;; spec/spec_deneb/10-helpers-attestation.spectec:282:1-286:68:
   clause 0(state, attestation) = {ATTESTING_INDICES $sort_<validatorIndex>(vid_attesting*{vid_attesting <- vid_attesting*}), DATA attestation.DATA, SIGNATURE attestation.SIGNATURE}
      -- let vid_attesting*{vid_attesting <- vid_attesting*} = $get_attesting_indices(state, attestation)

;; spec/spec_deneb/11-helpers-rewards-penalties.spectec:6:1-6:60:
def $get_total_balance(beaconState, validatorIndex*) : gwei =

   ;; spec/spec_deneb/11-helpers-rewards-penalties.spectec:8:1-16:35:
   clause 0(state, vid*{vid <- vid*}) = $max_uint64($EFFECTIVE_BALANCE_INCREMENT, gwei_sum)
      -- (let balance = state.VALIDATORS[vid].EFFECTIVE_BALANCE)*{balance <- balance*, vid <- vid*}
      -- let gwei_sum = $sum_<gwei>(balance*{balance <- balance*})
      -- if (gwei_sum <= $UINT64_MAX)   ;; [ins:overflow]

;; spec/spec_deneb/11-helpers-rewards-penalties.spectec:18:1-18:50:
def $get_total_active_balance(beaconState) : gwei =

   ;; spec/spec_deneb/11-helpers-rewards-penalties.spectec:20:1-24:57:
   clause 0(state) = gwei_total
      -- let epoch_cur = $get_current_epoch(state)
      -- let vid_active*{vid_active <- vid_active*} = $get_active_validator_indices(state, epoch_cur)
      -- let vid_set*{vid_set <- vid_set*} = $to_set_<validatorIndex>(vid_active*{vid_active <- vid_active*})
      -- let gwei_total = $get_total_balance(state, vid_set*{vid_set <- vid_set*})

;; spec/spec_deneb/11-helpers-rewards-penalties.spectec:27:1-27:55:
def $get_base_reward_per_increment(beaconState) : gwei =

   ;; spec/spec_deneb/11-helpers-rewards-penalties.spectec:29:1-33:7:
   clause 0(state) = (($EFFECTIVE_BALANCE_INCREMENT * $BASE_REWARD_FACTOR) / $integer_square_root($get_total_active_balance(state)))

;; spec/spec_deneb/11-helpers-rewards-penalties.spectec:36:1-36:57:
def $get_base_reward(beaconState, validatorIndex) : gwei =

   ;; spec/spec_deneb/11-helpers-rewards-penalties.spectec:38:1-42:80:
   clause 0(state, vid) = reward
      -- if (vid < |state.VALIDATORS|)   ;; [ins:bounds]
      -- let uint64_increments = (state.VALIDATORS[vid].EFFECTIVE_BALANCE / $EFFECTIVE_BALANCE_INCREMENT)
      -- let reward = (uint64_increments * $get_base_reward_per_increment(state))

;; spec/spec_deneb/11-helpers-rewards-penalties.spectec:45:1-47:20:
relation ApplyEffectiveBalance: validator .EFFECTIVE_BALANCE gwei ~> validator

   ;; spec/spec_deneb/11-helpers-rewards-penalties.spectec:49:1-66:70:
   rule main: validator .EFFECTIVE_BALANCE balance ~> validator[EFFECTIVE_BALANCE = $min_uint64((balance - (balance \ $EFFECTIVE_BALANCE_INCREMENT)), $MAX_EFFECTIVE_BALANCE)]
      -- let uint64_hyst_inc = ($EFFECTIVE_BALANCE_INCREMENT / $HYSTERESIS_QUOTIENT)
      -- let uint64_down_th = (uint64_hyst_inc * $HYSTERESIS_DOWNWARD_MULTIPLIER)
      -- let uint64_up_th = (uint64_hyst_inc * $HYSTERESIS_UPWARD_MULTIPLIER)
      -- if (balance <= ($UINT64_MAX - uint64_down_th))   ;; [ins:overflow]
      -- if (((balance + uint64_down_th) < validator.EFFECTIVE_BALANCE) \/ ((validator.EFFECTIVE_BALANCE <= ($UINT64_MAX - uint64_up_th)) /\ ((validator.EFFECTIVE_BALANCE + uint64_up_th) < balance)))

   ;; spec/spec_deneb/11-helpers-rewards-penalties.spectec:68:1-79:67:
   rule skip: validator .EFFECTIVE_BALANCE balance ~> validator
      -- let uint64_hyst_inc = ($EFFECTIVE_BALANCE_INCREMENT / $HYSTERESIS_QUOTIENT)
      -- let uint64_down_th = (uint64_hyst_inc * $HYSTERESIS_DOWNWARD_MULTIPLIER)
      -- let uint64_up_th = (uint64_hyst_inc * $HYSTERESIS_UPWARD_MULTIPLIER)
      -- if (balance <= ($UINT64_MAX - uint64_down_th))   ;; [ins:overflow]
      -- if ((balance + uint64_down_th) >= validator.EFFECTIVE_BALANCE)
      -- if (validator.EFFECTIVE_BALANCE <= ($UINT64_MAX - uint64_up_th))   ;; [ins:overflow]
      -- if ((validator.EFFECTIVE_BALANCE + uint64_up_th) >= balance)   ;; [ins:underflow]

;; spec/spec_deneb/11-helpers-rewards-penalties.spectec:82:1-82:82:
def $inact_penalty_one(nat, beaconState, validatorIndex*, validatorIndex*) : gwei =

   ;; spec/spec_deneb/11-helpers-rewards-penalties.spectec:84:1-97:62:
   clause 0(vid, state, vid_matching*{vid_matching <- vid_matching*}, vid_eligible*{vid_eligible <- vid_eligible*}) = penalty
      -- if vid <- vid_eligible*{vid_eligible <- vid_eligible*}
      -- if ~vid <- vid_matching*{vid_matching <- vid_matching*}
      -- if (vid < |state.VALIDATORS|)
      -- let balance_effective = state.VALIDATORS[vid].EFFECTIVE_BALANCE
      -- if (vid < |state.INACTIVITY_SCORES|)   ;; [ins:bounds]
      -- let uint64_score = state.INACTIVITY_SCORES[vid]
      -- let penalty_numerator = (balance_effective * uint64_score)
      -- if (penalty_numerator <= $UINT64_MAX)   ;; [ins:overflow]
      -- let penalty_denominator = ($INACTIVITY_SCORE_BIAS * $INACTIVITY_PENALTY_QUOTIENT_BELLATRIX)
      -- let penalty = (penalty_numerator / penalty_denominator)

   ;; spec/spec_deneb/11-helpers-rewards-penalties.spectec:99:1-101:58:
   clause 1(vid, _beaconState, vid_matching*{vid_matching <- vid_matching*}, vid_eligible*{vid_eligible <- vid_eligible*}) = 0
      -- if (~vid <- vid_eligible*{vid_eligible <- vid_eligible*} \/ vid <- vid_matching*{vid_matching <- vid_matching*})

;; spec/spec_deneb/11-helpers-rewards-penalties.spectec:104:1-104:65:
def $get_inactivity_penalty_deltas(beaconState) : (gwei*, gwei*) =

   ;; spec/spec_deneb/11-helpers-rewards-penalties.spectec:106:1-115:82:
   clause 0(state) = (reward*{reward <- reward*}, penalty*{penalty <- penalty*})
      -- let reward*{reward <- reward*} = $repeat_<gwei>(0, |state.VALIDATORS|)
      -- let vid_eligible*{vid_eligible <- vid_eligible*} = $get_eligible_validator_indices(state)
      -- let epoch_prev = $get_previous_epoch(state)
      -- let vid_matching*{vid_matching <- vid_matching*} = $get_unslashed_participating_indices(state, $TIMELY_TARGET_FLAG_INDEX, epoch_prev)
      -- let vid*{vid <- vid*} = $range(|state.VALIDATORS|)
      -- (let penalty = $inact_penalty_one(vid, state, vid_matching*{vid_matching <- vid_matching*}, vid_eligible*{vid_eligible <- vid_eligible*}))*{penalty <- penalty*, vid <- vid*}

;; spec/spec_deneb/11-helpers-rewards-penalties.spectec:118:1-118:124:
def $flag_reward_one_eligible(validatorIndex, beaconState, validatorIndex*, validatorIndex*, uint64, uint64, uint64) : gwei =

   ;; spec/spec_deneb/11-helpers-rewards-penalties.spectec:120:1-129:85:
   clause 0(vid, state, vid_unslashed*{vid_unslashed <- vid_unslashed*}, vid_eligible*{vid_eligible <- vid_eligible*}, uint64_weight, uint64_up_incs, uint64_active_incs) = reward
      -- if vid <- vid_eligible*{vid_eligible <- vid_eligible*}
      -- if vid <- vid_unslashed*{vid_unslashed <- vid_unslashed*}
      -- if ~$is_in_inactivity_leak(state)
      -- let reward_base = $get_base_reward(state, vid)
      -- let reward_numerator = ((reward_base * uint64_weight) * uint64_up_incs)
      -- if (reward_numerator <= $UINT64_MAX)   ;; [ins:overflow]
      -- let reward = (reward_numerator / (uint64_active_incs * $WEIGHT_DENOMINATOR))

   ;; spec/spec_deneb/11-helpers-rewards-penalties.spectec:131:1-133:60:
   clause 1(vid, _beaconState, vid_unslashed*{vid_unslashed <- vid_unslashed*}, vid_eligible*{vid_eligible <- vid_eligible*}, _uint64, _uint64', _uint64'') = 0
      -- if (~vid <- vid_eligible*{vid_eligible <- vid_eligible*} \/ ~vid <- vid_unslashed*{vid_unslashed <- vid_unslashed*})

   ;; spec/spec_deneb/11-helpers-rewards-penalties.spectec:136:1-138:38:
   clause 2(_validatorIndex, state, _validatorIndex'*{_validatorIndex' <- _validatorIndex'*}, _validatorIndex''*{_validatorIndex'' <- _validatorIndex''*}, _uint64, _uint64', _uint64'') = 0
      -- if $is_in_inactivity_leak(state)

;; spec/spec_deneb/11-helpers-rewards-penalties.spectec:141:1-141:114:
def $flag_penalty_one_eligible(validatorIndex, beaconState, validatorIndex*, validatorIndex*, uint64, nat) : gwei =

   ;; spec/spec_deneb/11-helpers-rewards-penalties.spectec:143:1-149:75:
   clause 0(vid, state, vid_unslashed*{vid_unslashed <- vid_unslashed*}, vid_eligible*{vid_eligible <- vid_eligible*}, uint64_weight, flag_index) = penalty
      -- if vid <- vid_eligible*{vid_eligible <- vid_eligible*}
      -- if ~vid <- vid_unslashed*{vid_unslashed <- vid_unslashed*}
      -- if (flag_index =/= $TIMELY_HEAD_FLAG_INDEX)
      -- let reward_base = $get_base_reward(state, vid)
      -- let penalty = ((reward_base * uint64_weight) / $WEIGHT_DENOMINATOR)

   ;; spec/spec_deneb/11-helpers-rewards-penalties.spectec:151:1-155:47:
   clause 1(vid, _beaconState, vid_unslashed*{vid_unslashed <- vid_unslashed*}, vid_eligible*{vid_eligible <- vid_eligible*}, _uint64, flag_index) = 0
      -- if ((~vid <- vid_eligible*{vid_eligible <- vid_eligible*} \/ vid <- vid_unslashed*{vid_unslashed <- vid_unslashed*}) \/ (flag_index = $TIMELY_HEAD_FLAG_INDEX))

;; spec/spec_deneb/11-helpers-rewards-penalties.spectec:158:1-158:62:
def $get_flag_index_deltas(beaconState, nat) : (gwei*, gwei*) =

   ;; spec/spec_deneb/11-helpers-rewards-penalties.spectec:160:1-190:22:
   clause 0(state, flag_index) = (reward*{reward <- reward*}, penalty*{penalty <- penalty*})
      -- let vid_eligible*{vid_eligible <- vid_eligible*} = $to_set_<validatorIndex>($get_eligible_validator_indices(state))
      -- let epoch_prev = $get_previous_epoch(state)
      -- let vid_unslashed*{vid_unslashed <- vid_unslashed*} = $get_unslashed_participating_indices(state, flag_index, epoch_prev)
      -- let uint64_weight = $PARTICIPATION_FLAG_WEIGHTS[flag_index]
      -- let balance_unslashed_participating = $get_total_balance(state, vid_unslashed*{vid_unslashed <- vid_unslashed*})
      -- let uint64_unslashed_increments = (balance_unslashed_participating / $EFFECTIVE_BALANCE_INCREMENT)
      -- let uint64_active_increments = ($get_total_active_balance(state) / $EFFECTIVE_BALANCE_INCREMENT)
      -- let vid*{vid <- vid*} = $range(|state.VALIDATORS|)
      -- (let reward = $flag_reward_one_eligible(vid, state, vid_unslashed*{vid_unslashed <- vid_unslashed*}, vid_eligible*{vid_eligible <- vid_eligible*}, uint64_weight, uint64_unslashed_increments, uint64_active_increments))*{reward <- reward*, vid <- vid*}
      -- (let penalty = $flag_penalty_one_eligible(vid, state, vid_unslashed*{vid_unslashed <- vid_unslashed*}, vid_eligible*{vid_eligible <- vid_eligible*}, uint64_weight, flag_index))*{penalty <- penalty*, vid <- vid*}

;; spec/spec_deneb/12-helpers-process-epoch.spectec:5:1-7:26:
relation ApplyRewardAndPenalty: beaconState .BALANCES[ validatorIndex ]+ gwei - gwei ~> beaconState

   ;; spec/spec_deneb/12-helpers-process-epoch.spectec:9:1-12:74:
   rule : state .BALANCES[ vid ]+ reward - penalty ~> state_out
      -- rel IncreaseBalance: state .BALANCES[ vid ]+ reward ~> state_r
      -- rel DecreaseBalance: state_r .BALANCES[ vid ]- penalty ~> state_out

;; spec/spec_deneb/12-helpers-process-epoch.spectec:17:1-19:26:
relation ApplyRewardsAndPenalties: beaconState .BALANCES[ validatorIndex* ]+ gwei* - gwei* ~> beaconState

   ;; spec/spec_deneb/12-helpers-process-epoch.spectec:21:1-22:51:
   rule nil: state .BALANCES[ validatorIndex*{validatorIndex <- validatorIndex*} ]+ gwei*{gwei <- gwei*} - gwei'*{gwei' <- gwei'*} ~> state
      -- if validatorIndex*{validatorIndex <- validatorIndex*} matches []
      -- if gwei*{gwei <- gwei*} matches []
      -- if gwei'*{gwei' <- gwei'*} matches []

   ;; spec/spec_deneb/12-helpers-process-epoch.spectec:24:1-27:102:
   rule cons: state .BALANCES[ validatorIndex*{validatorIndex <- validatorIndex*} ]+ gwei*{gwei <- gwei*} - gwei'*{gwei' <- gwei'*} ~> state_out
      -- if validatorIndex*{validatorIndex <- validatorIndex*} matches _ :: _
      -- let vid_h :: vid_t*{vid_t <- vid_t*} = validatorIndex*{validatorIndex <- validatorIndex*}
      -- if gwei*{gwei <- gwei*} matches _ :: _
      -- let reward_h :: reward_t*{reward_t <- reward_t*} = gwei*{gwei <- gwei*}
      -- if gwei'*{gwei' <- gwei'*} matches _ :: _
      -- let penalty_h :: penalty_t*{penalty_t <- penalty_t*} = gwei'*{gwei' <- gwei'*}
      -- rel ApplyRewardAndPenalty: state .BALANCES[ vid_h ]+ reward_h - penalty_h ~> state_h
      -- rel ApplyRewardsAndPenalties: state_h .BALANCES[ vid_t*{vid_t <- vid_t*} ]+ reward_t*{reward_t <- reward_t*} - penalty_t*{penalty_t <- penalty_t*} ~> state_out

;; spec/spec_deneb/12-helpers-process-epoch.spectec:32:1-34:26:
relation ApplyRewardsAndPenalties_over_deltas: beaconState .BALANCES[ validatorIndex* ]+ gwei** - gwei** ~>* beaconState

   ;; spec/spec_deneb/12-helpers-process-epoch.spectec:36:1-37:50:
   rule nil: state .BALANCES[ _validatorIndex*{_validatorIndex <- _validatorIndex*} ]+ gwei*{gwei <- gwei*}*{gwei* <- gwei**} - gwei'*{gwei' <- gwei'*}*{gwei'* <- gwei'**} ~>* state
      -- if gwei*{gwei <- gwei*}*{gwei* <- gwei**} matches []
      -- if gwei'*{gwei' <- gwei'*}*{gwei'* <- gwei'**} matches []

   ;; spec/spec_deneb/12-helpers-process-epoch.spectec:39:1-42:115:
   rule cons: state .BALANCES[ vid*{vid <- vid*} ]+ gwei*{gwei <- gwei*}*{gwei* <- gwei**} - gwei'*{gwei' <- gwei'*}*{gwei'* <- gwei'**} ~>* state_out
      -- if gwei*{gwei <- gwei*}*{gwei* <- gwei**} matches _ :: _
      -- let reward*{reward <- reward*} :: reward_t*{reward_t <- reward_t*}*{reward_t* <- reward_t**} = gwei*{gwei <- gwei*}*{gwei* <- gwei**}
      -- if gwei'*{gwei' <- gwei'*}*{gwei'* <- gwei'**} matches _ :: _
      -- let penalty*{penalty <- penalty*} :: penalty_t*{penalty_t <- penalty_t*}*{penalty_t* <- penalty_t**} = gwei'*{gwei' <- gwei'*}*{gwei'* <- gwei'**}
      -- rel ApplyRewardsAndPenalties: state .BALANCES[ vid*{vid <- vid*} ]+ reward*{reward <- reward*} - penalty*{penalty <- penalty*} ~> state_t
      -- rel ApplyRewardsAndPenalties_over_deltas: state_t .BALANCES[ vid*{vid <- vid*} ]+ reward_t*{reward_t <- reward_t*}*{reward_t* <- reward_t**} - penalty_t*{penalty_t <- penalty_t*}*{penalty_t* <- penalty_t**} ~>* state_out

;; spec/spec_deneb/12-helpers-process-epoch.spectec:48:1-50:20:
relation ApplyInactivity: beaconState .INACTIVITY_SCORES[ validatorIndex ]~> beaconState

   ;; spec/spec_deneb/12-helpers-process-epoch.spectec:52:1-63:43:
   rule unslashed_participating_no_leak: state .INACTIVITY_SCORES[ vid ]~> state[INACTIVITY_SCORES[vid] = $max_uint64(((state.INACTIVITY_SCORES[vid] - 1) - $INACTIVITY_SCORE_RECOVERY_RATE), 0)]
      -- if vid <- $get_unslashed_participating_indices(state, $TIMELY_TARGET_FLAG_INDEX, $get_previous_epoch(state))
      -- if ~$is_in_inactivity_leak(state)
      -- if (vid < |state.INACTIVITY_SCORES|)   ;; [ins:bounds]

   ;; spec/spec_deneb/12-helpers-process-epoch.spectec:65:1-76:43:
   rule unslashed_participating_leak: state .INACTIVITY_SCORES[ vid ]~> state[INACTIVITY_SCORES[vid] = $max_uint64((state.INACTIVITY_SCORES[vid] - 1), 0)]
      -- if vid <- $get_unslashed_participating_indices(state, $TIMELY_TARGET_FLAG_INDEX, $get_previous_epoch(state))
      -- if $is_in_inactivity_leak(state)
      -- if (vid < |state.INACTIVITY_SCORES|)   ;; [ins:bounds]

   ;; spec/spec_deneb/12-helpers-process-epoch.spectec:78:1-92:80:
   rule inactive_no_leak: state .INACTIVITY_SCORES[ vid ]~> state[INACTIVITY_SCORES[vid] = $max_uint64((state.INACTIVITY_SCORES[vid] + n_leak_penalty), 0)]
      -- if ~vid <- $get_unslashed_participating_indices(state, $TIMELY_TARGET_FLAG_INDEX, $get_previous_epoch(state))
      -- if ~$is_in_inactivity_leak(state)
      -- let n_leak_penalty = ($INACTIVITY_SCORE_BIAS - $INACTIVITY_SCORE_RECOVERY_RATE)
      -- if (vid < |state.INACTIVITY_SCORES|)   ;; [ins:bounds]
      -- if (state.INACTIVITY_SCORES[vid] <= ($UINT64_MAX - $INACTIVITY_SCORE_BIAS))   ;; [ins:overflow]

   ;; spec/spec_deneb/12-helpers-process-epoch.spectec:94:1-107:80:
   rule inactive_leak: state .INACTIVITY_SCORES[ vid ]~> state[INACTIVITY_SCORES[vid] = $max_uint64((state.INACTIVITY_SCORES[vid] + $INACTIVITY_SCORE_BIAS), 0)]
      -- if ~vid <- $get_unslashed_participating_indices(state, $TIMELY_TARGET_FLAG_INDEX, $get_previous_epoch(state))
      -- if $is_in_inactivity_leak(state)
      -- if (vid < |state.INACTIVITY_SCORES|)   ;; [ins:bounds]
      -- if (state.INACTIVITY_SCORES[vid] <= ($UINT64_MAX - $INACTIVITY_SCORE_BIAS))   ;; [ins:overflow]

;; spec/spec_deneb/12-helpers-process-epoch.spectec:110:1-112:20:
relation ApplyInactivity_over_vids: beaconState .INACTIVITY_SCORES[ validatorIndex* ]~>* beaconState

   ;; spec/spec_deneb/12-helpers-process-epoch.spectec:114:1-115:47:
   rule nil: state .INACTIVITY_SCORES[ validatorIndex*{validatorIndex <- validatorIndex*} ]~>* state
      -- if validatorIndex*{validatorIndex <- validatorIndex*} matches []

   ;; spec/spec_deneb/12-helpers-process-epoch.spectec:117:1-120:90:
   rule cons: state .INACTIVITY_SCORES[ validatorIndex*{validatorIndex <- validatorIndex*} ]~>* state_updated
      -- if validatorIndex*{validatorIndex <- validatorIndex*} matches _ :: _
      -- let vid_h :: vid_t*{vid_t <- vid_t*} = validatorIndex*{validatorIndex <- validatorIndex*}
      -- rel ApplyInactivity: state .INACTIVITY_SCORES[ vid_h ]~> state_1
      -- rel ApplyInactivity_over_vids: state_1 .INACTIVITY_SCORES[ vid_t*{vid_t <- vid_t*} ]~>* state_updated

;; spec/spec_deneb/12-helpers-process-epoch.spectec:126:1-126:65:
def $is_due_slashing_en(enumerated_<validator>, epoch) : boolean =

   ;; spec/spec_deneb/12-helpers-process-epoch.spectec:128:1-130:87:
   clause 0((_nat, validator), epoch) = true
      -- if (validator.SLASHED = true)
      -- if ((epoch + ($EPOCHS_PER_SLASHINGS_VECTOR / 2)) = validator.WITHDRAWABLE_EPOCH)

   ;; spec/spec_deneb/12-helpers-process-epoch.spectec:132:1-133:15:
   clause 1((_nat, _validator), _epoch) = false
      -- otherwise

;; spec/spec_deneb/12-helpers-process-epoch.spectec:136:1-138:23:
relation DecreaseBalances: beaconState .BALANCES[ validatorIndex* ]- gwei* ~> beaconState

   ;; spec/spec_deneb/12-helpers-process-epoch.spectec:140:1-141:44:
   rule nil: state .BALANCES[ validatorIndex*{validatorIndex <- validatorIndex*} ]- gwei*{gwei <- gwei*} ~> state
      -- if validatorIndex*{validatorIndex <- validatorIndex*} matches []
      -- if gwei*{gwei <- gwei*} matches []

   ;; spec/spec_deneb/12-helpers-process-epoch.spectec:143:1-146:79:
   rule cons: state .BALANCES[ validatorIndex*{validatorIndex <- validatorIndex*} ]- gwei*{gwei <- gwei*} ~> state_t
      -- if validatorIndex*{validatorIndex <- validatorIndex*} matches _ :: _
      -- let vid_h :: vid_t*{vid_t <- vid_t*} = validatorIndex*{validatorIndex <- validatorIndex*}
      -- if gwei*{gwei <- gwei*} matches _ :: _
      -- let penalty_h :: penalty_t*{penalty_t <- penalty_t*} = gwei*{gwei <- gwei*}
      -- rel DecreaseBalance: state .BALANCES[ vid_h ]- penalty_h ~> state_h
      -- rel DecreaseBalances: state_h .BALANCES[ vid_t*{vid_t <- vid_t*} ]- penalty_t*{penalty_t <- penalty_t*} ~> state_t

;; spec/spec_deneb/12-helpers-process-epoch.spectec:157:1-163:26:
relation WeighJustificationAndFinalization: beaconState TOTAL gwei PREV gwei CUR gwei ~> beaconState

   ;; spec/spec_deneb/12-helpers-process-epoch.spectec:167:1-200:73:
   rule justify_neither_finalize_prev: state TOTAL balance_total_active PREV balance_prev_epoch_target CUR balance_current_epoch_target ~> state[PREVIOUS_JUSTIFIED_CHECKPOINT = checkpoint_cur][FINALIZED_CHECKPOINT = checkpoint_prev][JUSTIFICATION_BITS = bit*{bit <- bit*}]
      -- if (balance_prev_epoch_target <= ($UINT64_MAX / 3))   ;; [ins:overflow]
      -- if (balance_total_active <= ($UINT64_MAX / 2))   ;; [ins:overflow]
      -- if (balance_current_epoch_target <= ($UINT64_MAX / 3))   ;; [ins:overflow]
      -- if ~((balance_prev_epoch_target * 3) >= (balance_total_active * 2))
      -- if ~((balance_current_epoch_target * 3) >= (balance_total_active * 2))
      -- let bit*{bit <- bit*} = [false, state.JUSTIFICATION_BITS[0], state.JUSTIFICATION_BITS[1], state.JUSTIFICATION_BITS[2]]
      -- let checkpoint_prev = state.PREVIOUS_JUSTIFIED_CHECKPOINT
      -- let checkpoint_cur = state.CURRENT_JUSTIFIED_CHECKPOINT
      -- let epoch_cur = $get_current_epoch(state)
      -- if (~((bit*{bit <- bit*}[1] /\ bit*{bit <- bit*}[2]) /\ bit*{bit <- bit*}[3]) \/ (checkpoint_prev.EPOCH <= ($UINT64_MAX - 3)))   ;; [ins:overflow]
      -- if (~(bit*{bit <- bit*}[1] /\ bit*{bit <- bit*}[2]) \/ (checkpoint_prev.EPOCH <= ($UINT64_MAX - 2)))   ;; [ins:overflow]
      -- if (~((bit*{bit <- bit*}[0] /\ bit*{bit <- bit*}[1]) /\ bit*{bit <- bit*}[2]) \/ (checkpoint_cur.EPOCH <= ($UINT64_MAX - 2)))   ;; [ins:overflow]
      -- if (~(bit*{bit <- bit*}[0] /\ bit*{bit <- bit*}[1]) \/ (checkpoint_cur.EPOCH <= ($UINT64_MAX - 1)))   ;; [ins:overflow]
      -- if ((((bit*{bit <- bit*}[1] /\ bit*{bit <- bit*}[2]) /\ bit*{bit <- bit*}[3]) /\ (epoch_cur = (checkpoint_prev.EPOCH + 3))) \/ ((bit*{bit <- bit*}[1] /\ bit*{bit <- bit*}[2]) /\ (epoch_cur = (checkpoint_prev.EPOCH + 2))))

   ;; spec/spec_deneb/12-helpers-process-epoch.spectec:202:1-234:74:
   rule justify_neither_finalize_neither: state TOTAL balance_total_active PREV balance_prev_epoch_target CUR balance_current_epoch_target ~> state[PREVIOUS_JUSTIFIED_CHECKPOINT = checkpoint_cur][JUSTIFICATION_BITS = bit*{bit <- bit*}]
      -- if (balance_prev_epoch_target <= ($UINT64_MAX / 3))   ;; [ins:overflow]
      -- if (balance_total_active <= ($UINT64_MAX / 2))   ;; [ins:overflow]
      -- if (balance_current_epoch_target <= ($UINT64_MAX / 3))   ;; [ins:overflow]
      -- if ~((balance_prev_epoch_target * 3) >= (balance_total_active * 2))
      -- if ~((balance_current_epoch_target * 3) >= (balance_total_active * 2))
      -- let bit*{bit <- bit*} = [false, state.JUSTIFICATION_BITS[0], state.JUSTIFICATION_BITS[1], state.JUSTIFICATION_BITS[2]]
      -- let checkpoint_prev = state.PREVIOUS_JUSTIFIED_CHECKPOINT
      -- let checkpoint_cur = state.CURRENT_JUSTIFIED_CHECKPOINT
      -- let epoch_cur = $get_current_epoch(state)
      -- if (~((bit*{bit <- bit*}[1] /\ bit*{bit <- bit*}[2]) /\ bit*{bit <- bit*}[3]) \/ (checkpoint_prev.EPOCH <= ($UINT64_MAX - 3)))   ;; [ins:overflow]
      -- if (~(bit*{bit <- bit*}[1] /\ bit*{bit <- bit*}[2]) \/ (checkpoint_prev.EPOCH <= ($UINT64_MAX - 2)))   ;; [ins:overflow]
      -- if (~((bit*{bit <- bit*}[0] /\ bit*{bit <- bit*}[1]) /\ bit*{bit <- bit*}[2]) \/ (checkpoint_cur.EPOCH <= ($UINT64_MAX - 2)))   ;; [ins:overflow]
      -- if (~(bit*{bit <- bit*}[0] /\ bit*{bit <- bit*}[1]) \/ (checkpoint_cur.EPOCH <= ($UINT64_MAX - 1)))   ;; [ins:overflow]
      -- if (~(((bit*{bit <- bit*}[1] /\ bit*{bit <- bit*}[2]) /\ bit*{bit <- bit*}[3]) /\ (epoch_cur = (checkpoint_prev.EPOCH + 3))) /\ ~((bit*{bit <- bit*}[1] /\ bit*{bit <- bit*}[2]) /\ (epoch_cur = (checkpoint_prev.EPOCH + 2))))

   ;; spec/spec_deneb/12-helpers-process-epoch.spectec:236:1-273:73:
   rule justify_prev_finalize_prev: state TOTAL balance_total_active PREV balance_prev_epoch_target CUR balance_current_epoch_target ~> state[PREVIOUS_JUSTIFIED_CHECKPOINT = checkpoint_cur][CURRENT_JUSTIFIED_CHECKPOINT = {EPOCH epoch_prev, ROOT $get_block_root(state, epoch_prev)}][FINALIZED_CHECKPOINT = checkpoint_prev][JUSTIFICATION_BITS = bit*{bit <- bit*}]
      -- if (balance_prev_epoch_target <= ($UINT64_MAX / 3))   ;; [ins:overflow]
      -- if (balance_total_active <= ($UINT64_MAX / 2))   ;; [ins:overflow]
      -- if (balance_current_epoch_target <= ($UINT64_MAX / 3))   ;; [ins:overflow]
      -- if ((balance_prev_epoch_target * 3) >= (balance_total_active * 2))
      -- if ~((balance_current_epoch_target * 3) >= (balance_total_active * 2))
      -- let bit*{bit <- bit*} = [false, true, state.JUSTIFICATION_BITS[1], state.JUSTIFICATION_BITS[2]]
      -- let checkpoint_prev = state.PREVIOUS_JUSTIFIED_CHECKPOINT
      -- let checkpoint_cur = state.CURRENT_JUSTIFIED_CHECKPOINT
      -- let epoch_prev = $get_previous_epoch(state)
      -- let epoch_cur = $get_current_epoch(state)
      -- if (~((bit*{bit <- bit*}[1] /\ bit*{bit <- bit*}[2]) /\ bit*{bit <- bit*}[3]) \/ (checkpoint_prev.EPOCH <= ($UINT64_MAX - 3)))   ;; [ins:overflow]
      -- if (~(bit*{bit <- bit*}[1] /\ bit*{bit <- bit*}[2]) \/ (checkpoint_prev.EPOCH <= ($UINT64_MAX - 2)))   ;; [ins:overflow]
      -- if (~((bit*{bit <- bit*}[0] /\ bit*{bit <- bit*}[1]) /\ bit*{bit <- bit*}[2]) \/ (checkpoint_cur.EPOCH <= ($UINT64_MAX - 2)))   ;; [ins:overflow]
      -- if (~(bit*{bit <- bit*}[0] /\ bit*{bit <- bit*}[1]) \/ (checkpoint_cur.EPOCH <= ($UINT64_MAX - 1)))   ;; [ins:overflow]
      -- if ((((bit*{bit <- bit*}[1] /\ bit*{bit <- bit*}[2]) /\ bit*{bit <- bit*}[3]) /\ (epoch_cur = (checkpoint_prev.EPOCH + 3))) \/ ((bit*{bit <- bit*}[1] /\ bit*{bit <- bit*}[2]) /\ (epoch_cur = (checkpoint_prev.EPOCH + 2))))

   ;; spec/spec_deneb/12-helpers-process-epoch.spectec:275:1-311:74:
   rule justify_prev_finalize_neither: state TOTAL balance_total_active PREV balance_prev_epoch_target CUR balance_current_epoch_target ~> state[PREVIOUS_JUSTIFIED_CHECKPOINT = checkpoint_cur][CURRENT_JUSTIFIED_CHECKPOINT = {EPOCH epoch_prev, ROOT $get_block_root(state, epoch_prev)}][JUSTIFICATION_BITS = bit*{bit <- bit*}]
      -- if (balance_prev_epoch_target <= ($UINT64_MAX / 3))   ;; [ins:overflow]
      -- if (balance_total_active <= ($UINT64_MAX / 2))   ;; [ins:overflow]
      -- if (balance_current_epoch_target <= ($UINT64_MAX / 3))   ;; [ins:overflow]
      -- if ((balance_prev_epoch_target * 3) >= (balance_total_active * 2))
      -- if ~((balance_current_epoch_target * 3) >= (balance_total_active * 2))
      -- let bit*{bit <- bit*} = [false, true, state.JUSTIFICATION_BITS[1], state.JUSTIFICATION_BITS[2]]
      -- let checkpoint_prev = state.PREVIOUS_JUSTIFIED_CHECKPOINT
      -- let checkpoint_cur = state.CURRENT_JUSTIFIED_CHECKPOINT
      -- let epoch_prev = $get_previous_epoch(state)
      -- let epoch_cur = $get_current_epoch(state)
      -- if (~((bit*{bit <- bit*}[1] /\ bit*{bit <- bit*}[2]) /\ bit*{bit <- bit*}[3]) \/ (checkpoint_prev.EPOCH <= ($UINT64_MAX - 3)))   ;; [ins:overflow]
      -- if (~(bit*{bit <- bit*}[1] /\ bit*{bit <- bit*}[2]) \/ (checkpoint_prev.EPOCH <= ($UINT64_MAX - 2)))   ;; [ins:overflow]
      -- if (~((bit*{bit <- bit*}[0] /\ bit*{bit <- bit*}[1]) /\ bit*{bit <- bit*}[2]) \/ (checkpoint_cur.EPOCH <= ($UINT64_MAX - 2)))   ;; [ins:overflow]
      -- if (~(bit*{bit <- bit*}[0] /\ bit*{bit <- bit*}[1]) \/ (checkpoint_cur.EPOCH <= ($UINT64_MAX - 1)))   ;; [ins:overflow]
      -- if (~(((bit*{bit <- bit*}[1] /\ bit*{bit <- bit*}[2]) /\ bit*{bit <- bit*}[3]) /\ (epoch_cur = (checkpoint_prev.EPOCH + 3))) /\ ~((bit*{bit <- bit*}[1] /\ bit*{bit <- bit*}[2]) /\ (epoch_cur = (checkpoint_prev.EPOCH + 2))))

   ;; spec/spec_deneb/12-helpers-process-epoch.spectec:313:1-349:72:
   rule justify_cur_finalize_cur: state TOTAL balance_total_active PREV balance_prev_epoch_target CUR balance_current_epoch_target ~> state[PREVIOUS_JUSTIFIED_CHECKPOINT = checkpoint_cur][CURRENT_JUSTIFIED_CHECKPOINT = {EPOCH epoch_cur, ROOT $get_block_root(state, epoch_cur)}][FINALIZED_CHECKPOINT = checkpoint_cur][JUSTIFICATION_BITS = bit*{bit <- bit*}]
      -- if (balance_prev_epoch_target <= ($UINT64_MAX / 3))   ;; [ins:overflow]
      -- if (balance_total_active <= ($UINT64_MAX / 2))   ;; [ins:overflow]
      -- if (balance_current_epoch_target <= ($UINT64_MAX / 3))   ;; [ins:overflow]
      -- if ((balance_current_epoch_target * 3) >= (balance_total_active * 2))
      -- let bit*{bit <- bit*} = [true, (state.JUSTIFICATION_BITS[0] \/ ((balance_prev_epoch_target * 3) >= (balance_total_active * 2))), state.JUSTIFICATION_BITS[1], state.JUSTIFICATION_BITS[2]]
      -- let checkpoint_prev = state.PREVIOUS_JUSTIFIED_CHECKPOINT
      -- let checkpoint_cur = state.CURRENT_JUSTIFIED_CHECKPOINT
      -- let epoch_cur = $get_current_epoch(state)
      -- if (~((bit*{bit <- bit*}[1] /\ bit*{bit <- bit*}[2]) /\ bit*{bit <- bit*}[3]) \/ (checkpoint_prev.EPOCH <= ($UINT64_MAX - 3)))   ;; [ins:overflow]
      -- if (~(bit*{bit <- bit*}[1] /\ bit*{bit <- bit*}[2]) \/ (checkpoint_prev.EPOCH <= ($UINT64_MAX - 2)))   ;; [ins:overflow]
      -- if (~((bit*{bit <- bit*}[0] /\ bit*{bit <- bit*}[1]) /\ bit*{bit <- bit*}[2]) \/ (checkpoint_cur.EPOCH <= ($UINT64_MAX - 2)))   ;; [ins:overflow]
      -- if (~(bit*{bit <- bit*}[0] /\ bit*{bit <- bit*}[1]) \/ (checkpoint_cur.EPOCH <= ($UINT64_MAX - 1)))   ;; [ins:overflow]
      -- if ((((bit*{bit <- bit*}[0] /\ bit*{bit <- bit*}[1]) /\ bit*{bit <- bit*}[2]) /\ (epoch_cur = (checkpoint_cur.EPOCH + 2))) \/ ((bit*{bit <- bit*}[0] /\ bit*{bit <- bit*}[1]) /\ (epoch_cur = (checkpoint_cur.EPOCH + 1))))

   ;; spec/spec_deneb/12-helpers-process-epoch.spectec:351:1-389:75:
   rule justify_cur_finalize_prev: state TOTAL balance_total_active PREV balance_prev_epoch_target CUR balance_current_epoch_target ~> state[PREVIOUS_JUSTIFIED_CHECKPOINT = checkpoint_cur][CURRENT_JUSTIFIED_CHECKPOINT = {EPOCH epoch_cur, ROOT $get_block_root(state, epoch_cur)}][FINALIZED_CHECKPOINT = checkpoint_prev][JUSTIFICATION_BITS = bit*{bit <- bit*}]
      -- if (balance_prev_epoch_target <= ($UINT64_MAX / 3))   ;; [ins:overflow]
      -- if (balance_total_active <= ($UINT64_MAX / 2))   ;; [ins:overflow]
      -- if (balance_current_epoch_target <= ($UINT64_MAX / 3))   ;; [ins:overflow]
      -- if ((balance_current_epoch_target * 3) >= (balance_total_active * 2))
      -- let bit*{bit <- bit*} = [true, (state.JUSTIFICATION_BITS[0] \/ ((balance_prev_epoch_target * 3) >= (balance_total_active * 2))), state.JUSTIFICATION_BITS[1], state.JUSTIFICATION_BITS[2]]
      -- let checkpoint_prev = state.PREVIOUS_JUSTIFIED_CHECKPOINT
      -- let checkpoint_cur = state.CURRENT_JUSTIFIED_CHECKPOINT
      -- let epoch_cur = $get_current_epoch(state)
      -- if (~((bit*{bit <- bit*}[1] /\ bit*{bit <- bit*}[2]) /\ bit*{bit <- bit*}[3]) \/ (checkpoint_prev.EPOCH <= ($UINT64_MAX - 3)))   ;; [ins:overflow]
      -- if (~(bit*{bit <- bit*}[1] /\ bit*{bit <- bit*}[2]) \/ (checkpoint_prev.EPOCH <= ($UINT64_MAX - 2)))   ;; [ins:overflow]
      -- if (~((bit*{bit <- bit*}[0] /\ bit*{bit <- bit*}[1]) /\ bit*{bit <- bit*}[2]) \/ (checkpoint_cur.EPOCH <= ($UINT64_MAX - 2)))   ;; [ins:overflow]
      -- if (~(bit*{bit <- bit*}[0] /\ bit*{bit <- bit*}[1]) \/ (checkpoint_cur.EPOCH <= ($UINT64_MAX - 1)))   ;; [ins:overflow]
      -- if ((~(((bit*{bit <- bit*}[0] /\ bit*{bit <- bit*}[1]) /\ bit*{bit <- bit*}[2]) /\ (epoch_cur = (checkpoint_cur.EPOCH + 2))) /\ ~((bit*{bit <- bit*}[0] /\ bit*{bit <- bit*}[1]) /\ (epoch_cur = (checkpoint_cur.EPOCH + 1)))) /\ ((((bit*{bit <- bit*}[1] /\ bit*{bit <- bit*}[2]) /\ bit*{bit <- bit*}[3]) /\ (epoch_cur = (checkpoint_prev.EPOCH + 3))) \/ ((bit*{bit <- bit*}[1] /\ bit*{bit <- bit*}[2]) /\ (epoch_cur = (checkpoint_prev.EPOCH + 2)))))

   ;; spec/spec_deneb/12-helpers-process-epoch.spectec:391:1-428:74:
   rule justify_cur_finalize_neither: state TOTAL balance_total_active PREV balance_prev_epoch_target CUR balance_current_epoch_target ~> state[PREVIOUS_JUSTIFIED_CHECKPOINT = checkpoint_cur][CURRENT_JUSTIFIED_CHECKPOINT = {EPOCH epoch_cur, ROOT $get_block_root(state, epoch_cur)}][JUSTIFICATION_BITS = bit*{bit <- bit*}]
      -- if (balance_prev_epoch_target <= ($UINT64_MAX / 3))   ;; [ins:overflow]
      -- if (balance_total_active <= ($UINT64_MAX / 2))   ;; [ins:overflow]
      -- if (balance_current_epoch_target <= ($UINT64_MAX / 3))   ;; [ins:overflow]
      -- if ((balance_current_epoch_target * 3) >= (balance_total_active * 2))
      -- let bit*{bit <- bit*} = [true, (state.JUSTIFICATION_BITS[0] \/ ((balance_prev_epoch_target * 3) >= (balance_total_active * 2))), state.JUSTIFICATION_BITS[1], state.JUSTIFICATION_BITS[2]]
      -- let checkpoint_prev = state.PREVIOUS_JUSTIFIED_CHECKPOINT
      -- let checkpoint_cur = state.CURRENT_JUSTIFIED_CHECKPOINT
      -- let epoch_cur = $get_current_epoch(state)
      -- if (~((bit*{bit <- bit*}[1] /\ bit*{bit <- bit*}[2]) /\ bit*{bit <- bit*}[3]) \/ (checkpoint_prev.EPOCH <= ($UINT64_MAX - 3)))   ;; [ins:overflow]
      -- if (~(bit*{bit <- bit*}[1] /\ bit*{bit <- bit*}[2]) \/ (checkpoint_prev.EPOCH <= ($UINT64_MAX - 2)))   ;; [ins:overflow]
      -- if (~((bit*{bit <- bit*}[0] /\ bit*{bit <- bit*}[1]) /\ bit*{bit <- bit*}[2]) \/ (checkpoint_cur.EPOCH <= ($UINT64_MAX - 2)))   ;; [ins:overflow]
      -- if (~(bit*{bit <- bit*}[0] /\ bit*{bit <- bit*}[1]) \/ (checkpoint_cur.EPOCH <= ($UINT64_MAX - 1)))   ;; [ins:overflow]
      -- if (((~(((bit*{bit <- bit*}[0] /\ bit*{bit <- bit*}[1]) /\ bit*{bit <- bit*}[2]) /\ (epoch_cur = (checkpoint_cur.EPOCH + 2))) /\ ~((bit*{bit <- bit*}[0] /\ bit*{bit <- bit*}[1]) /\ (epoch_cur = (checkpoint_cur.EPOCH + 1)))) /\ ~(((bit*{bit <- bit*}[1] /\ bit*{bit <- bit*}[2]) /\ bit*{bit <- bit*}[3]) /\ (epoch_cur = (checkpoint_prev.EPOCH + 3)))) /\ ~((bit*{bit <- bit*}[1] /\ bit*{bit <- bit*}[2]) /\ (epoch_cur = (checkpoint_prev.EPOCH + 2))))

;; spec/spec_deneb/12-helpers-process-epoch.spectec:432:1-434:20:
relation ProcessEligibilityAndEjection: beaconState .VALIDATORS[ validatorIndex ]~> beaconState

   ;; spec/spec_deneb/12-helpers-process-epoch.spectec:436:1-446:48:
   rule eligible_and_eject: state .VALIDATORS[ vid ]~> state_updated
      -- let validator = state.VALIDATORS[vid]
      -- let epoch_cur = $get_current_epoch(state)
      -- if $is_eligible_for_activation_queue(validator)
      -- if ($is_active_validator(validator, epoch_cur) /\ (validator.EFFECTIVE_BALANCE <= $EJECTION_BALANCE))
      -- rel InitiateValidatorExit: state[VALIDATORS[vid].ACTIVATION_ELIGIBILITY_EPOCH = (epoch_cur + 1)] .VALIDATORS[ vid ]~> state_updated

   ;; spec/spec_deneb/12-helpers-process-epoch.spectec:448:1-456:64:
   rule eligible: state .VALIDATORS[ vid ]~> state[VALIDATORS[vid].ACTIVATION_ELIGIBILITY_EPOCH = (epoch_cur + 1)]
      -- let validator = state.VALIDATORS[vid]
      -- let epoch_cur = $get_current_epoch(state)
      -- if $is_eligible_for_activation_queue(validator)
      -- if ~($is_active_validator(validator, epoch_cur) /\ (validator.EFFECTIVE_BALANCE <= $EJECTION_BALANCE))

   ;; spec/spec_deneb/12-helpers-process-epoch.spectec:458:1-466:52:
   rule eject: state .VALIDATORS[ vid ]~> state_updated
      -- let validator = state.VALIDATORS[vid]
      -- let epoch_cur = $get_current_epoch(state)
      -- if ~$is_eligible_for_activation_queue(validator)
      -- if ($is_active_validator(validator, epoch_cur) /\ (validator.EFFECTIVE_BALANCE <= $EJECTION_BALANCE))
      -- rel InitiateValidatorExit: state .VALIDATORS[ vid ]~> state_updated

   ;; spec/spec_deneb/12-helpers-process-epoch.spectec:468:1-474:64:
   rule skip: state .VALIDATORS[ vid ]~> state
      -- let validator = state.VALIDATORS[vid]
      -- let epoch_cur = $get_current_epoch(state)
      -- if ~$is_eligible_for_activation_queue(validator)
      -- if ~($is_active_validator(validator, epoch_cur) /\ (validator.EFFECTIVE_BALANCE <= $EJECTION_BALANCE))

;; spec/spec_deneb/12-helpers-process-epoch.spectec:476:1-478:20:
relation ProcessEligibilityAndEjection_over_vids: beaconState .VALIDATORS[ validatorIndex* ]~> beaconState

   ;; spec/spec_deneb/12-helpers-process-epoch.spectec:480:1-481:39:
   rule nil: state .VALIDATORS[ validatorIndex*{validatorIndex <- validatorIndex*} ]~> state
      -- if validatorIndex*{validatorIndex <- validatorIndex*} matches []

   ;; spec/spec_deneb/12-helpers-process-epoch.spectec:483:1-486:92:
   rule cons: state .VALIDATORS[ validatorIndex*{validatorIndex <- validatorIndex*} ]~> state_out
      -- if validatorIndex*{validatorIndex <- validatorIndex*} matches _ :: _
      -- let vid_h :: vid_t*{vid_t <- vid_t*} = validatorIndex*{validatorIndex <- validatorIndex*}
      -- rel ProcessEligibilityAndEjection: state .VALIDATORS[ vid_h ]~> state_h
      -- rel ProcessEligibilityAndEjection_over_vids: state_h .VALIDATORS[ vid_t*{vid_t <- vid_t*} ]~> state_out

;; spec/spec_deneb/12-helpers-process-epoch.spectec:489:1-489:72:
def $is_eligible_activation_en((nat, validator), beaconState) : boolean =

   ;; spec/spec_deneb/12-helpers-process-epoch.spectec:490:1-491:50:
   clause 0((_nat, validator), state) = $is_eligible_for_activation(state, validator)

;; spec/spec_deneb/12-helpers-process-epoch.spectec:495:1-497:20:
relation ApplyActivation: beaconState .VALIDATORS[ validatorIndex ].ACTIVATION_EPOCH~> beaconState

   ;; spec/spec_deneb/12-helpers-process-epoch.spectec:499:1-502:71:
   rule : state .VALIDATORS[ vid ].ACTIVATION_EPOCH~> state[VALIDATORS[vid].ACTIVATION_EPOCH = $compute_activation_exit_epoch($get_current_epoch(state))]

;; spec/spec_deneb/12-helpers-process-epoch.spectec:504:1-508:20:
relation ApplyActivations: beaconState .VALIDATORS[ validatorIndex* ].ACTIVATION_EPOCH~>* beaconState

   ;; spec/spec_deneb/12-helpers-process-epoch.spectec:510:1-511:59:
   rule nil: state .VALIDATORS[ validatorIndex*{validatorIndex <- validatorIndex*} ].ACTIVATION_EPOCH~>* state
      -- if validatorIndex*{validatorIndex <- validatorIndex*} matches []

   ;; spec/spec_deneb/12-helpers-process-epoch.spectec:513:1-516:89:
   rule cons: state .VALIDATORS[ validatorIndex*{validatorIndex <- validatorIndex*} ].ACTIVATION_EPOCH~>* state_out
      -- if validatorIndex*{validatorIndex <- validatorIndex*} matches _ :: _
      -- let vid_h :: vid_t*{vid_t <- vid_t*} = validatorIndex*{validatorIndex <- validatorIndex*}
      -- rel ApplyActivation: state .VALIDATORS[ vid_h ].ACTIVATION_EPOCH~> state_h
      -- rel ApplyActivations: state_h .VALIDATORS[ vid_t*{vid_t <- vid_t*} ].ACTIVATION_EPOCH~>* state_out

;; spec/spec_deneb/12.1-process-slot-and-epoch-functions.spectec:6:1-8:17:
relation ProcessSlot: beaconState ~> beaconState

   ;; spec/spec_deneb/12.1-process-slot-and-epoch-functions.spectec:11:1-25:79:
   rule header_root_empty: state ~> state[STATE_ROOTS[i] = root_state_prev][LATEST_BLOCK_HEADER = beaconBlockHeader][BLOCK_ROOTS[i] = root_block_prev]
      -- let i = (state.SLOT \ $SLOTS_PER_HISTORICAL_ROOT)
      -- if (state.LATEST_BLOCK_HEADER.STATE_ROOT = $ZERO_ROOT)
      -- let root_state_prev = $hash_tree_root_beaconState(state)
      -- let beaconBlockHeader = state.LATEST_BLOCK_HEADER[STATE_ROOT = $hash_tree_root_beaconState(state)]
      -- let root_block_prev = $hash_tree_root_beaconBlockHeader(beaconBlockHeader)

   ;; spec/spec_deneb/12.1-process-slot-and-epoch-functions.spectec:28:1-38:87:
   rule header_root_not_empty: state ~> state[STATE_ROOTS[i] = root_state_prev][BLOCK_ROOTS[i] = root_block_prev]
      -- let i = (state.SLOT \ $SLOTS_PER_HISTORICAL_ROOT)
      -- if (state.LATEST_BLOCK_HEADER.STATE_ROOT =/= $ZERO_ROOT)
      -- let root_state_prev = $hash_tree_root_beaconState(state)
      -- let root_block_prev = $hash_tree_root_beaconBlockHeader(state.LATEST_BLOCK_HEADER)

;; spec/spec_deneb/12.1-process-slot-and-epoch-functions.spectec:46:1-48:17:
relation ProcessJustificationAndFinalization: beaconState ~> beaconState

   ;; spec/spec_deneb/12.1-process-slot-and-epoch-functions.spectec:50:1-53:45:
   rule skip: state ~> state
      -- let epoch_cur = $get_current_epoch(state)
      -- if (epoch_cur <= ($GENESIS_EPOCH + 1))

   ;; spec/spec_deneb/12.1-process-slot-and-epoch-functions.spectec:55:1-71:25:
   rule main: state ~> state_updated
      -- let vid_prev*{vid_prev <- vid_prev*} = $get_unslashed_participating_indices(state, $TIMELY_TARGET_FLAG_INDEX, $get_previous_epoch(state))
      -- let vid_cur*{vid_cur <- vid_cur*} = $get_unslashed_participating_indices(state, $TIMELY_TARGET_FLAG_INDEX, $get_current_epoch(state))
      -- let balance_total_active = $get_total_active_balance(state)
      -- let balance_prev_target = $get_total_balance(state, vid_prev*{vid_prev <- vid_prev*})
      -- let balance_cur_target = $get_total_balance(state, vid_cur*{vid_cur <- vid_cur*})
      -- rel WeighJustificationAndFinalization: state TOTAL balance_total_active PREV balance_prev_target CUR balance_cur_target ~> state_updated

;; spec/spec_deneb/12.1-process-slot-and-epoch-functions.spectec:77:1-79:17:
relation ProcessInactivityUpdates: beaconState ~> beaconState

   ;; spec/spec_deneb/12.1-process-slot-and-epoch-functions.spectec:81:1-84:51:
   rule skip: state ~> state
      -- if ($get_current_epoch(state) = $GENESIS_EPOCH)

   ;; spec/spec_deneb/12.1-process-slot-and-epoch-functions.spectec:86:1-90:95:
   rule main: state ~> state_updated
      -- otherwise
      -- let vid_eligible*{vid_eligible <- vid_eligible*} = $get_eligible_validator_indices(state)
      -- rel ApplyInactivity_over_vids: state .INACTIVITY_SCORES[ vid_eligible*{vid_eligible <- vid_eligible*} ]~>* state_updated

;; spec/spec_deneb/12.1-process-slot-and-epoch-functions.spectec:96:1-98:17:
relation ProcessRewardsAndPenalties: beaconState ~> beaconState

   ;; spec/spec_deneb/12.1-process-slot-and-epoch-functions.spectec:100:1-102:51:
   rule skip: state ~> state
      -- if ($get_current_epoch(state) = $GENESIS_EPOCH)

   ;; spec/spec_deneb/12.1-process-slot-and-epoch-functions.spectec:104:1-118:109:
   rule main: state ~> state_out
      -- otherwise
      -- let vid_flag*{vid_flag <- vid_flag*} = $range(|$PARTICIPATION_FLAG_WEIGHTS|)
      -- (let (reward_flag*{reward_flag <- reward_flag*}, penalty_flag*{penalty_flag <- penalty_flag*}) = $get_flag_index_deltas(state, vid_flag))*{penalty_flag* <- penalty_flag**, reward_flag* <- reward_flag**, vid_flag <- vid_flag*}
      -- let (reward_inactivity*{reward_inactivity <- reward_inactivity*}, penalty_inactivity*{penalty_inactivity <- penalty_inactivity*}) = $get_inactivity_penalty_deltas(state)
      -- let reward*{reward <- reward*}*{reward* <- reward**} = reward_flag*{reward_flag <- reward_flag*}*{reward_flag* <- reward_flag**} ++ [reward_inactivity*{reward_inactivity <- reward_inactivity*}]
      -- let penalty*{penalty <- penalty*}*{penalty* <- penalty**} = penalty_flag*{penalty_flag <- penalty_flag*}*{penalty_flag* <- penalty_flag**} ++ [penalty_inactivity*{penalty_inactivity <- penalty_inactivity*}]
      -- let vid*{vid <- vid*} = $range(|state.VALIDATORS|)
      -- rel ApplyRewardsAndPenalties_over_deltas: state .BALANCES[ vid*{vid <- vid*} ]+ reward*{reward <- reward*}*{reward* <- reward**} - penalty*{penalty <- penalty*}*{penalty* <- penalty**} ~>* state_out

;; spec/spec_deneb/12.1-process-slot-and-epoch-functions.spectec:125:1-127:17:
relation ProcessRegistryUpdates: beaconState ~> beaconState

   ;; spec/spec_deneb/12.1-process-slot-and-epoch-functions.spectec:129:1-149:79:
   rule : state ~> state_out
      -- let vid*{vid <- vid*} = $range(|state.VALIDATORS|)
      -- rel ProcessEligibilityAndEjection_over_vids: state .VALIDATORS[ vid*{vid <- vid*} ]~> state_1
      -- let (vid_1, validator)*{validator <- validator*, vid_1 <- vid_1*} = $enumerate_<validator>(state_1.VALIDATORS)
      -- let (vid_elg, validator_elg)*{validator_elg <- validator_elg*, vid_elg <- vid_elg*} = $filter_list_2_<(nat, validator), beaconState>((vid_1, validator)*{validator <- validator*, vid_1 <- vid_1*}, state_1, $is_eligible_activation_en)
      -- (let epoch_elg = validator_elg.ACTIVATION_ELIGIBILITY_EPOCH)*{epoch_elg <- epoch_elg*, validator_elg <- validator_elg*}
      -- let (_epoch, vid_activation_queue)*{_epoch <- _epoch*, vid_activation_queue <- vid_activation_queue*} = $sort_<(epoch, validatorIndex)>((epoch_elg, vid_elg)*{epoch_elg <- epoch_elg*, vid_elg <- vid_elg*})
      -- let vid_dequeued*{vid_dequeued <- vid_dequeued*} = vid_activation_queue*{vid_activation_queue <- vid_activation_queue*}[0 : $get_validator_activation_churn_limit(state_1)]
      -- rel ApplyActivations: state_1 .VALIDATORS[ vid_dequeued*{vid_dequeued <- vid_dequeued*} ].ACTIVATION_EPOCH~>* state_out

;; spec/spec_deneb/12.1-process-slot-and-epoch-functions.spectec:155:1-157:17:
relation ProcessSlashings: beaconState ~> beaconState

   ;; spec/spec_deneb/12.1-process-slot-and-epoch-functions.spectec:159:1-183:79:
   rule : state ~> state_out
      -- let epoch_cur = $get_current_epoch(state)
      -- let balance_total = $get_total_active_balance(state)
      -- if ($sum_<gwei>(state.SLASHINGS) <= ($UINT64_MAX / $PROPORTIONAL_SLASHING_MULTIPLIER_BELLATRIX))   ;; [ins:overflow]
      -- let balance_adjusted_total_slashing = $min_uint64(($sum_<gwei>(state.SLASHINGS) * $PROPORTIONAL_SLASHING_MULTIPLIER_BELLATRIX), balance_total)
      -- let (vid, validator)*{validator <- validator*, vid <- vid*} = $enumerate_<validator>(state.VALIDATORS)
      -- let (vid_due, validator_due)*{validator_due <- validator_due*, vid_due <- vid_due*} = $filter_list_2_<(validatorIndex, validator), epoch>((vid, validator)*{validator <- validator*, vid <- vid*}, epoch_cur, $is_due_slashing_en)
      -- let gwei_increment = $EFFECTIVE_BALANCE_INCREMENT
      -- (let penalty_numerator = ((validator_due.EFFECTIVE_BALANCE / gwei_increment) * balance_adjusted_total_slashing))*{penalty_numerator <- penalty_numerator*, validator_due <- validator_due*}
      -- (if (penalty_numerator <= $UINT64_MAX))*{penalty_numerator <- penalty_numerator*}
      -- (let penalty = ((penalty_numerator / balance_total) * gwei_increment))*{penalty <- penalty*, penalty_numerator <- penalty_numerator*}
      -- rel DecreaseBalances: state .BALANCES[ vid_due*{vid_due <- vid_due*} ]- penalty*{penalty <- penalty*} ~> state_out

;; spec/spec_deneb/12.1-process-slot-and-epoch-functions.spectec:189:1-191:17:
relation ProcessEth1DataReset: beaconState ~> beaconState

   ;; spec/spec_deneb/12.1-process-slot-and-epoch-functions.spectec:193:1-197:61:
   rule skip: state ~> state
      -- let epoch_next = ($get_current_epoch(state) + 1)
      -- if ((epoch_next \ $EPOCHS_PER_ETH1_VOTING_PERIOD) =/= 0)

   ;; spec/spec_deneb/12.1-process-slot-and-epoch-functions.spectec:199:1-201:15:
   rule main: state ~> state[ETH1_DATA_VOTES = []]
      -- otherwise

;; spec/spec_deneb/12.1-process-slot-and-epoch-functions.spectec:210:1-212:17:
relation ProcessEffectiveBalanceUpdates: beaconState ~> beaconState

   ;; spec/spec_deneb/12.1-process-slot-and-epoch-functions.spectec:214:1-221:67:
   rule : state ~> state[VALIDATORS = validator_updated*{validator_updated <- validator_updated*}]
      -- let (vid, validator)*{validator <- validator*, vid <- vid*} = $enumerate_<validator>(state.VALIDATORS)
      -- if (|state.VALIDATORS| <= |state.BALANCES|)   ;; [ins:bounds]
      -- (let balance = state.BALANCES[vid])*{balance <- balance*, vid <- vid*}
      -- (rel ApplyEffectiveBalance: validator .EFFECTIVE_BALANCE balance ~> validator_updated)*{balance <- balance*, validator <- validator*, validator_updated <- validator_updated*}

;; spec/spec_deneb/12.1-process-slot-and-epoch-functions.spectec:227:1-229:17:
relation ProcessSlashingsReset: beaconState ~> beaconState

   ;; spec/spec_deneb/12.1-process-slot-and-epoch-functions.spectec:231:1-236:33:
   rule : state ~> state[SLASHINGS[i] = 0]
      -- let epoch_next = ($get_current_epoch(state) + 1)
      -- let i = (epoch_next \ $EPOCHS_PER_SLASHINGS_VECTOR)
      -- if (i < |state.SLASHINGS|)   ;; [ins:bounds]

;; spec/spec_deneb/12.1-process-slot-and-epoch-functions.spectec:243:1-245:17:
relation ProcessRandaoMixesReset: beaconState ~> beaconState

   ;; spec/spec_deneb/12.1-process-slot-and-epoch-functions.spectec:247:1-253:36:
   rule : state ~> state[RANDAO_MIXES[i] = $get_randao_mix(state, epoch_cur)]
      -- let epoch_cur = $get_current_epoch(state)
      -- let epoch_next = (epoch_cur + 1)
      -- let i = (epoch_next \ $EPOCHS_PER_HISTORICAL_VECTOR)
      -- if (i < |state.RANDAO_MIXES|)   ;; [ins:bounds]

;; spec/spec_deneb/12.1-process-slot-and-epoch-functions.spectec:259:1-261:17:
relation ProcessHistoricalSummariesUpdate: beaconState ~> beaconState

   ;; spec/spec_deneb/12.1-process-slot-and-epoch-functions.spectec:263:1-267:78:
   rule skip: state ~> state
      -- let epoch_next = ($get_current_epoch(state) + 1)
      -- if ((epoch_next \ ($SLOTS_PER_HISTORICAL_ROOT / $SLOTS_PER_EPOCH)) =/= 0)

   ;; spec/spec_deneb/12.1-process-slot-and-epoch-functions.spectec:269:1-278:109:
   rule main: state ~> state[HISTORICAL_SUMMARIES = state.HISTORICAL_SUMMARIES ++ [historicalSummary]]
      -- otherwise
      -- let root_block_summary = $hash_tree_root_roots(state.BLOCK_ROOTS)
      -- let root_state_summary = $hash_tree_root_roots(state.STATE_ROOTS)
      -- let historicalSummary = {BLOCK_SUMMARY_ROOT root_block_summary, STATE_SUMMARY_ROOT root_state_summary}

;; spec/spec_deneb/12.1-process-slot-and-epoch-functions.spectec:285:1-287:17:
relation ProcessParticipationFlagUpdates: beaconState ~> beaconState

   ;; spec/spec_deneb/12.1-process-slot-and-epoch-functions.spectec:289:1-293:87:
   rule : state ~> state[PREVIOUS_EPOCH_PARTICIPATION = state.CURRENT_EPOCH_PARTICIPATION][CURRENT_EPOCH_PARTICIPATION = participationFlags_zero*{participationFlags_zero <- participationFlags_zero*}]
      -- let participationFlags_zero*{participationFlags_zero <- participationFlags_zero*} = $repeat_<participationFlags>(0, |state.VALIDATORS|)

;; spec/spec_deneb/12.1-process-slot-and-epoch-functions.spectec:300:1-302:17:
relation ProcessSyncCommitteeUpdates: beaconState ~> beaconState

   ;; spec/spec_deneb/12.1-process-slot-and-epoch-functions.spectec:304:1-308:64:
   rule skip: state ~> state
      -- let epoch_next = ($get_current_epoch(state) + 1)
      -- if ((epoch_next \ $EPOCHS_PER_SYNC_COMMITTEE_PERIOD) =/= 0)

   ;; spec/spec_deneb/12.1-process-slot-and-epoch-functions.spectec:310:1-314:15:
   rule main: state ~> state[CURRENT_SYNC_COMMITTEE = state.NEXT_SYNC_COMMITTEE][NEXT_SYNC_COMMITTEE = $get_next_sync_committee(state)]
      -- otherwise

;; spec/spec_deneb/12.2-process-slots-and-epoch.spectec:5:1-7:17:
relation ProcessEpoch: beaconState ~> beaconState

   ;; spec/spec_deneb/12.2-process-slots-and-epoch.spectec:9:1-34:73:
   rule : state ~> state_11
      -- rel ProcessJustificationAndFinalization: state ~> state_0
      -- rel ProcessInactivityUpdates: state_0 ~> state_1
      -- rel ProcessRewardsAndPenalties: state_1 ~> state_2
      -- rel ProcessRegistryUpdates: state_2 ~> state_3
      -- rel ProcessSlashings: state_3 ~> state_4
      -- rel ProcessEth1DataReset: state_4 ~> state_5
      -- rel ProcessEffectiveBalanceUpdates: state_5 ~> state_6
      -- rel ProcessSlashingsReset: state_6 ~> state_7
      -- rel ProcessRandaoMixesReset: state_7 ~> state_8
      -- rel ProcessHistoricalSummariesUpdate: state_8 ~> state_9
      -- rel ProcessParticipationFlagUpdates: state_9 ~> state_10
      -- rel ProcessSyncCommitteeUpdates: state_10 ~> state_11

;; spec/spec_deneb/12.2-process-slots-and-epoch.spectec:39:1-41:20:
relation ProcessSlots_loop: beaconState slot ~> beaconState

   ;; spec/spec_deneb/12.2-process-slots-and-epoch.spectec:44:1-46:39:
   rule base: state slot_target ~> state
      -- if (state.SLOT >= slot_target)

   ;; spec/spec_deneb/12.2-process-slots-and-epoch.spectec:49:1-62:60:
   rule step-no-epoch: state slot_target ~> state_out
      -- if (state.SLOT < slot_target)
      -- rel ProcessSlot: state ~> state_after_slot
      -- let slot_cur = state_after_slot.SLOT
      -- let slot_next = (slot_cur + 1)
      -- if ((slot_next \ $SLOTS_PER_EPOCH) =/= 0)
      -- let state_next = state_after_slot[SLOT = slot_next]
      -- rel ProcessSlots_loop: state_next slot_target ~> state_out

   ;; spec/spec_deneb/12.2-process-slots-and-epoch.spectec:65:1-79:60:
   rule step-epoch: state slot_target ~> state_out
      -- if (state.SLOT < slot_target)
      -- rel ProcessSlot: state ~> state_after_slot
      -- let slot_cur = state_after_slot.SLOT
      -- let slot_next = (slot_cur + 1)
      -- if ((slot_next \ $SLOTS_PER_EPOCH) = 0)
      -- rel ProcessEpoch: state_after_slot ~> state_after_epoch
      -- let state_next = state_after_epoch[SLOT = slot_next]
      -- rel ProcessSlots_loop: state_next slot_target ~> state_out

;; spec/spec_deneb/12.2-process-slots-and-epoch.spectec:82:1-84:20:
relation ProcessSlots: beaconState slot ~> beaconState

   ;; spec/spec_deneb/12.2-process-slots-and-epoch.spectec:86:1-90:55:
   rule : state slot_target ~> state_out
      -- if (state.SLOT < slot_target)
      -- rel ProcessSlots_loop: state slot_target ~> state_out

;; spec/spec_deneb/13-helpers-process-block.spectec:7:1-9:16:
def $expected_withdrawals_loop(beaconState, epoch, withdrawalIndex, validatorIndex, uint64, uint64, withdrawal*) : withdrawal* =

   ;; spec/spec_deneb/13-helpers-process-block.spectec:11:1-13:57:
   clause 0(_beaconState, _epoch, _withdrawalIndex, _validatorIndex, _uint64, _uint64', withdrawal_acc*{withdrawal_acc <- withdrawal_acc*}) = withdrawal_acc*{withdrawal_acc <- withdrawal_acc*}
      -- if (|withdrawal_acc*{withdrawal_acc <- withdrawal_acc*}| = $MAX_WITHDRAWALS_PER_PAYLOAD)

   ;; spec/spec_deneb/13-helpers-process-block.spectec:15:1-17:31:
   clause 1(_beaconState, _epoch, _withdrawalIndex, _validatorIndex, uint64_bound, i, withdrawal_acc*{withdrawal_acc <- withdrawal_acc*}) = withdrawal_acc*{withdrawal_acc <- withdrawal_acc*}
      -- if (i >= uint64_bound)

   ;; spec/spec_deneb/13-helpers-process-block.spectec:20:1-43:35:
   clause 2(state, epoch, withdrawalIndex, vid, uint64_bound, i, withdrawal_acc*{withdrawal_acc <- withdrawal_acc*}) = $expected_withdrawals_loop(state, epoch, (withdrawalIndex + 1), ((vid + 1) \ |state.VALIDATORS|), uint64_bound, (i + 1), withdrawal_acc*{withdrawal_acc <- withdrawal_acc*} ++ [withdrawal])
      -- if (vid < |state.VALIDATORS|)   ;; [ins:bounds]
      -- if (vid < |state.BALANCES|)   ;; [ins:bounds]
      -- let validator = state.VALIDATORS[vid]
      -- let balance = state.BALANCES[vid]
      -- if ($is_fully_withdrawable_validator(validator, balance, epoch) = true)
      -- if (withdrawalIndex <= ($UINT64_MAX - 1))   ;; [ins:overflow]
      -- let withdrawal = {INDEX withdrawalIndex, VALIDATOR_INDEX vid, ADDRESS $extract_execution_address(validator.WITHDRAWAL_CREDENTIALS), AMOUNT balance}

   ;; spec/spec_deneb/13-helpers-process-block.spectec:47:1-71:65:
   clause 3(state, epoch, withdrawalIndex, vid, uint64_bound, i, withdrawal_acc*{withdrawal_acc <- withdrawal_acc*}) = $expected_withdrawals_loop(state, epoch, (withdrawalIndex + 1), ((vid + 1) \ |state.VALIDATORS|), uint64_bound, (i + 1), withdrawal_acc*{withdrawal_acc <- withdrawal_acc*} ++ [withdrawal])
      -- if (vid < |state.VALIDATORS|)   ;; [ins:bounds]
      -- if (vid < |state.BALANCES|)   ;; [ins:bounds]
      -- let validator = state.VALIDATORS[vid]
      -- let balance = state.BALANCES[vid]
      -- if ($is_fully_withdrawable_validator(validator, balance, epoch) = false)
      -- if ($is_partially_withdrawable_validator(validator, balance) = true)
      -- if (withdrawalIndex <= ($UINT64_MAX - 1))   ;; [ins:overflow]
      -- let withdrawal = {INDEX withdrawalIndex, VALIDATOR_INDEX vid, ADDRESS $extract_execution_address(validator.WITHDRAWAL_CREDENTIALS), AMOUNT (balance - $MAX_EFFECTIVE_BALANCE)}

   ;; spec/spec_deneb/13-helpers-process-block.spectec:74:1-91:67:
   clause 4(state, epoch, withdrawalIndex, vid, uint64_bound, i, withdrawal_acc*{withdrawal_acc <- withdrawal_acc*}) = $expected_withdrawals_loop(state, epoch, withdrawalIndex, ((vid + 1) \ |state.VALIDATORS|), uint64_bound, (i + 1), withdrawal_acc*{withdrawal_acc <- withdrawal_acc*})
      -- if (vid < |state.VALIDATORS|)   ;; [ins:bounds]
      -- if (vid < |state.BALANCES|)   ;; [ins:bounds]
      -- let validator = state.VALIDATORS[vid]
      -- let balance = state.BALANCES[vid]
      -- if ~$is_fully_withdrawable_validator(validator, balance, epoch)
      -- if ~$is_partially_withdrawable_validator(validator, balance)

;; spec/spec_deneb/13-helpers-process-block.spectec:94:1-94:57:
def $get_expected_withdrawals(beaconState) : withdrawal* =

   ;; spec/spec_deneb/13-helpers-process-block.spectec:96:1-103:94:
   clause 0(state) = $expected_withdrawals_loop(state, epoch_cur, withdrawalIndex_start, validatorIndex_start, uint64_bound, 0, [])
      -- let epoch_cur = $get_current_epoch(state)
      -- let withdrawalIndex_start = state.NEXT_WITHDRAWAL_INDEX
      -- let validatorIndex_start = state.NEXT_WITHDRAWAL_VALIDATOR_INDEX
      -- let uint64_bound = $min_uint64(|state.VALIDATORS|, $MAX_VALIDATORS_PER_WITHDRAWALS_SWEEP)

;; spec/spec_deneb/13-helpers-process-block.spectec:105:1-107:20:
relation ApplyWithdrawal: beaconState .BALANCES{ withdrawal }~> beaconState

   ;; spec/spec_deneb/13-helpers-process-block.spectec:109:1-111:105:
   rule main: state .BALANCES{ withdrawal }~> state_out
      -- rel DecreaseBalance: state .BALANCES[ withdrawal.VALIDATOR_INDEX ]- withdrawal.AMOUNT ~> state_out

;; spec/spec_deneb/13-helpers-process-block.spectec:113:1-115:20:
relation ApplyWithdrawals: beaconState .BALANCES{ withdrawal* }~>* beaconState

   ;; spec/spec_deneb/13-helpers-process-block.spectec:117:1-118:38:
   rule nil: state .BALANCES{ withdrawal*{withdrawal <- withdrawal*} }~>* state
      -- if withdrawal*{withdrawal <- withdrawal*} matches []

   ;; spec/spec_deneb/13-helpers-process-block.spectec:120:1-123:75:
   rule cons: state .BALANCES{ withdrawal*{withdrawal <- withdrawal*} }~>* state_out
      -- if withdrawal*{withdrawal <- withdrawal*} matches _ :: _
      -- let withdrawal_h :: withdrawal_t*{withdrawal_t <- withdrawal_t*} = withdrawal*{withdrawal <- withdrawal*}
      -- rel ApplyWithdrawal: state .BALANCES{ withdrawal_h }~> state_1
      -- rel ApplyWithdrawals: state_1 .BALANCES{ withdrawal_t*{withdrawal_t <- withdrawal_t*} }~>* state_out

;; spec/spec_deneb/13-helpers-process-block.spectec:128:1-130:29:
relation AddFlag: participationFlags [ validatorIndex ]++{ validatorIndex }# beaconState #SUM gwei ~> participationFlags #SUM gwei

   ;; spec/spec_deneb/13-helpers-process-block.spectec:132:1-138:61:
   rule main: participationFlags [ vid_attesting ]++{ vid_flag }# state #SUM reward ~> $add_flag(participationFlags, vid_flag) #SUM (reward + (reward_base * $PARTICIPATION_FLAG_WEIGHTS[vid_flag]))
      -- if ~$has_flag(participationFlags, vid_flag)
      -- let reward_base = $get_base_reward(state, vid_attesting)

   ;; spec/spec_deneb/13-helpers-process-block.spectec:139:1-141:48:
   rule skip: participationFlags [ _validatorIndex ]++{ vid_flag }# _beaconState #SUM reward ~> participationFlags #SUM reward
      -- if $has_flag(participationFlags, vid_flag)

;; spec/spec_deneb/13-helpers-process-block.spectec:145:1-148:29:
relation AddFlags: participationFlags [ validatorIndex ]++{ validatorIndex* }# beaconState #SUM gwei ~> participationFlags #SUM gwei

   ;; spec/spec_deneb/13-helpers-process-block.spectec:150:1-151:94:
   rule nil: participationFlags [ _validatorIndex ]++{ validatorIndex*{validatorIndex <- validatorIndex*} }# _beaconState #SUM reward ~> participationFlags #SUM reward
      -- if validatorIndex*{validatorIndex <- validatorIndex*} matches []

   ;; spec/spec_deneb/13-helpers-process-block.spectec:152:1-158:45:
   rule cons: participationFlags [ vid_attesting ]++{ validatorIndex*{validatorIndex <- validatorIndex*} }# state #SUM reward ~> participationFlags_t #SUM reward_t
      -- if validatorIndex*{validatorIndex <- validatorIndex*} matches _ :: _
      -- let vid_flag_h :: vid_flag_t*{vid_flag_t <- vid_flag_t*} = validatorIndex*{validatorIndex <- validatorIndex*}
      -- rel AddFlag: participationFlags [ vid_attesting ]++{ vid_flag_h }# state #SUM reward ~> participationFlags_h #SUM reward_h
      -- rel AddFlags: participationFlags_h [ vid_attesting ]++{ vid_flag_t*{vid_flag_t <- vid_flag_t*} }# state #SUM reward_h ~> participationFlags_t #SUM reward_t

;; spec/spec_deneb/13-helpers-process-block.spectec:162:1-165:29:
relation ProcessFlags: participationFlags* [ validatorIndex ]++{ validatorIndex* }# beaconState #SUM gwei ~> participationFlags* #SUM gwei

   ;; spec/spec_deneb/13-helpers-process-block.spectec:167:1-174:59:
   rule main: participationFlags*{participationFlags <- participationFlags*} [ vid_attesting ]++{ vid_flag*{vid_flag <- vid_flag*} }# state #SUM reward ~> participationFlags*{participationFlags <- participationFlags*}[[vid_attesting] = participationFlags_updated] #SUM (reward + reward_increment)
      -- if (vid_attesting < |participationFlags*{participationFlags <- participationFlags*}|)
      -- rel AddFlags: participationFlags*{participationFlags <- participationFlags*}[vid_attesting] [ vid_attesting ]++{ vid_flag*{vid_flag <- vid_flag*} }# state #SUM 0 ~> participationFlags_updated #SUM reward_increment

;; spec/spec_deneb/13-helpers-process-block.spectec:178:1-181:29:
relation ProcessFlags_over_attesting: participationFlags* [ validatorIndex* ]++{ validatorIndex* }# beaconState #SUM gwei ~> participationFlags* #SUM gwei

   ;; spec/spec_deneb/13-helpers-process-block.spectec:183:1-184:96:
   rule nil: participationFlags*{participationFlags <- participationFlags*} [ validatorIndex*{validatorIndex <- validatorIndex*} ]++{ _validatorIndex*{_validatorIndex <- _validatorIndex*} }# _beaconState #SUM reward ~> participationFlags*{participationFlags <- participationFlags*} #SUM reward
      -- if validatorIndex*{validatorIndex <- validatorIndex*} matches []

   ;; spec/spec_deneb/13-helpers-process-block.spectec:185:1-191:46:
   rule cons: participationFlags*{participationFlags <- participationFlags*} [ validatorIndex*{validatorIndex <- validatorIndex*} ]++{ vid_flag*{vid_flag <- vid_flag*} }# state #SUM reward ~> participationFlags_2*{participationFlags_2 <- participationFlags_2*} #SUM reward_2
      -- if validatorIndex*{validatorIndex <- validatorIndex*} matches _ :: _
      -- let vid_attesting_h :: vid_attesting_t*{vid_attesting_t <- vid_attesting_t*} = validatorIndex*{validatorIndex <- validatorIndex*}
      -- rel ProcessFlags: participationFlags*{participationFlags <- participationFlags*} [ vid_attesting_h ]++{ vid_flag*{vid_flag <- vid_flag*} }# state #SUM reward ~> participationFlags_1*{participationFlags_1 <- participationFlags_1*} #SUM reward_1
      -- rel ProcessFlags_over_attesting: participationFlags_1*{participationFlags_1 <- participationFlags_1*} [ vid_attesting_t*{vid_attesting_t <- vid_attesting_t*} ]++{ vid_flag*{vid_flag <- vid_flag*} }# state #SUM reward_1 ~> participationFlags_2*{participationFlags_2 <- participationFlags_2*} #SUM reward_2

;; spec/spec_deneb/13-helpers-process-block.spectec:194:1-194:70:
def $bit_is_one_en_blsPubkey(enumerated_<blsPubkey>, boolean*) : bool =

   ;; spec/spec_deneb/13-helpers-process-block.spectec:195:1-197:32:
   clause 0((i, blsPubkey), boolean_bits*{boolean_bits <- boolean_bits*}) = true
      -- if (i < |boolean_bits*{boolean_bits <- boolean_bits*}|)
      -- if (boolean_bits*{boolean_bits <- boolean_bits*}[i] = true)

   ;; spec/spec_deneb/13-helpers-process-block.spectec:198:1-199:15:
   clause 1((i, blsPubkey), boolean_bits*{boolean_bits <- boolean_bits*}) = false
      -- otherwise

;; spec/spec_deneb/13-helpers-process-block.spectec:203:1-208:32:
relation ApplyReward: beaconState PARTICIPANT boolean [ validatorIndex ]+ gwei PROPOSER[ validatorIndex ]+ gwei ~> beaconState

   ;; spec/spec_deneb/13-helpers-process-block.spectec:210:1-216:101:
   rule participation: state PARTICIPANT bool [ vid_participant ]+ reward_participant PROPOSER[ vid_proposer ]+ reward_proposer ~> state_out
      -- if (bool = true)
      -- rel IncreaseBalance: state .BALANCES[ vid_participant ]+ reward_participant ~> state_participant
      -- rel IncreaseBalance: state_participant .BALANCES[ vid_proposer ]+ reward_proposer ~> state_out

   ;; spec/spec_deneb/13-helpers-process-block.spectec:218:1-223:95:
   rule no_participation: state PARTICIPANT bool [ vid_participant ]+ reward_participant PROPOSER[ _validatorIndex ]+ _gwei ~> state_out
      -- if (bool = false)
      -- rel DecreaseBalance: state .BALANCES[ vid_participant ]- reward_participant ~> state_out

;; spec/spec_deneb/13-helpers-process-block.spectec:227:1-232:34:
relation ApplyReward_over_participants: beaconState PARTICIPANT boolean* [ validatorIndex* ]+ gwei PROPOSER[ validatorIndex ]+ gwei ~> beaconState

   ;; spec/spec_deneb/13-helpers-process-block.spectec:234:1-238:15:
   rule nil: state PARTICIPANT boolean*{boolean <- boolean*} [ validatorIndex*{validatorIndex <- validatorIndex*} ]+ _gwei PROPOSER[ _validatorIndex ]+ _gwei' ~> state
      -- if boolean*{boolean <- boolean*} matches []
      -- if validatorIndex*{validatorIndex <- validatorIndex*} matches []

   ;; spec/spec_deneb/13-helpers-process-block.spectec:240:1-254:23:
   rule cons: state PARTICIPANT boolean*{boolean <- boolean*} [ validatorIndex*{validatorIndex <- validatorIndex*} ]+ reward_participant PROPOSER[ vid_proposer ]+ reward_proposer ~> state_out
      -- if boolean*{boolean <- boolean*} matches _ :: _
      -- let boolean_h :: boolean_t*{boolean_t <- boolean_t*} = boolean*{boolean <- boolean*}
      -- if validatorIndex*{validatorIndex <- validatorIndex*} matches _ :: _
      -- let vid_participant_h :: vid_participant_t*{vid_participant_t <- vid_participant_t*} = validatorIndex*{validatorIndex <- validatorIndex*}
      -- rel ApplyReward: state PARTICIPANT boolean_h [ vid_participant_h ]+ reward_participant PROPOSER[ vid_proposer ]+ reward_proposer ~> state_1
      -- rel ApplyReward_over_participants: state_1 PARTICIPANT boolean_t*{boolean_t <- boolean_t*} [ vid_participant_t*{vid_participant_t <- vid_participant_t*} ]+ reward_participant PROPOSER[ vid_proposer ]+ reward_proposer ~> state_out

;; spec/spec_deneb/13.1-process-operations-function.spectec:5:1-7:20:
relation ProcessProposerSlashing: beaconState proposerSlashing ~> beaconState

   ;; spec/spec_deneb/13.1-process-operations-function.spectec:9:1-42:75:
   rule : state proposerSlashing ~> state_slashed
      -- let beaconBlockHeader_1 = proposerSlashing.SIGNED_HEADER_1.MESSAGE
      -- let beaconBlockHeader_2 = proposerSlashing.SIGNED_HEADER_2.MESSAGE
      -- if (beaconBlockHeader_1.SLOT = beaconBlockHeader_2.SLOT)
      -- if (beaconBlockHeader_1.PROPOSER_INDEX = beaconBlockHeader_2.PROPOSER_INDEX)
      -- if (beaconBlockHeader_1 =/= beaconBlockHeader_2)
      -- let vid_proposer = beaconBlockHeader_1.PROPOSER_INDEX
      -- if (vid_proposer < |state.VALIDATORS|)   ;; [ins:bounds]
      -- let validator_proposer = state.VALIDATORS[vid_proposer]
      -- if $is_slashable_validator(validator_proposer, $get_current_epoch(state))
      -- let signedBeaconBlockHeader_1 = proposerSlashing.SIGNED_HEADER_1
      -- let epoch_h1 = $compute_epoch_at_slot(signedBeaconBlockHeader_1.MESSAGE.SLOT)
      -- let domain_h1 = $get_domain(state, $DOMAIN_BEACON_PROPOSER, ?(epoch_h1))
      -- let root_sign_h1 = $compute_signing_root_beaconBlockHeader(signedBeaconBlockHeader_1.MESSAGE, domain_h1)
      -- if $bls_verify(validator_proposer.PUBKEY, root_sign_h1, signedBeaconBlockHeader_1.SIGNATURE)
      -- let signedBeaconBlockHeader_2 = proposerSlashing.SIGNED_HEADER_2
      -- let epoch_h2 = $compute_epoch_at_slot(signedBeaconBlockHeader_2.MESSAGE.SLOT)
      -- let domain_h2 = $get_domain(state, $DOMAIN_BEACON_PROPOSER, ?(epoch_h2))
      -- let root_sign_h2 = $compute_signing_root_beaconBlockHeader(signedBeaconBlockHeader_2.MESSAGE, domain_h2)
      -- if $bls_verify(validator_proposer.PUBKEY, root_sign_h2, signedBeaconBlockHeader_2.SIGNATURE)
      -- rel SlashValidator: state SLASH[ vid_proposer ]BY ?() ~> state_slashed

;; spec/spec_deneb/13.1-process-operations-function.spectec:45:1-47:20:
relation ProcessProposerSlashings: beaconState proposerSlashing* ~> beaconState

   ;; spec/spec_deneb/13.1-process-operations-function.spectec:49:1-50:21:
   rule nil: state proposerSlashing*{proposerSlashing <- proposerSlashing*} ~> state
      -- if proposerSlashing*{proposerSlashing <- proposerSlashing*} matches []

   ;; spec/spec_deneb/13.1-process-operations-function.spectec:51:1-54:75:
   rule cons: state proposerSlashing*{proposerSlashing <- proposerSlashing*} ~> state_out
      -- if proposerSlashing*{proposerSlashing <- proposerSlashing*} matches _ :: _
      -- let proposerSlashing_h :: proposerSlashing_t*{proposerSlashing_t <- proposerSlashing_t*} = proposerSlashing*{proposerSlashing <- proposerSlashing*}
      -- rel ProcessProposerSlashing: state proposerSlashing_h ~> state_mid
      -- rel ProcessProposerSlashings: state_mid proposerSlashing_t*{proposerSlashing_t <- proposerSlashing_t*} ~> state_out

;; spec/spec_deneb/13.1-process-operations-function.spectec:61:1-63:20:
relation ProcessAttesterSlashing: beaconState attesterSlashing ~> beaconState

   ;; spec/spec_deneb/13.1-process-operations-function.spectec:65:1-82:25:
   rule : state attesterSlashing ~> state_slashed
      -- let indexedAttestation_1 = attesterSlashing.ATTESTATION_1
      -- let indexedAttestation_2 = attesterSlashing.ATTESTATION_2
      -- if ($is_slashable_attestation_data(indexedAttestation_1.DATA, indexedAttestation_2.DATA) = true)
      -- if ($is_valid_indexed_attestation(state, indexedAttestation_1) = true)
      -- if ($is_valid_indexed_attestation(state, indexedAttestation_2) = true)
      -- let vid_intersection*{vid_intersection <- vid_intersection*} = $set_intersection_<validatorIndex>($to_set_<validatorIndex>(indexedAttestation_1.ATTESTING_INDICES), $to_set_<validatorIndex>(indexedAttestation_2.ATTESTING_INDICES))
      -- let vid_sorted*{vid_sorted <- vid_sorted*} = $sort_<validatorIndex>(vid_intersection*{vid_intersection <- vid_intersection*})
      -- rel SlashIfEligible_over_validators: state SLASH?[ vid_sorted*{vid_sorted <- vid_sorted*} ]~> state_slashed #SLASHED bool_slashed_any
      -- if bool_slashed_any

;; spec/spec_deneb/13.1-process-operations-function.spectec:85:1-87:20:
relation ProcessAttesterSlashings: beaconState attesterSlashing* ~> beaconState

   ;; spec/spec_deneb/13.1-process-operations-function.spectec:89:1-90:21:
   rule nil: state attesterSlashing*{attesterSlashing <- attesterSlashing*} ~> state
      -- if attesterSlashing*{attesterSlashing <- attesterSlashing*} matches []

   ;; spec/spec_deneb/13.1-process-operations-function.spectec:91:1-94:75:
   rule cons: state attesterSlashing*{attesterSlashing <- attesterSlashing*} ~> state_out
      -- if attesterSlashing*{attesterSlashing <- attesterSlashing*} matches _ :: _
      -- let attesterSlashing_h :: attesterSlashing_t*{attesterSlashing_t <- attesterSlashing_t*} = attesterSlashing*{attesterSlashing <- attesterSlashing*}
      -- rel ProcessAttesterSlashing: state attesterSlashing_h ~> state_mid
      -- rel ProcessAttesterSlashings: state_mid attesterSlashing_t*{attesterSlashing_t <- attesterSlashing_t*} ~> state_out

;; spec/spec_deneb/13.1-process-operations-function.spectec:101:1-103:20:
relation ProcessAttestation: beaconState attestation ~> beaconState

   ;; spec/spec_deneb/13.1-process-operations-function.spectec:105:1-136:114:
   rule current_epoch: state attestation ~> state_out
      -- let attestationData = attestation.DATA
      -- if (attestationData.TARGET.EPOCH = $get_current_epoch(state))
      -- if (attestationData.TARGET.EPOCH = $compute_epoch_at_slot(attestationData.SLOT))
      -- if ((attestationData.SLOT + $MIN_ATTESTATION_INCLUSION_DELAY) <= state.SLOT)
      -- if (attestationData.INDEX < $get_committee_count_per_slot(state, attestationData.TARGET.EPOCH))
      -- let vid_committee*{vid_committee <- vid_committee*} = $get_beacon_committee(state, attestationData.SLOT, attestationData.INDEX)
      -- if (|attestation.AGGREGATION_BITS| = |vid_committee*{vid_committee <- vid_committee*}|)
      -- let vid_participation_flag*{vid_participation_flag <- vid_participation_flag*} = $get_attestation_participation_flag_indices(state, attestationData, (state.SLOT - attestationData.SLOT))
      -- if $is_valid_indexed_attestation(state, $get_indexed_attestation(state, attestation))
      -- rel ProcessFlags_over_attesting: state.CURRENT_EPOCH_PARTICIPATION [ $get_attesting_indices(state, attestation) ]++{ vid_participation_flag*{vid_participation_flag <- vid_participation_flag*} }# state #SUM 0 ~> participationFlags_updated*{participationFlags_updated <- participationFlags_updated*} #SUM reward_proposer_numerator
      -- let state_1 = state[CURRENT_EPOCH_PARTICIPATION = participationFlags_updated*{participationFlags_updated <- participationFlags_updated*}]
      -- let reward_proposer_denominator = ((($WEIGHT_DENOMINATOR - $PROPOSER_WEIGHT) * $WEIGHT_DENOMINATOR) / $PROPOSER_WEIGHT)
      -- let reward_proposer = (reward_proposer_numerator / reward_proposer_denominator)
      -- rel IncreaseBalance: state_1 .BALANCES[ $get_beacon_proposer_index(state_1) ]+ reward_proposer ~> state_out

   ;; spec/spec_deneb/13.1-process-operations-function.spectec:138:1-169:114:
   rule previous_epoch: state attestation ~> state_out
      -- let attestationData = attestation.DATA
      -- if (attestationData.TARGET.EPOCH = $get_previous_epoch(state))
      -- if (attestationData.TARGET.EPOCH = $compute_epoch_at_slot(attestationData.SLOT))
      -- if ((attestationData.SLOT + $MIN_ATTESTATION_INCLUSION_DELAY) <= state.SLOT)
      -- if (attestationData.INDEX < $get_committee_count_per_slot(state, attestationData.TARGET.EPOCH))
      -- let vid_committee*{vid_committee <- vid_committee*} = $get_beacon_committee(state, attestationData.SLOT, attestationData.INDEX)
      -- if (|attestation.AGGREGATION_BITS| = |vid_committee*{vid_committee <- vid_committee*}|)
      -- let vid_participation_flag*{vid_participation_flag <- vid_participation_flag*} = $get_attestation_participation_flag_indices(state, attestationData, (state.SLOT - attestationData.SLOT))
      -- if $is_valid_indexed_attestation(state, $get_indexed_attestation(state, attestation))
      -- rel ProcessFlags_over_attesting: state.PREVIOUS_EPOCH_PARTICIPATION [ $get_attesting_indices(state, attestation) ]++{ vid_participation_flag*{vid_participation_flag <- vid_participation_flag*} }# state #SUM 0 ~> participationFlags_updated*{participationFlags_updated <- participationFlags_updated*} #SUM reward_proposer_numerator
      -- let state_1 = state[PREVIOUS_EPOCH_PARTICIPATION = participationFlags_updated*{participationFlags_updated <- participationFlags_updated*}]
      -- let reward_proposer_denominator = ((($WEIGHT_DENOMINATOR - $PROPOSER_WEIGHT) * $WEIGHT_DENOMINATOR) / $PROPOSER_WEIGHT)
      -- let reward_proposer = (reward_proposer_numerator / reward_proposer_denominator)
      -- rel IncreaseBalance: state_1 .BALANCES[ $get_beacon_proposer_index(state_1) ]+ reward_proposer ~> state_out

;; spec/spec_deneb/13.1-process-operations-function.spectec:172:1-174:20:
relation ProcessAttestations: beaconState attestation* ~> beaconState

   ;; spec/spec_deneb/13.1-process-operations-function.spectec:176:1-177:21:
   rule nil: state attestation*{attestation <- attestation*} ~> state
      -- if attestation*{attestation <- attestation*} matches []

   ;; spec/spec_deneb/13.1-process-operations-function.spectec:178:1-181:61:
   rule cons: state attestation*{attestation <- attestation*} ~> state_t
      -- if attestation*{attestation <- attestation*} matches _ :: _
      -- let attestation_h :: attestation_t*{attestation_t <- attestation_t*} = attestation*{attestation <- attestation*}
      -- rel ProcessAttestation: state attestation_h ~> state_h
      -- rel ProcessAttestations: state_h attestation_t*{attestation_t <- attestation_t*} ~> state_t

;; spec/spec_deneb/13.1-process-operations-function.spectec:188:1-190:20:
relation ProcessDeposit: beaconState deposit ~> beaconState

   ;; spec/spec_deneb/13.1-process-operations-function.spectec:192:1-208:53:
   rule main: state deposit ~> state_applied
      -- if $is_valid_merkle_branch($hash_tree_root_depositData(deposit.DATA), deposit.PROOF, ($DEPOSIT_CONTRACT_TREE_DEPTH + 1), state.ETH1_DEPOSIT_INDEX, state.ETH1_DATA.DEPOSIT_ROOT)
      -- let state_inc = state[ETH1_DEPOSIT_INDEX = (state.ETH1_DEPOSIT_INDEX + 1)]
      -- rel ApplyDeposit: state_inc .VALIDATORS++{ deposit.DATA.PUBKEY deposit.DATA.WITHDRAWAL_CREDENTIALS deposit.DATA.AMOUNT }SIGNED deposit.DATA.SIGNATURE ~> state_applied

;; spec/spec_deneb/13.1-process-operations-function.spectec:211:1-213:20:
relation ProcessDeposits: beaconState deposit* ~> beaconState

   ;; spec/spec_deneb/13.1-process-operations-function.spectec:215:1-216:21:
   rule nil: state deposit*{deposit <- deposit*} ~> state
      -- if deposit*{deposit <- deposit*} matches []

   ;; spec/spec_deneb/13.1-process-operations-function.spectec:217:1-220:53:
   rule cons: state deposit*{deposit <- deposit*} ~> state_t
      -- if deposit*{deposit <- deposit*} matches _ :: _
      -- let deposit_h :: deposit_t*{deposit_t <- deposit_t*} = deposit*{deposit <- deposit*}
      -- rel ProcessDeposit: state deposit_h ~> state_h
      -- rel ProcessDeposits: state_h deposit_t*{deposit_t <- deposit_t*} ~> state_t

;; spec/spec_deneb/13.1-process-operations-function.spectec:227:1-229:20:
relation ProcessVoluntaryExit: beaconState signedVoluntaryExit ~> beaconState

   ;; spec/spec_deneb/13.1-process-operations-function.spectec:231:1-256:75:
   rule main: state signedVoluntaryExit ~> state_exit
      -- let voluntaryExit = signedVoluntaryExit.MESSAGE
      -- let vid_exit = voluntaryExit.VALIDATOR_INDEX
      -- if (vid_exit < |state.VALIDATORS|)   ;; [ins:bounds]
      -- let validator = state.VALIDATORS[vid_exit]
      -- let epoch_cur = $get_current_epoch(state)
      -- if ($is_active_validator(validator, epoch_cur) = true)
      -- if (validator.EXIT_EPOCH = $FAR_FUTURE_EPOCH)
      -- if (epoch_cur >= voluntaryExit.EPOCH)
      -- if (validator.ACTIVATION_EPOCH <= ($UINT64_MAX - $SHARD_COMMITTEE_PERIOD))   ;; [ins:overflow]
      -- if (epoch_cur >= (validator.ACTIVATION_EPOCH + $SHARD_COMMITTEE_PERIOD))   ;; [ins:underflow]
      -- let domain_exit = $compute_domain($DOMAIN_VOLUNTARY_EXIT, ?($CAPELLA_FORK_VERSION), ?(state.GENESIS_VALIDATORS_ROOT))
      -- let root_vol_exit_signing_root = $compute_signing_root_voluntary_exit(voluntaryExit, domain_exit)
      -- if ($bls_verify(validator.PUBKEY, root_vol_exit_signing_root, signedVoluntaryExit.SIGNATURE) = true)
      -- rel InitiateValidatorExit: state .VALIDATORS[ vid_exit ]~> state_exit

;; spec/spec_deneb/13.1-process-operations-function.spectec:259:1-261:20:
relation ProcessVoluntaryExits: beaconState signedVoluntaryExit* ~> beaconState

   ;; spec/spec_deneb/13.1-process-operations-function.spectec:263:1-264:21:
   rule nil: state signedVoluntaryExit*{signedVoluntaryExit <- signedVoluntaryExit*} ~> state
      -- if signedVoluntaryExit*{signedVoluntaryExit <- signedVoluntaryExit*} matches []

   ;; spec/spec_deneb/13.1-process-operations-function.spectec:265:1-268:71:
   rule cons: state signedVoluntaryExit*{signedVoluntaryExit <- signedVoluntaryExit*} ~> state_t
      -- if signedVoluntaryExit*{signedVoluntaryExit <- signedVoluntaryExit*} matches _ :: _
      -- let signedVoluntaryExit_h :: signedVoluntaryExit_t*{signedVoluntaryExit_t <- signedVoluntaryExit_t*} = signedVoluntaryExit*{signedVoluntaryExit <- signedVoluntaryExit*}
      -- rel ProcessVoluntaryExit: state signedVoluntaryExit_h ~> state_h
      -- rel ProcessVoluntaryExits: state_h signedVoluntaryExit_t*{signedVoluntaryExit_t <- signedVoluntaryExit_t*} ~> state_t

;; spec/spec_deneb/13.1-process-operations-function.spectec:275:1-277:20:
relation ProcessBlsToExecutionChange: beaconState signedBlsToExecutionChange ~> beaconState

   ;; spec/spec_deneb/13.1-process-operations-function.spectec:279:1-295:102:
   rule main: state signedBlsToExecutionChange ~> state[VALIDATORS[vid_change].WITHDRAWAL_CREDENTIALS = bytes32_new_wc]
      -- let blsToExecutionChange = signedBlsToExecutionChange.MESSAGE
      -- let vid_change = blsToExecutionChange.VALIDATOR_INDEX
      -- if (vid_change < |state.VALIDATORS|)
      -- let validator = state.VALIDATORS[vid_change]
      -- if ($get_first_byte(validator.WITHDRAWAL_CREDENTIALS) = $BLS_WITHDRAWAL_PREFIX)
      -- if ($strip_first_byte(validator.WITHDRAWAL_CREDENTIALS) = $strip_first_byte($hash_<blsPubkey>(blsToExecutionChange.FROM_BLS_PUBKEY)))
      -- let domain = $compute_domain($DOMAIN_BLS_TO_EXECUTION_CHANGE, ?(), ?(state.GENESIS_VALIDATORS_ROOT))
      -- let root_sign = $compute_signing_root_bls_to_execution_change(blsToExecutionChange, domain)
      -- if ($bls_verify(blsToExecutionChange.FROM_BLS_PUBKEY, root_sign, signedBlsToExecutionChange.SIGNATURE) = true)
      -- let bytes32_new_wc = $make_withdrawal_credentials_eth1(blsToExecutionChange.TO_EXECUTION_ADDRESS)

;; spec/spec_deneb/13.1-process-operations-function.spectec:298:1-300:20:
relation ProcessBlsToExecutionChanges: beaconState signedBlsToExecutionChange* ~> beaconState

   ;; spec/spec_deneb/13.1-process-operations-function.spectec:302:1-303:21:
   rule nil: state signedBlsToExecutionChange*{signedBlsToExecutionChange <- signedBlsToExecutionChange*} ~> state
      -- if signedBlsToExecutionChange*{signedBlsToExecutionChange <- signedBlsToExecutionChange*} matches []

   ;; spec/spec_deneb/13.1-process-operations-function.spectec:304:1-307:85:
   rule cons: state signedBlsToExecutionChange*{signedBlsToExecutionChange <- signedBlsToExecutionChange*} ~> state_t
      -- if signedBlsToExecutionChange*{signedBlsToExecutionChange <- signedBlsToExecutionChange*} matches _ :: _
      -- let signedBlsToExecutionChange_h :: signedBlsToExecutionChange_t*{signedBlsToExecutionChange_t <- signedBlsToExecutionChange_t*} = signedBlsToExecutionChange*{signedBlsToExecutionChange <- signedBlsToExecutionChange*}
      -- rel ProcessBlsToExecutionChange: state signedBlsToExecutionChange_h ~> state_h
      -- rel ProcessBlsToExecutionChanges: state_h signedBlsToExecutionChange_t*{signedBlsToExecutionChange_t <- signedBlsToExecutionChange_t*} ~> state_t

;; spec/spec_deneb/13.2-process-block-function.spectec:7:1-9:20:
relation ProcessBlockHeader: beaconState beaconBlock ~> beaconState

   ;; spec/spec_deneb/13.2-process-block-function.spectec:11:1-30:56:
   rule : state block ~> state[LATEST_BLOCK_HEADER = beaconBlockHeader_new]
      -- if (block.SLOT = state.SLOT)
      -- if (state.LATEST_BLOCK_HEADER.SLOT < block.SLOT)
      -- if ($get_beacon_proposer_index(state) = block.PROPOSER_INDEX)
      -- if (block.PARENT_ROOT = $hash_tree_root_beaconBlockHeader(state.LATEST_BLOCK_HEADER))
      -- let beaconBlockHeader_new = {SLOT block.SLOT, PROPOSER_INDEX block.PROPOSER_INDEX, PARENT_ROOT block.PARENT_ROOT, STATE_ROOT $ZERO_ROOT, BODY_ROOT $hash_tree_root_beaconBlockBody(block.BODY)}
      -- if (block.PROPOSER_INDEX < |state.VALIDATORS|)   ;; [ins:bounds]
      -- if ~state.VALIDATORS[block.PROPOSER_INDEX].SLASHED

;; spec/spec_deneb/13.2-process-block-function.spectec:36:1-38:20:
relation ProcessWithdrawals: beaconState executionPayload ~> beaconState

   ;; spec/spec_deneb/13.2-process-block-function.spectec:41:1-52:97:
   rule len0: state executionPayload ~> state_after_debits[NEXT_WITHDRAWAL_VALIDATOR_INDEX = vid_next]
      -- let withdrawal_expected*{withdrawal_expected <- withdrawal_expected*} = $get_expected_withdrawals(state)
      -- if (executionPayload.WITHDRAWALS = withdrawal_expected*{withdrawal_expected <- withdrawal_expected*})
      -- rel ApplyWithdrawals: state .BALANCES{ withdrawal_expected*{withdrawal_expected <- withdrawal_expected*} }~>* state_after_debits
      -- if (|withdrawal_expected*{withdrawal_expected <- withdrawal_expected*}| = 0)
      -- let vid_next = ((state_after_debits.NEXT_WITHDRAWAL_VALIDATOR_INDEX + $MAX_VALIDATORS_PER_WITHDRAWALS_SWEEP) \ |state_after_debits.VALIDATORS|)

   ;; spec/spec_deneb/13.2-process-block-function.spectec:55:1-69:98:
   rule lenMax: state executionPayload ~> state_after_debits[NEXT_WITHDRAWAL_INDEX = withdrawalIndex_next][NEXT_WITHDRAWAL_VALIDATOR_INDEX = vid_next]
      -- let withdrawal_expected*{withdrawal_expected <- withdrawal_expected*} = $get_expected_withdrawals(state)
      -- if (executionPayload.WITHDRAWALS = withdrawal_expected*{withdrawal_expected <- withdrawal_expected*})
      -- rel ApplyWithdrawals: state .BALANCES{ withdrawal_expected*{withdrawal_expected <- withdrawal_expected*} }~>* state_after_debits
      -- if (|withdrawal_expected*{withdrawal_expected <- withdrawal_expected*}| = $MAX_WITHDRAWALS_PER_PAYLOAD)
      -- let withdrawal_latest = withdrawal_expected*{withdrawal_expected <- withdrawal_expected*}[(|withdrawal_expected*{withdrawal_expected <- withdrawal_expected*}| - 1)]
      -- let withdrawalIndex_next = (withdrawal_latest.INDEX + 1)
      -- let vid_next = ((withdrawal_latest.VALIDATOR_INDEX + 1) \ |state_after_debits.VALIDATORS|)

   ;; spec/spec_deneb/13.2-process-block-function.spectec:72:1-88:97:
   rule lenPartial: state executionPayload ~> state_after_debits[NEXT_WITHDRAWAL_INDEX = withdrawalIndex_next][NEXT_WITHDRAWAL_VALIDATOR_INDEX = vid_next]
      -- let withdrawal_expected*{withdrawal_expected <- withdrawal_expected*} = $get_expected_withdrawals(state)
      -- if (executionPayload.WITHDRAWALS = withdrawal_expected*{withdrawal_expected <- withdrawal_expected*})
      -- rel ApplyWithdrawals: state .BALANCES{ withdrawal_expected*{withdrawal_expected <- withdrawal_expected*} }~>* state_after_debits
      -- if (|withdrawal_expected*{withdrawal_expected <- withdrawal_expected*}| =/= 0)
      -- if (|withdrawal_expected*{withdrawal_expected <- withdrawal_expected*}| =/= $MAX_WITHDRAWALS_PER_PAYLOAD)
      -- let withdrawal_latest = withdrawal_expected*{withdrawal_expected <- withdrawal_expected*}[(|withdrawal_expected*{withdrawal_expected <- withdrawal_expected*}| - 1)]
      -- let withdrawalIndex_next = (withdrawal_latest.INDEX + 1)
      -- let vid_next = ((state_after_debits.NEXT_WITHDRAWAL_VALIDATOR_INDEX + $MAX_VALIDATORS_PER_WITHDRAWALS_SWEEP) \ |state_after_debits.VALIDATORS|)

;; spec/spec_deneb/13.2-process-block-function.spectec:95:1-97:20:
relation ProcessExecutionPayload: beaconState beaconBlockBody ~> beaconState

   ;; spec/spec_deneb/13.2-process-block-function.spectec:99:1-130:63:
   rule main: state body ~> state[LATEST_EXECUTION_PAYLOAD_HEADER = executionPayloadHeader]
      -- let executionPayload = body.EXECUTION_PAYLOAD
      -- if (executionPayload.PARENT_HASH = state.LATEST_EXECUTION_PAYLOAD_HEADER.BLOCK_HASH)
      -- if (executionPayload.PREV_RANDAO = $get_randao_mix(state, $get_current_epoch(state)))
      -- if (executionPayload.TIMESTAMP = $compute_time_at_slot(state, state.SLOT))
      -- if (|body.BLOB_KZG_COMMITMENTS| <= $MAX_BLOBS_PER_BLOCK)
      -- if $ee_verify_and_notify_new_payload(executionPayload)
      -- let executionPayloadHeader = {PARENT_HASH executionPayload.PARENT_HASH, FEE_RECIPIENT executionPayload.FEE_RECIPIENT, STATE_ROOT executionPayload.STATE_ROOT, RECEIPTS_ROOT executionPayload.RECEIPTS_ROOT, LOGS_BLOOM executionPayload.LOGS_BLOOM, PREV_RANDAO executionPayload.PREV_RANDAO, BLOCK_NUMBER executionPayload.BLOCK_NUMBER, GAS_LIMIT executionPayload.GAS_LIMIT, GAS_USED executionPayload.GAS_USED, TIMESTAMP executionPayload.TIMESTAMP, EXTRA_DATA executionPayload.EXTRA_DATA, BASE_FEE_PER_GAS executionPayload.BASE_FEE_PER_GAS, BLOCK_HASH executionPayload.BLOCK_HASH, TRANSACTIONS_ROOT $hash_tree_root_tx(executionPayload.TRANSACTIONS), WITHDRAWALS_ROOT $hash_tree_root_withdrawals(executionPayload.WITHDRAWALS), BLOB_GAS_USED executionPayload.BLOB_GAS_USED, EXCESS_BLOB_GAS executionPayload.EXCESS_BLOB_GAS}

;; spec/spec_deneb/13.2-process-block-function.spectec:136:1-138:20:
relation ProcessRandao: beaconState beaconBlockBody ~> beaconState

   ;; spec/spec_deneb/13.2-process-block-function.spectec:140:1-154:60:
   rule : state body ~> state[RANDAO_MIXES[uint64_n] = bytes32_mix_new]
      -- let epoch = $get_current_epoch(state)
      -- let vid_proposer = $get_beacon_proposer_index(state)
      -- if (vid_proposer < |state.VALIDATORS|)   ;; [ins:bounds]
      -- let validator_proposer = state.VALIDATORS[vid_proposer]
      -- let domain_randao = $get_domain(state, $DOMAIN_RANDAO, ?())
      -- let root_signing = $compute_signing_root_epoch(epoch, domain_randao)
      -- if $bls_verify(validator_proposer.PUBKEY, root_signing, body.RANDAO_REVEAL)
      -- let bytes32_mix_old = $get_randao_mix(state, epoch)
      -- let bytes32_hash_reveal = $hash_<blsSignature>(body.RANDAO_REVEAL)
      -- let bytes32_mix_new = $xor(bytes32_mix_old, bytes32_hash_reveal)
      -- let uint64_n = (epoch \ $EPOCHS_PER_HISTORICAL_VECTOR)

;; spec/spec_deneb/13.2-process-block-function.spectec:160:1-162:20:
relation ProcessEth1Data: beaconState beaconBlockBody ~> beaconState

   ;; spec/spec_deneb/13.2-process-block-function.spectec:164:1-169:73:
   rule majority: state body ~> state[ETH1_DATA_VOTES = eth1Data_update*{eth1Data_update <- eth1Data_update*}][ETH1_DATA = body.ETH1_DATA]
      -- let eth1Data_update*{eth1Data_update <- eth1Data_update*} = state.ETH1_DATA_VOTES ++ [body.ETH1_DATA]
      -- let n_occ = $count_occurrences_<eth1Data>(eth1Data_update*{eth1Data_update <- eth1Data_update*}, body.ETH1_DATA)
      -- if ((n_occ * 2) > ($EPOCHS_PER_ETH1_VOTING_PERIOD * $SLOTS_PER_EPOCH))

   ;; spec/spec_deneb/13.2-process-block-function.spectec:171:1-176:74:
   rule accumulate: state body ~> state[ETH1_DATA_VOTES = eth1Data_update*{eth1Data_update <- eth1Data_update*}]
      -- let eth1Data_update*{eth1Data_update <- eth1Data_update*} = state.ETH1_DATA_VOTES ++ [body.ETH1_DATA]
      -- let n_occ = $count_occurrences_<eth1Data>(eth1Data_update*{eth1Data_update <- eth1Data_update*}, body.ETH1_DATA)
      -- if ((n_occ * 2) <= ($EPOCHS_PER_ETH1_VOTING_PERIOD * $SLOTS_PER_EPOCH))

;; spec/spec_deneb/13.2-process-block-function.spectec:181:1-183:20:
relation ProcessOperations: beaconState beaconBlockBody ~> beaconState

   ;; spec/spec_deneb/13.2-process-block-function.spectec:185:1-198:92:
   rule : state body ~> state_out
      -- if (state.ETH1_DEPOSIT_INDEX <= state.ETH1_DATA.DEPOSIT_COUNT)   ;; [ins:underflow]
      -- if (|body.DEPOSITS| = $min_uint64($MAX_DEPOSITS, (state.ETH1_DATA.DEPOSIT_COUNT - state.ETH1_DEPOSIT_INDEX)))
      -- rel ProcessProposerSlashings: state body.PROPOSER_SLASHINGS ~> state_ps
      -- rel ProcessAttesterSlashings: state_ps body.ATTESTER_SLASHINGS ~> state_as
      -- rel ProcessAttestations: state_as body.ATTESTATIONS ~> state_att
      -- rel ProcessDeposits: state_att body.DEPOSITS ~> state_dep
      -- rel ProcessVoluntaryExits: state_dep body.VOLUNTARY_EXITS ~> state_ve
      -- rel ProcessBlsToExecutionChanges: state_ve body.BLS_TO_EXECUTION_CHANGES ~> state_out

;; spec/spec_deneb/13.2-process-block-function.spectec:204:1-206:20:
relation ProcessSyncAggregate: beaconState syncAggregate ~> beaconState

   ;; spec/spec_deneb/13.2-process-block-function.spectec:208:1-246:27:
   rule : state syncAggregate ~> state_updated
      -- let blsPubkey_committee*{blsPubkey_committee <- blsPubkey_committee*} = state.CURRENT_SYNC_COMMITTEE.PUBKEYS
      -- let (i_committee, blsPubkey)*{blsPubkey <- blsPubkey*, i_committee <- i_committee*} = $enumerate_<blsPubkey>(blsPubkey_committee*{blsPubkey_committee <- blsPubkey_committee*})
      -- (if (blsPubkey = blsPubkey_committee))*{blsPubkey <- blsPubkey*, blsPubkey_committee <- blsPubkey_committee*}
      -- let (_nat, blsPubkey_participants)*{_nat <- _nat*, blsPubkey_participants <- blsPubkey_participants*} = $filter_list_2_<(nat, blsPubkey), boolean*>((i_committee, blsPubkey_committee)*{blsPubkey_committee <- blsPubkey_committee*, i_committee <- i_committee*}, syncAggregate.SYNC_COMMITTEE_BITS, $bit_is_one_en_blsPubkey)
      -- let slot_prev = $get_prev_slot(state.SLOT)
      -- let domain = $get_domain(state, $DOMAIN_SYNC_COMMITTEE, ?($compute_epoch_at_slot(slot_prev)))
      -- let root_sign = $compute_signing_root_block_root($get_block_root_at_slot(state, slot_prev), domain)
      -- if $eth_fast_aggregate_verify(blsPubkey_participants*{blsPubkey_participants <- blsPubkey_participants*}, root_sign, syncAggregate.SYNC_COMMITTEE_SIGNATURE)
      -- let uint64_total_incs = ($get_total_active_balance(state) / $EFFECTIVE_BALANCE_INCREMENT)
      -- let reward_total_base = ($get_base_reward_per_increment(state) * uint64_total_incs)
      -- let reward_max_participant = (((reward_total_base * $SYNC_REWARD_WEIGHT) / $WEIGHT_DENOMINATOR) / $SLOTS_PER_EPOCH)
      -- let reward_participant = (reward_max_participant / $SYNC_COMMITTEE_SIZE)
      -- let reward_proposer = ((reward_participant * $PROPOSER_WEIGHT) / ($WEIGHT_DENOMINATOR - $PROPOSER_WEIGHT))
      -- let (vid, validator)*{validator <- validator*, vid <- vid*} = $enumerate_<validator>(state.VALIDATORS)
      -- (let blsPubkey_existing = validator.PUBKEY)*{blsPubkey_existing <- blsPubkey_existing*, validator <- validator*}
      -- if (state.CURRENT_SYNC_COMMITTEE.PUBKEYS = blsPubkey_committee*{blsPubkey_committee <- blsPubkey_committee*})
      -- (let vid_committee = $index_of_pubkey((vid, blsPubkey_existing)*{blsPubkey_existing <- blsPubkey_existing*, vid <- vid*}, blsPubkey_committee))*{blsPubkey_committee <- blsPubkey_committee*, vid_committee <- vid_committee*}
      -- let boolean_participation*{boolean_participation <- boolean_participation*} = syncAggregate.SYNC_COMMITTEE_BITS
      -- let vid_proposer = $get_beacon_proposer_index(state)
      -- rel ApplyReward_over_participants: state PARTICIPANT boolean_participation*{boolean_participation <- boolean_participation*} [ vid_committee*{vid_committee <- vid_committee*} ]+ reward_participant PROPOSER[ vid_proposer ]+ reward_proposer ~> state_updated

;; spec/spec_deneb/13.3-process-block.spectec:3:1-5:20:
relation ProcessBlock: beaconState beaconBlock ~>* beaconState

   ;; spec/spec_deneb/13.3-process-block.spectec:7:1-22:94:
   rule : state block ~>* state_6
      -- rel ProcessBlockHeader: state block ~> state_0
      -- rel ProcessWithdrawals: state_0 block.BODY.EXECUTION_PAYLOAD ~> state_1
      -- rel ProcessExecutionPayload: state_1 block.BODY ~> state_2
      -- rel ProcessRandao: state_2 block.BODY ~> state_3
      -- rel ProcessEth1Data: state_3 block.BODY ~> state_4
      -- rel ProcessOperations: state_4 block.BODY ~> state_5
      -- rel ProcessSyncAggregate: state_5 block.BODY.SYNC_AGGREGATE ~> state_6

;; spec/spec_deneb/14-state-transition.spectec:3:1-5:23:
relation State_transition: beaconState signedBeaconBlock boolean ~>* beaconState

   ;; spec/spec_deneb/14-state-transition.spectec:8:1-17:76:
   rule validate: state signedBeaconBlock bool ~>* state_next
      -- if (bool = true)
      -- let beaconBlock = signedBeaconBlock.MESSAGE
      -- rel ProcessSlots: state beaconBlock.SLOT ~> state_cur
      -- if $verify_block_signature(state_cur, signedBeaconBlock)
      -- rel ProcessBlock: state_cur beaconBlock ~>* state_next
      -- if (beaconBlock.STATE_ROOT = $hash_tree_root_beaconState(state_next))

   ;; spec/spec_deneb/14-state-transition.spectec:20:1-25:56:
   rule skip-validate: state signedBeaconBlock bool ~>* state_next
      -- if (bool = false)
      -- let beaconBlock = signedBeaconBlock.MESSAGE
      -- rel ProcessSlots: state beaconBlock.SLOT ~> state_cur
      -- rel ProcessBlock: state_cur beaconBlock ~>* state_next
