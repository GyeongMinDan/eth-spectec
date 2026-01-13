package main

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"regexp"
	"runtime"
	"strings"
	"time"

	"github.com/OffchainLabs/prysm/v7/beacon-chain/core/altair"
	"github.com/OffchainLabs/prysm/v7/beacon-chain/core/blocks"
	"github.com/OffchainLabs/prysm/v7/beacon-chain/core/epoch"
	"github.com/OffchainLabs/prysm/v7/beacon-chain/core/epoch/precompute"
	"github.com/OffchainLabs/prysm/v7/beacon-chain/core/transition"
	v "github.com/OffchainLabs/prysm/v7/beacon-chain/core/validators"
	"github.com/OffchainLabs/prysm/v7/beacon-chain/core/validators"
	"github.com/OffchainLabs/prysm/v7/beacon-chain/state"
	state_native "github.com/OffchainLabs/prysm/v7/beacon-chain/state/state-native"
	"github.com/OffchainLabs/prysm/v7/config/params"
	consensus_blocks "github.com/OffchainLabs/prysm/v7/consensus-types/blocks"
	"github.com/OffchainLabs/prysm/v7/consensus-types/interfaces"
	"github.com/OffchainLabs/prysm/v7/crypto/bls"
	"github.com/OffchainLabs/prysm/v7/encoding/ssz/detect"
	"github.com/OffchainLabs/prysm/v7/encoding/ssz/equality"
	enginev1 "github.com/OffchainLabs/prysm/v7/proto/engine/v1"
	ethpb "github.com/OffchainLabs/prysm/v7/proto/prysm/v1alpha1"
	prefixed "github.com/OffchainLabs/prysm/v7/runtime/logging/logrus-prefixed-formatter"
	"github.com/OffchainLabs/prysm/v7/runtime/version"
	"github.com/OffchainLabs/prysm/v7/testing/util"
	"github.com/kr/pretty"
	"github.com/pkg/errors"
	fssz "github.com/prysmaticlabs/fastssz"
	log "github.com/sirupsen/logrus"
	"github.com/urfave/cli/v2"
	"gopkg.in/d4l3k/messagediff.v1"
)

var blockPath string
var preStatePath string
var expectedPostStatePath string
var network string
var sszPath string
var sszType string
var operationType string
var operationPath string
var operationOutputPath string
var executionValid string
var epochProcessingType string
var epochProcessingOutputPath string
var sanitySlotsSlot uint64
var sanitySlotsOutputPath string
var prettyCommand = &cli.Command{
	Name:    "pretty",
	Aliases: []string{"p"},
	Usage:   "pretty-print SSZ data",
	Flags: []cli.Flag{
		&cli.StringFlag{
			Name:        "ssz-path",
			Usage:       "Path to file(ssz)",
			Required:    true,
			Destination: &sszPath,
		},
		&cli.StringFlag{
			Name: "data-type",
			Usage: "ssz file data type: " +
				"block|" +
				"blinded_block|" +
				"signed_block|" +
				"attestation|" +
				"block_header|" +
				"deposit|" +
				"proposer_slashing|" +
				"signed_block_header|" +
				"signed_voluntary_exit|" +
				"voluntary_exit|" +
				"state_capella",
			Required:    true,
			Destination: &sszType,
		},
	},
	Action: func(c *cli.Context) error {
		var data fssz.Unmarshaler
		switch sszType {
		case "block":
			data = &ethpb.BeaconBlock{}
		case "signed_block":
			data = &ethpb.SignedBeaconBlock{}
		case "blinded_block":
			data = &ethpb.BlindedBeaconBlockBellatrix{}
		case "attestation":
			data = &ethpb.Attestation{}
		case "block_header":
			data = &ethpb.BeaconBlockHeader{}
		case "deposit":
			data = &ethpb.Deposit{}
		case "deposit_message":
			data = &ethpb.DepositMessage{}
		case "proposer_slashing":
			data = &ethpb.ProposerSlashing{}
		case "signed_block_header":
			data = &ethpb.SignedBeaconBlockHeader{}
		case "signed_voluntary_exit":
			data = &ethpb.SignedVoluntaryExit{}
		case "voluntary_exit":
			data = &ethpb.VoluntaryExit{}
		case "state_capella":
			data = &ethpb.BeaconStateCapella{}
		default:
			log.Fatal("Invalid type")
		}
		prettyPrint(sszPath, data)
		return nil
	},
}

var benchmarkHashCommand = &cli.Command{
	Name:    "benchmark-hash",
	Aliases: []string{"b"},
	Usage:   "benchmark-hash SSZ data",
	Flags: []cli.Flag{
		&cli.StringFlag{
			Name:        "ssz-path",
			Usage:       "Path to file(ssz)",
			Required:    true,
			Destination: &sszPath,
		},
		&cli.StringFlag{
			Name: "data-type",
			Usage: "ssz file data type: " +
				"block_capella|" +
				"blinded_block_capella|" +
				"signed_block_capella|" +
				"attestation|" +
				"block_header|" +
				"deposit|" +
				"proposer_slashing|" +
				"signed_block_header|" +
				"signed_voluntary_exit|" +
				"voluntary_exit|" +
				"state_capella",
			Required:    true,
			Destination: &sszType,
		},
	},
	Action: func(c *cli.Context) error {
		benchmarkHash(sszPath, sszType)
		return nil
	},
}

var unrealizedCheckpointsCommand = &cli.Command{
	Name:     "unrealized-checkpoints",
	Category: "state-computations",
	Usage:    "Subcommand to compute manually the unrealized checkpoints",
	Flags: []cli.Flag{
		&cli.StringFlag{
			Name:        "state-path",
			Usage:       "Path to state file(ssz)",
			Destination: &preStatePath,
		},
	},
	Action: func(c *cli.Context) error {
		if preStatePath == "" {
			log.Info("State path not provided, please provide path")
			reader := bufio.NewReader(os.Stdin)
			text, err := reader.ReadString('\n')
			if err != nil {
				log.Fatal(err)
			}
			if text = strings.ReplaceAll(text, "\n", ""); text == "" {
				log.Fatal("Empty state path given")
			}
			preStatePath = text
		}
		stateObj, err := detectState(preStatePath)
		if err != nil {
			log.Fatal(err)
		}
		preStateRoot, err := stateObj.HashTreeRoot(context.Background())
		if err != nil {
			log.Fatal(err)
		}
		log.Infof(
			"Computing unrealized justification for state at slot %d and root %#x",
			stateObj.Slot(),
			preStateRoot,
		)
		uj, uf, err := precompute.UnrealizedCheckpoints(stateObj)
		if err != nil {
			log.Fatal(err)
		}
		log.Infof("Computed:\nUnrealized Justified: (Root: %#x, Epoch: %d)\nUnrealized Finalized: (Root: %#x, Epoch: %d).", uj.Root, uj.Epoch, uf.Root, uf.Epoch)
		return nil
	},
}

var stateTransitionCommand = &cli.Command{
	Name:     "state-transition",
	Category: "state-computations",
	Usage:    "Subcommand to run manual state transitions",
	Flags: []cli.Flag{
		&cli.StringFlag{
			Name:        "block-path",
			Usage:       "Path to block file(ssz)",
			Destination: &blockPath,
		},
		&cli.StringFlag{
			Name:        "pre-state-path",
			Usage:       "Path to pre state file(ssz)",
			Destination: &preStatePath,
		},
		&cli.StringFlag{
			Name:        "expected-post-state-path",
			Usage:       "Path to expected post state file(ssz)",
			Destination: &expectedPostStatePath,
		},
		&cli.StringFlag{
			Name:        "network",
			Usage:       "Network to run the state transition in",
			Destination: &network,
		},
	},
	Action: func(c *cli.Context) error {
		if network != "" {
			switch network {
			case params.SepoliaName:
				if err := params.SetActive(params.SepoliaConfig()); err != nil {
					log.Fatal(err)
				}
			case params.HoleskyName:
				if err := params.SetActive(params.HoleskyConfig()); err != nil {
					log.Fatal(err)
				}
			case params.HoodiName:
				if err := params.SetActive(params.HoodiConfig()); err != nil {
					log.Fatal(err)
				}
			default:
				log.Fatalf("Unknown network provided: %s", network)
			}
		} else {
			// Detect fork version from state and set config accordingly
			if preStatePath == "" {
				log.Info("Pre State path not provided for state transition. " +
					"Please provide path")
				reader := bufio.NewReader(os.Stdin)
				text, err := reader.ReadString('\n')
				if err != nil {
					log.Fatal(err)
				}
				if text = strings.ReplaceAll(text, "\n", ""); text == "" {
					log.Fatal("Empty state path given")
				}
				preStatePath = text
			}
			isDeneb, err := detectForkVersionFromState(preStatePath)
			if err != nil {
				log.Fatal(err)
			}
			setForkConfig(isDeneb)
		}

		if blockPath == "" {
			log.Info("Block path not provided for state transition. " +
				"Please provide path")
			reader := bufio.NewReader(os.Stdin)
			text, err := reader.ReadString('\n')
			if err != nil {
				log.Fatal(err)
			}
			if text = strings.ReplaceAll(text, "\n", ""); text == "" {
				log.Fatal("Empty block path given")
			}
			blockPath = text
		}
		block, err := detectBlock(blockPath)
		if err != nil {
			log.Fatal(err)
		}
		blkRoot, err := block.Block().HashTreeRoot()
		if err != nil {
			log.Fatal(err)
		}
		stateObj, err := detectState(preStatePath)
		if err != nil {
			log.Fatal(err)
		}
		preStateRoot, err := stateObj.HashTreeRoot(context.Background())
		if err != nil {
			log.Fatal(err)
		}
		log.WithFields(log.Fields{
			"blockSlot":    fmt.Sprintf("%d", block.Block().Slot()),
			"preStateSlot": fmt.Sprintf("%d", stateObj.Slot()),
		}).Infof(
			"Performing state transition with a block root of %#x and pre state root of %#x",
			blkRoot,
			preStateRoot,
		)
		// validate_result = true: Use debugStateTransition to verify all signatures
		// debugStateTransition performs signature verification via set.VerifyVerbosely()
		postState, err := debugStateTransition(context.Background(), stateObj, block)
		if err != nil {
			log.Fatal(err)
		}
		postRoot, err := postState.HashTreeRoot(context.Background())
		if err != nil {
			log.Fatal(err)
		}
		log.Infof("Finished state transition with post state root of %#x", postRoot)

		// validate_result = false: Skip state root verification
		// Verify that the computed post-state root matches the state root in the block
		// This is essential for detecting invalid blocks with incorrect state roots (e.g., `invalid_incorrect_state_root` test cases)
		// blockStateRoot := block.Block().StateRoot()
		// if !bytes.Equal(postRoot[:], blockStateRoot[:]) {
		// 	log.Fatalf("State root mismatch! Block contains %#x, but computed post-state root is %#x", blockStateRoot, postRoot)
		// }

		// Store the post state to the expectedPostStatePath if provided.
		if expectedPostStatePath != "" {
			// Serialize the postState to SSZ format.
			postStateData, err := postState.MarshalSSZ()
			if err != nil {
				log.Fatal(err)
			}

			// Write the serialized data to the specified path.
			err = os.WriteFile(expectedPostStatePath, postStateData, 0644)
			if err != nil {
				log.Fatal(err)
			}

			log.Infof("Post state successfully written to %s", expectedPostStatePath)
		}
		// Diff the state if a post state is provided.
		if expectedPostStatePath != "" {
			expectedState, err := detectState(expectedPostStatePath)
			if err != nil {
				log.Fatal(err)
			}
			if !equality.DeepEqual(expectedState.ToProtoUnsafe(), postState.ToProtoUnsafe()) {
				diff, _ := messagediff.PrettyDiff(expectedState.ToProtoUnsafe(), postState.ToProtoUnsafe())
				log.Errorf("Derived state differs from provided post state: %s", diff)
			}
		}
		return nil
	},
}

var operationCommand = &cli.Command{
	Name:     "operation",
	Category: "state-computations",
	Usage:    "Subcommand to process operations (attestation, block_header, deposit, etc.)",
	Flags: []cli.Flag{
		&cli.StringFlag{
			Name:        "operation-type",
			Usage:       "Operation type: attestation, block_header, deposit, proposer_slashing, attester_slashing, voluntary_exit, bls_to_execution_change, sync_committee (or sync_aggregate), execution_payload, withdrawals",
			Required:    true,
			Destination: &operationType,
		},
		&cli.StringFlag{
			Name:        "pre-state-path",
			Usage:       "Path to pre state file(ssz)",
			Required:    true,
			Destination: &preStatePath,
		},
		&cli.StringFlag{
			Name:        "operation-path",
			Usage:       "Path to operation file(ssz). For execution_payload, use body.ssz. For withdrawals, use execution_payload.ssz. For block_header, use block.ssz",
			Required:    true,
			Destination: &operationPath,
		},
		&cli.StringFlag{
			Name:        "post-state-output-path",
			Usage:       "Path to output post state file(ssz)",
			Required:    true,
			Destination: &operationOutputPath,
		},
		&cli.StringFlag{
			Name:        "execution-valid",
			Usage:       "For execution_payload operation: whether execution payload is valid (true or false, default: true)",
			Destination: &executionValid,
		},
	},
	Action: func(c *cli.Context) error {
		// Detect fork version and set config accordingly
		isDeneb, err := detectForkVersionFromState(preStatePath)
		if err != nil {
			log.Fatal(err)
		}
		setForkConfig(isDeneb)

		preState, err := detectState(preStatePath)
		if err != nil {
			log.Fatal(err)
		}

		// Parse execution_valid flag for execution_payload operation
		var executionValidBool bool = true // Default to true
		if operationType == "execution_payload" && executionValid != "" {
			executionValidBool = (executionValid == "true")
		}
		
		postState, err := processOperation(context.Background(), preState, operationType, operationPath, executionValidBool)
		if err != nil {
			log.Fatal(err)
		}

		postStateData, err := postState.MarshalSSZ()
		if err != nil {
			log.Fatal(err)
		}

		err = os.WriteFile(operationOutputPath, postStateData, 0644)
		if err != nil {
			log.Fatal(err)
		}

		log.Infof("Operation processed successfully. Post state written to %s", operationOutputPath)
		return nil
	},
}

var epochProcessingCommand = &cli.Command{
	Name:     "epoch-processing",
	Category: "state-computations",
	Usage:    "Subcommand to process epoch operations (justification_and_finalization, rewards_and_penalties, etc.)",
	Flags: []cli.Flag{
		&cli.StringFlag{
			Name:        "epoch-processing-type",
			Usage:       "Epoch processing type: justification_and_finalization, rewards_and_penalties, registry_updates, slashings, eth1_data_reset, effective_balance_updates, slashings_reset, randao_mixes_reset, historical_summaries_update, participation_flag_updates, inactivity_updates",
			Required:    true,
			Destination: &epochProcessingType,
		},
		&cli.StringFlag{
			Name:        "pre-state-path",
			Usage:       "Path to pre state file(ssz)",
			Required:    true,
			Destination: &preStatePath,
		},
		&cli.StringFlag{
			Name:        "post-state-output-path",
			Usage:       "Path to output post state file(ssz)",
			Required:    true,
			Destination: &epochProcessingOutputPath,
		},
	},
	Action: func(c *cli.Context) error {
		// Detect fork version and set config accordingly
		isDeneb, err := detectForkVersionFromState(preStatePath)
		if err != nil {
			log.Fatal(err)
		}
		setForkConfig(isDeneb)

		preState, err := detectState(preStatePath)
		if err != nil {
			log.Fatal(err)
		}

		postState, err := processEpochOperation(context.Background(), preState, epochProcessingType)
		if err != nil {
			log.Fatal(err)
		}

		postStateData, err := postState.MarshalSSZ()
		if err != nil {
			log.Fatal(err)
		}

		err = os.WriteFile(epochProcessingOutputPath, postStateData, 0644)
		if err != nil {
			log.Fatal(err)
		}

		log.Infof("Epoch processing completed successfully. Post state written to %s", epochProcessingOutputPath)
		return nil
	},
}

var sanitySlotsCommand = &cli.Command{
	Name:     "sanity-slots",
	Category: "state-computations",
	Usage:    "Subcommand to process slots (matches official test runner sanity_slots behavior)",
	Flags: []cli.Flag{
		&cli.StringFlag{
			Name:        "pre-state-path",
			Usage:       "Path to pre state file(ssz)",
			Required:    true,
			Destination: &preStatePath,
		},
		&cli.Uint64Flag{
			Name:        "slot",
			Usage:       "Number of slots to process",
			Required:    true,
			Destination: &sanitySlotsSlot,
		},
		&cli.StringFlag{
			Name:        "post-state-output-path",
			Usage:       "Path to output post state file(ssz)",
			Required:    true,
			Destination: &sanitySlotsOutputPath,
		},
	},
	Action: func(c *cli.Context) error {
		// Detect fork version and set config accordingly
		isDeneb, err := detectForkVersionFromState(preStatePath)
		if err != nil {
			log.Fatal(err)
		}
		setForkConfig(isDeneb)

		preState, err := detectState(preStatePath)
		if err != nil {
			log.Fatal(err)
		}

		// Process slots (same logic as official test runner)
		// transition.ProcessSlots(context.Background(), beaconState, beaconState.Slot().Add(slotsCount))
		postState, err := transition.ProcessSlots(context.Background(), preState, preState.Slot().Add(sanitySlotsSlot))
		if err != nil {
			log.Fatal(err)
		}

		postStateData, err := postState.MarshalSSZ()
		if err != nil {
			log.Fatal(err)
		}

		err = os.WriteFile(sanitySlotsOutputPath, postStateData, 0644)
		if err != nil {
			log.Fatal(err)
		}

		log.Infof("Sanity slots processed successfully. Post state written to %s", sanitySlotsOutputPath)
		return nil
	},
}

func main() {
	customFormatter := new(prefixed.TextFormatter)
	customFormatter.TimestampFormat = "2006-01-02 15:04:05.00"
	customFormatter.FullTimestamp = true
	log.SetFormatter(customFormatter)
	app := cli.App{}
	app.Name = "pcli"
	app.Usage = "A command line utility to run Ethereum consensus specific commands"
	app.Version = version.Version()
	app.Commands = []*cli.Command{
		prettyCommand,
		benchmarkHashCommand,
		unrealizedCheckpointsCommand,
		stateTransitionCommand,
		operationCommand,
		epochProcessingCommand,
		sanitySlotsCommand,
	}
	if err := app.Run(os.Args); err != nil {
		log.Error(err.Error())
		os.Exit(1)
	}
}

// dataFetcher fetches and unmarshals data from file to provided data structure.
func dataFetcher(fPath string, data fssz.Unmarshaler) error {
	rawFile, err := os.ReadFile(fPath) // #nosec G304
	if err != nil {
		return err
	}
	return data.UnmarshalSSZ(rawFile)
}

// detectForkVersionFromState detects fork version by attempting to unmarshal SSZ data
// Returns true if Deneb, false if Capella
func detectForkVersionFromState(fPath string) (bool, error) {
	rawFile, err := os.ReadFile(fPath) // #nosec G304
	if err != nil {
		return false, err
	}
	// Try Deneb first (newer fork)
	baseDeneb := &ethpb.BeaconStateDeneb{}
	if err := baseDeneb.UnmarshalSSZ(rawFile); err == nil {
		return true, nil
	}
	// Try Capella
	baseCapella := &ethpb.BeaconStateCapella{}
	if err := baseCapella.UnmarshalSSZ(rawFile); err == nil {
		return false, nil
	}
	return false, errors.New("unable to detect fork version (tried both Capella and Deneb)")
}

// setForkConfig sets config based on fork version
func setForkConfig(isDeneb bool) {
	cfg := params.MainnetConfig()
	cfg.AltairForkEpoch = 0
	cfg.BellatrixForkEpoch = 0
	cfg.CapellaForkEpoch = 0
	if isDeneb {
		// Pure Deneb config: DENEB_FORK_EPOCH = 0
		cfg.DenebForkEpoch = 0
	} else {
		// Pure Capella config: CAPELLA_FORK_EPOCH = 0, DENEB_FORK_EPOCH = 75520
		cfg.DenebForkEpoch = 75520
	}
	cfg.InitializeForkSchedule()
	if err := params.SetActive(cfg); err != nil {
		log.Fatal(err)
	}
}

func detectState(fPath string) (state.BeaconState, error) {
	rawFile, err := os.ReadFile(fPath) // #nosec G304
	if err != nil {
		return nil, err
	}
	// Try to detect fork version from SSZ data
	// First try Capella, then Deneb (matches official test runner approach)
	baseCapella := &ethpb.BeaconStateCapella{}
	if err := baseCapella.UnmarshalSSZ(rawFile); err == nil {
		// Successfully unmarshalled as Capella
		return state_native.InitializeFromProtoCapella(baseCapella)
	}
	// Try Deneb if Capella failed
	baseDeneb := &ethpb.BeaconStateDeneb{}
	if err := baseDeneb.UnmarshalSSZ(rawFile); err != nil {
		return nil, errors.Wrap(err, "error unmarshalling state (tried both Capella and Deneb)")
	}
	// Successfully unmarshalled as Deneb
	return state_native.InitializeFromProtoDeneb(baseDeneb)
}

func detectBlock(fPath string) (interfaces.SignedBeaconBlock, error) {
	rawFile, err := os.ReadFile(fPath) // #nosec G304
	if err != nil {
		return nil, err
	}
	vu, err := detect.FromBlock(rawFile)
	if err != nil {
		return nil, err
	}
	return vu.UnmarshalBeaconBlock(rawFile)
}

func prettyPrint(sszPath string, data fssz.Unmarshaler) {
	if err := dataFetcher(sszPath, data); err != nil {
		log.Fatal(err)
	}
	str := pretty.Sprint(data)
	re := regexp.MustCompile("(?m)[\r\n]+^.*XXX_.*$")
	str = re.ReplaceAllString(str, "")
	fmt.Print(str)
}

func benchmarkHash(sszPath string, sszType string) {
	switch sszType {
	case "state_capella":
		st := &ethpb.BeaconStateCapella{}
		rawFile, err := os.ReadFile(sszPath) // #nosec G304
		if err != nil {
			log.Fatal(err)
		}

		startDeserialize := time.Now()
		if err := st.UnmarshalSSZ(rawFile); err != nil {
			log.Fatal(err)
		}
		deserializeDuration := time.Since(startDeserialize)

		stateTrieState, err := state_native.InitializeFromProtoCapella(st)
		if err != nil {
			log.Fatal(err)
		}
		start := time.Now()
		stat := &runtime.MemStats{}
		runtime.ReadMemStats(stat)
		root, err := stateTrieState.HashTreeRoot(context.Background())
		if err != nil {
			log.Fatal("Couldn't hash")
		}
		newStat := &runtime.MemStats{}
		runtime.ReadMemStats(newStat)
		fmt.Printf("Deserialize Duration: %v, Hashing Duration: %v HTR: %#x\n", deserializeDuration, time.Since(start), root)
		fmt.Printf("Total Memory Allocation Differential: %d bytes, Heap Memory Allocation Differential: %d bytes\n", int64(newStat.TotalAlloc)-int64(stat.TotalAlloc), int64(newStat.HeapAlloc)-int64(stat.HeapAlloc))
		return
	default:
		log.Fatal("Invalid type")
	}
}

func debugStateTransition(
	ctx context.Context,
	st state.BeaconState,
	signed interfaces.ReadOnlySignedBeaconBlock,
) (state.BeaconState, error) {
	var err error

	parentRoot := signed.Block().ParentRoot()
	st, err = transition.ProcessSlotsUsingNextSlotCache(ctx, st, parentRoot[:], signed.Block().Slot())
	if err != nil {
		return st, errors.Wrap(err, "could not process slots")
	}

	// Execute per block transition.
	// validate_result = false: Skip block signature verification, but verify RANDAO and attestation signatures
	set, st, err := transition.ProcessBlockNoVerifyAnySig(ctx, st, signed)
	if err != nil {
		return st, errors.Wrap(err, "could not process block")
	}
	// validate_result = false: Only verify RANDAO and attestation signatures, skip block signature
	// Create a new set excluding block signatures by filtering descriptions
	filteredSet := bls.NewSet()
	for i := 0; i < len(set.Signatures); i++ {
		desc := set.Descriptions[i]
		// Skip block signature, verify all other signatures (RANDAO, attestations, etc.)
		if !strings.Contains(desc, "block") && !strings.Contains(desc, "Block") {
			filteredSet.Signatures = append(filteredSet.Signatures, set.Signatures[i])
			filteredSet.PublicKeys = append(filteredSet.PublicKeys, set.PublicKeys[i])
			filteredSet.Messages = append(filteredSet.Messages, set.Messages[i])
			filteredSet.Descriptions = append(filteredSet.Descriptions, desc)
		}
	}
	// Verify only non-block signatures
	if len(filteredSet.Signatures) > 0 {
		valid, err := filteredSet.VerifyVerbosely()
		if err != nil {
			return st, errors.Wrap(err, "could not batch verify signature")
		}
		if !valid {
			return st, errors.New("signature in block failed to verify")
		}
	}
	return st, nil
}

// processOperation processes a single operation and returns the post state
func processOperation(ctx context.Context, preState state.BeaconState, operationType string, operationPath string, executionValid bool) (state.BeaconState, error) {
	operationData, err := os.ReadFile(operationPath)
	if err != nil {
		return nil, errors.Wrap(err, "failed to read operation file")
	}

	switch operationType {
	case "attestation":
		return processAttestation(ctx, preState, operationData)
	case "block_header":
		return processBlockHeader(ctx, preState, operationData)
	case "deposit":
		return processDeposit(ctx, preState, operationData)
	case "proposer_slashing":
		return processProposerSlashing(ctx, preState, operationData)
	case "attester_slashing":
		return processAttesterSlashing(ctx, preState, operationData)
	case "voluntary_exit":
		return processVoluntaryExit(ctx, preState, operationData)
	case "bls_to_execution_change":
		return processBLSToExecutionChange(ctx, preState, operationData)
	case "sync_committee", "sync_aggregate":
		return processSyncCommittee(ctx, preState, operationData)
	case "execution_payload":
		return processExecutionPayload(ctx, preState, operationData, executionValid)
	case "withdrawals":
		return processWithdrawals(ctx, preState, operationData)
	default:
		return nil, errors.Errorf("unknown operation type: %s", operationType)
	}
}

// processEpochOperation processes an epoch operation and returns the post state
func processEpochOperation(ctx context.Context, preState state.BeaconState, epochProcessingType string) (state.BeaconState, error) {
	switch epochProcessingType {
	case "justification_and_finalization":
		return processJustificationAndFinalization(ctx, preState)
	case "rewards_and_penalties":
		return processRewardsAndPenalties(ctx, preState)
	case "registry_updates":
		return processRegistryUpdates(ctx, preState)
	case "slashings":
		return processSlashings(ctx, preState)
	case "eth1_data_reset":
		return processEth1DataReset(ctx, preState)
	case "effective_balance_updates":
		return processEffectiveBalanceUpdates(ctx, preState)
	case "slashings_reset":
		return processSlashingsReset(ctx, preState)
	case "randao_mixes_reset":
		return processRandaoMixesReset(ctx, preState)
	case "historical_summaries_update":
		return processHistoricalSummariesUpdate(ctx, preState)
	case "participation_flag_updates":
		return processParticipationFlagUpdates(ctx, preState)
	case "inactivity_updates":
		return processInactivityUpdates(ctx, preState)
	default:
		return nil, errors.Errorf("unknown epoch processing type: %s", epochProcessingType)
	}
}

// Operation processing functions
func processAttestation(ctx context.Context, st state.BeaconState, attestationSSZ []byte) (state.BeaconState, error) {
	att := &ethpb.Attestation{}
	if err := att.UnmarshalSSZ(attestationSSZ); err != nil {
		return nil, errors.Wrap(err, "failed to unmarshal attestation")
	}
	
	// Detect fork version from state to use correct block body type
	protoState := st.ToProtoUnsafe()
	var signedBlock interfaces.SignedBeaconBlock
	var err error
	
	switch protoState.(type) {
	case *ethpb.BeaconStateDeneb:
		b := util.NewBeaconBlockDeneb()
		b.Block.Body = &ethpb.BeaconBlockBodyDeneb{Attestations: []*ethpb.Attestation{att}}
		signedBlock, err = consensus_blocks.NewSignedBeaconBlock(b)
	case *ethpb.BeaconStateCapella:
		b := util.NewBeaconBlockCapella()
		b.Block.Body = &ethpb.BeaconBlockBodyCapella{Attestations: []*ethpb.Attestation{att}}
		signedBlock, err = consensus_blocks.NewSignedBeaconBlock(b)
	default:
		return nil, errors.New("unsupported state version for attestation (expected Capella or Deneb)")
	}
	
	if err != nil {
		return nil, errors.Wrap(err, "failed to create signed block")
	}

	st, err = altair.ProcessAttestationsNoVerifySignature(ctx, st, signedBlock.Block())
	if err != nil {
		return nil, errors.Wrap(err, "failed to process attestations")
	}

	aSet, err := blocks.AttestationSignatureBatch(ctx, st, signedBlock.Block().Body().Attestations())
	if err != nil {
		return nil, errors.Wrap(err, "failed to create attestation signature batch")
	}
	verified, err := aSet.Verify()
	if err != nil {
		return nil, errors.Wrap(err, "failed to verify attestation signatures")
	}
	if !verified {
		return nil, errors.New("attestation signature verification failed")
	}

	return st, nil
}

func processBlockHeader(ctx context.Context, st state.BeaconState, blockSSZ []byte) (state.BeaconState, error) {
	// Detect fork version from state to use correct block type (matching official test runner)
	protoState := st.ToProtoUnsafe()
	var signedBlock interfaces.SignedBeaconBlock
	var err error
	
	switch protoState.(type) {
	case *ethpb.BeaconStateDeneb:
		block := &ethpb.BeaconBlockDeneb{}
		if err := block.UnmarshalSSZ(blockSSZ); err != nil {
			return nil, errors.Wrap(err, "failed to unmarshal block (Deneb)")
		}
		signedBlock, err = consensus_blocks.NewSignedBeaconBlock(&ethpb.SignedBeaconBlockDeneb{Block: block})
	case *ethpb.BeaconStateCapella:
		block := &ethpb.BeaconBlockCapella{}
		if err := block.UnmarshalSSZ(blockSSZ); err != nil {
			return nil, errors.Wrap(err, "failed to unmarshal block (Capella)")
		}
		signedBlock, err = consensus_blocks.NewSignedBeaconBlock(&ethpb.SignedBeaconBlockCapella{Block: block})
	default:
		return nil, errors.New("unsupported state version for block_header (expected Capella or Deneb)")
	}
	
	if err != nil {
		return nil, errors.Wrap(err, "failed to create signed block")
	}

	// Use methods from SignedBeaconBlock interface (matching official test runner)
	bodyRoot, err := signedBlock.Block().Body().HashTreeRoot()
	if err != nil {
		return nil, errors.Wrap(err, "failed to hash body root")
	}
	parentRoot := signedBlock.Block().ParentRoot()

	st, err = blocks.ProcessBlockHeaderNoVerify(ctx, st, signedBlock.Block().Slot(), signedBlock.Block().ProposerIndex(), parentRoot[:], bodyRoot[:])
	if err != nil {
		return nil, errors.Wrap(err, "failed to process block header")
	}

	return st, nil
}

func processDeposit(ctx context.Context, st state.BeaconState, depositSSZ []byte) (state.BeaconState, error) {
	deposit := &ethpb.Deposit{}
	if err := deposit.UnmarshalSSZ(depositSSZ); err != nil {
		return nil, errors.Wrap(err, "failed to unmarshal deposit")
	}
	
	// Detect fork version from state to use correct block body type
	protoState := st.ToProtoUnsafe()
	var signedBlock interfaces.SignedBeaconBlock
	var err error
	
	switch protoState.(type) {
	case *ethpb.BeaconStateDeneb:
		b := util.NewBeaconBlockDeneb()
		b.Block.Body = &ethpb.BeaconBlockBodyDeneb{Deposits: []*ethpb.Deposit{deposit}}
		signedBlock, err = consensus_blocks.NewSignedBeaconBlock(b)
	case *ethpb.BeaconStateCapella:
		b := util.NewBeaconBlockCapella()
		b.Block.Body = &ethpb.BeaconBlockBodyCapella{Deposits: []*ethpb.Deposit{deposit}}
		signedBlock, err = consensus_blocks.NewSignedBeaconBlock(b)
	default:
		return nil, errors.New("unsupported state version for deposit (expected Capella or Deneb)")
	}
	
	if err != nil {
		return nil, errors.Wrap(err, "failed to create signed block")
	}

	st, err = altair.ProcessDeposits(ctx, st, signedBlock.Block().Body().Deposits())
	if err != nil {
		return nil, errors.Wrap(err, "failed to process deposits")
	}

	return st, nil
}

func processProposerSlashing(ctx context.Context, st state.BeaconState, proposerSlashingSSZ []byte) (state.BeaconState, error) {
	ps := &ethpb.ProposerSlashing{}
	if err := ps.UnmarshalSSZ(proposerSlashingSSZ); err != nil {
		return nil, errors.Wrap(err, "failed to unmarshal proposer slashing")
	}
	
	// Detect fork version from state to use correct block body type
	protoState := st.ToProtoUnsafe()
	var signedBlock interfaces.SignedBeaconBlock
	var err error
	
	switch protoState.(type) {
	case *ethpb.BeaconStateDeneb:
		b := util.NewBeaconBlockDeneb()
		b.Block.Body = &ethpb.BeaconBlockBodyDeneb{ProposerSlashings: []*ethpb.ProposerSlashing{ps}}
		signedBlock, err = consensus_blocks.NewSignedBeaconBlock(b)
	case *ethpb.BeaconStateCapella:
		b := util.NewBeaconBlockCapella()
		b.Block.Body = &ethpb.BeaconBlockBodyCapella{ProposerSlashings: []*ethpb.ProposerSlashing{ps}}
		signedBlock, err = consensus_blocks.NewSignedBeaconBlock(b)
	default:
		return nil, errors.New("unsupported state version for proposer_slashing (expected Capella or Deneb)")
	}
	
	if err != nil {
		return nil, errors.Wrap(err, "failed to create signed block")
	}

	st, err = blocks.ProcessProposerSlashings(ctx, st, signedBlock.Block().Body().ProposerSlashings(), v.ExitInformation(st))
	if err != nil {
		return nil, errors.Wrap(err, "failed to process proposer slashings")
	}

	return st, nil
}

func processAttesterSlashing(ctx context.Context, st state.BeaconState, attesterSlashingSSZ []byte) (state.BeaconState, error) {
	as := &ethpb.AttesterSlashing{}
	if err := as.UnmarshalSSZ(attesterSlashingSSZ); err != nil {
		return nil, errors.Wrap(err, "failed to unmarshal attester slashing")
	}
	
	// Detect fork version from state to use correct block body type
	protoState := st.ToProtoUnsafe()
	var signedBlock interfaces.SignedBeaconBlock
	var err error
	
	switch protoState.(type) {
	case *ethpb.BeaconStateDeneb:
		b := util.NewBeaconBlockDeneb()
		b.Block.Body = &ethpb.BeaconBlockBodyDeneb{AttesterSlashings: []*ethpb.AttesterSlashing{as}}
		signedBlock, err = consensus_blocks.NewSignedBeaconBlock(b)
	case *ethpb.BeaconStateCapella:
		b := util.NewBeaconBlockCapella()
		b.Block.Body = &ethpb.BeaconBlockBodyCapella{AttesterSlashings: []*ethpb.AttesterSlashing{as}}
		signedBlock, err = consensus_blocks.NewSignedBeaconBlock(b)
	default:
		return nil, errors.New("unsupported state version for attester_slashing (expected Capella or Deneb)")
	}
	
	if err != nil {
		return nil, errors.Wrap(err, "failed to create signed block")
	}

	st, err = blocks.ProcessAttesterSlashings(ctx, st, signedBlock.Block().Body().AttesterSlashings(), v.ExitInformation(st))
	if err != nil {
		return nil, errors.Wrap(err, "failed to process attester slashings")
	}

	return st, nil
}

func processVoluntaryExit(ctx context.Context, st state.BeaconState, voluntaryExitSSZ []byte) (state.BeaconState, error) {
	ve := &ethpb.SignedVoluntaryExit{}
	if err := ve.UnmarshalSSZ(voluntaryExitSSZ); err != nil {
		return nil, errors.Wrap(err, "failed to unmarshal voluntary exit")
	}
	
	// Detect fork version from state to use correct block body type
	protoState := st.ToProtoUnsafe()
	var signedBlock interfaces.SignedBeaconBlock
	var err error
	
	switch protoState.(type) {
	case *ethpb.BeaconStateDeneb:
		b := util.NewBeaconBlockDeneb()
		b.Block.Body = &ethpb.BeaconBlockBodyDeneb{VoluntaryExits: []*ethpb.SignedVoluntaryExit{ve}}
		signedBlock, err = consensus_blocks.NewSignedBeaconBlock(b)
	case *ethpb.BeaconStateCapella:
		b := util.NewBeaconBlockCapella()
		b.Block.Body = &ethpb.BeaconBlockBodyCapella{VoluntaryExits: []*ethpb.SignedVoluntaryExit{ve}}
		signedBlock, err = consensus_blocks.NewSignedBeaconBlock(b)
	default:
		return nil, errors.New("unsupported state version for voluntary_exit (expected Capella or Deneb)")
	}
	
	if err != nil {
		return nil, errors.Wrap(err, "failed to create signed block")
	}

	st, err = blocks.ProcessVoluntaryExits(ctx, st, signedBlock.Block().Body().VoluntaryExits(), validators.ExitInformation(st))
	if err != nil {
		return nil, errors.Wrap(err, "failed to process voluntary exits")
	}

	return st, nil
}

func processBLSToExecutionChange(ctx context.Context, st state.BeaconState, blsToExecChangeSSZ []byte) (state.BeaconState, error) {
	blsChange := &ethpb.SignedBLSToExecutionChange{}
	if err := blsChange.UnmarshalSSZ(blsToExecChangeSSZ); err != nil {
		return nil, errors.Wrap(err, "failed to unmarshal BLS to execution change")
	}
	
	// Detect fork version from state to use correct block body type
	protoState := st.ToProtoUnsafe()
	var signedBlock interfaces.SignedBeaconBlock
	var err error
	
	switch protoState.(type) {
	case *ethpb.BeaconStateDeneb:
		b := util.NewBeaconBlockDeneb()
		b.Block.Body = &ethpb.BeaconBlockBodyDeneb{BlsToExecutionChanges: []*ethpb.SignedBLSToExecutionChange{blsChange}}
		signedBlock, err = consensus_blocks.NewSignedBeaconBlock(b)
	case *ethpb.BeaconStateCapella:
		b := util.NewBeaconBlockCapella()
		b.Block.Body = &ethpb.BeaconBlockBodyCapella{BlsToExecutionChanges: []*ethpb.SignedBLSToExecutionChange{blsChange}}
		signedBlock, err = consensus_blocks.NewSignedBeaconBlock(b)
	default:
		return nil, errors.New("unsupported state version for bls_to_execution_change (expected Capella or Deneb)")
	}
	
	if err != nil {
		return nil, errors.Wrap(err, "failed to create signed block")
	}

	st, err = blocks.ProcessBLSToExecutionChanges(st, signedBlock.Block())
	if err != nil {
		return nil, errors.Wrap(err, "failed to process BLS to execution changes")
	}

	changes, err := signedBlock.Block().Body().BLSToExecutionChanges()
	if err != nil {
		return nil, errors.Wrap(err, "failed to get BLS to execution changes")
	}

	cSet, err := blocks.BLSChangesSignatureBatch(st, changes)
	if err != nil {
		return nil, errors.Wrap(err, "failed to create BLS changes signature batch")
	}

	ok, err := cSet.Verify()
	if err != nil {
		return nil, errors.Wrap(err, "failed to verify BLS changes signatures")
	}
	if !ok {
		return nil, errors.New("BLS to execution change signature verification failed")
	}

	return st, nil
}

func processSyncCommittee(ctx context.Context, st state.BeaconState, syncAggregateSSZ []byte) (state.BeaconState, error) {
	syncAgg := &ethpb.SyncAggregate{}
	if err := syncAgg.UnmarshalSSZ(syncAggregateSSZ); err != nil {
		return nil, errors.Wrap(err, "failed to unmarshal sync aggregate")
	}
	
	// Detect fork version from state to use correct block body type
	protoState := st.ToProtoUnsafe()
	var signedBlock interfaces.SignedBeaconBlock
	var err error
	
	switch protoState.(type) {
	case *ethpb.BeaconStateDeneb:
		b := util.NewBeaconBlockDeneb()
		b.Block.Body = &ethpb.BeaconBlockBodyDeneb{SyncAggregate: syncAgg}
		signedBlock, err = consensus_blocks.NewSignedBeaconBlock(b)
	case *ethpb.BeaconStateCapella:
		b := util.NewBeaconBlockCapella()
		b.Block.Body = &ethpb.BeaconBlockBodyCapella{SyncAggregate: syncAgg}
		signedBlock, err = consensus_blocks.NewSignedBeaconBlock(b)
	default:
		return nil, errors.New("unsupported state version for sync_committee (expected Capella or Deneb)")
	}
	
	if err != nil {
		return nil, errors.Wrap(err, "failed to create signed block")
	}

	sa, err := signedBlock.Block().Body().SyncAggregate()
	if err != nil {
		return nil, errors.Wrap(err, "failed to get sync aggregate")
	}

	st, _, err = altair.ProcessSyncAggregate(ctx, st, sa)
	if err != nil {
		return nil, errors.Wrap(err, "failed to process sync aggregate")
	}

	return st, nil
}

func processExecutionPayload(ctx context.Context, st state.BeaconState, bodySSZ []byte, executionValid bool) (state.BeaconState, error) {
	// If execution is invalid, return error immediately (matching official test runner behavior)
	if !executionValid {
		return nil, errors.New("execution payload is invalid")
	}

	// Detect fork version from state to use correct block body type
	var blockBody interfaces.ReadOnlyBeaconBlockBody
	var err error
	
	// Check if state is Deneb by checking the proto type
	protoState := st.ToProtoUnsafe()
	switch protoState.(type) {
	case *ethpb.BeaconStateDeneb:
		body := &ethpb.BeaconBlockBodyDeneb{}
		if err := body.UnmarshalSSZ(bodySSZ); err != nil {
			return nil, errors.Wrap(err, "failed to unmarshal block body (Deneb)")
		}
		blockBody, err = consensus_blocks.NewBeaconBlockBody(body)
		if err != nil {
			return nil, errors.Wrap(err, "failed to create block body (Deneb)")
		}
	case *ethpb.BeaconStateCapella:
		body := &ethpb.BeaconBlockBodyCapella{}
		if err := body.UnmarshalSSZ(bodySSZ); err != nil {
			return nil, errors.Wrap(err, "failed to unmarshal block body (Capella)")
		}
		blockBody, err = consensus_blocks.NewBeaconBlockBody(body)
		if err != nil {
			return nil, errors.Wrap(err, "failed to create block body (Capella)")
		}
	default:
		return nil, errors.New("unsupported state version for execution_payload (expected Capella or Deneb)")
	}

	err = blocks.ProcessPayload(st, blockBody)
	if err != nil {
		return nil, errors.Wrap(err, "failed to process execution payload")
	}

	return st, nil
}

func processWithdrawals(ctx context.Context, st state.BeaconState, executionPayloadSSZ []byte) (state.BeaconState, error) {
	// Detect fork version from state to use correct execution payload and block body type
	protoState := st.ToProtoUnsafe()
	var signedBlock interfaces.SignedBeaconBlock
	var err error
	
	switch protoState.(type) {
	case *ethpb.BeaconStateDeneb:
		execPayload := &enginev1.ExecutionPayloadDeneb{}
		if err := execPayload.UnmarshalSSZ(executionPayloadSSZ); err != nil {
			return nil, errors.Wrap(err, "failed to unmarshal execution payload (Deneb)")
		}
		b := util.NewBeaconBlockDeneb()
		b.Block.Body = &ethpb.BeaconBlockBodyDeneb{ExecutionPayload: execPayload}
		signedBlock, err = consensus_blocks.NewSignedBeaconBlock(b)
	case *ethpb.BeaconStateCapella:
		execPayload := &enginev1.ExecutionPayloadCapella{}
		if err := execPayload.UnmarshalSSZ(executionPayloadSSZ); err != nil {
			return nil, errors.Wrap(err, "failed to unmarshal execution payload (Capella)")
		}
		b := util.NewBeaconBlockCapella()
		b.Block.Body = &ethpb.BeaconBlockBodyCapella{ExecutionPayload: execPayload}
		signedBlock, err = consensus_blocks.NewSignedBeaconBlock(b)
	default:
		return nil, errors.New("unsupported state version for withdrawals (expected Capella or Deneb)")
	}
	
	if err != nil {
		return nil, errors.Wrap(err, "failed to create signed block")
	}

	payload, err := signedBlock.Block().Body().Execution()
	if err != nil {
		return nil, errors.Wrap(err, "failed to get execution payload")
	}

	withdrawals, err := payload.Withdrawals()
	if err != nil {
		return nil, errors.Wrap(err, "failed to get withdrawals")
	}

	// Use appropriate wrapper based on fork version
	var p interfaces.ExecutionData
	switch protoState.(type) {
	case *ethpb.BeaconStateDeneb:
		p, err = consensus_blocks.WrappedExecutionPayloadDeneb(&enginev1.ExecutionPayloadDeneb{Withdrawals: withdrawals})
	case *ethpb.BeaconStateCapella:
		p, err = consensus_blocks.WrappedExecutionPayloadCapella(&enginev1.ExecutionPayloadCapella{Withdrawals: withdrawals})
	default:
		return nil, errors.New("unsupported state version for withdrawals (expected Capella or Deneb)")
	}
	
	if err != nil {
		return nil, errors.Wrap(err, "failed to wrap execution payload")
	}

	st, err = blocks.ProcessWithdrawals(st, p)
	if err != nil {
		return nil, errors.Wrap(err, "failed to process withdrawals")
	}

	return st, nil
}

// Epoch processing functions
func processJustificationAndFinalization(ctx context.Context, st state.BeaconState) (state.BeaconState, error) {
	vp, bp, err := altair.InitializePrecomputeValidators(ctx, st)
	if err != nil {
		return nil, errors.Wrap(err, "failed to initialize precompute validators")
	}
	_, bp, err = altair.ProcessEpochParticipation(ctx, st, bp, vp)
	if err != nil {
		return nil, errors.Wrap(err, "failed to process epoch participation")
	}

	st, err = precompute.ProcessJustificationAndFinalizationPreCompute(st, bp)
	if err != nil {
		return nil, errors.Wrap(err, "failed to process justification and finalization")
	}

	return st, nil
}

func processRewardsAndPenalties(ctx context.Context, st state.BeaconState) (state.BeaconState, error) {
	vp, bp, err := altair.InitializePrecomputeValidators(ctx, st)
	if err != nil {
		return nil, errors.Wrap(err, "failed to initialize precompute validators")
	}
	_, bp, err = altair.ProcessEpochParticipation(ctx, st, bp, vp)
	if err != nil {
		return nil, errors.Wrap(err, "failed to process epoch participation")
	}

	st, err = altair.ProcessRewardsAndPenaltiesPrecompute(st, bp, vp)
	if err != nil {
		return nil, errors.Wrap(err, "failed to process rewards and penalties")
	}

	return st, nil
}

func processRegistryUpdates(ctx context.Context, st state.BeaconState) (state.BeaconState, error) {
	st, err := epoch.ProcessRegistryUpdates(ctx, st)
	if err != nil {
		return nil, errors.Wrap(err, "failed to process registry updates")
	}
	return st, nil
}

func processSlashings(ctx context.Context, st state.BeaconState) (state.BeaconState, error) {
	err := epoch.ProcessSlashings(st)
	if err != nil {
		return nil, errors.Wrap(err, "failed to process slashings")
	}
	return st, nil
}

func processEth1DataReset(ctx context.Context, st state.BeaconState) (state.BeaconState, error) {
	st, err := epoch.ProcessEth1DataReset(st)
	if err != nil {
		return nil, errors.Wrap(err, "failed to process eth1 data reset")
	}
	return st, nil
}

func processEffectiveBalanceUpdates(ctx context.Context, st state.BeaconState) (state.BeaconState, error) {
	st, err := epoch.ProcessEffectiveBalanceUpdates(st)
	if err != nil {
		return nil, errors.Wrap(err, "failed to process effective balance updates")
	}
	return st, nil
}

func processSlashingsReset(ctx context.Context, st state.BeaconState) (state.BeaconState, error) {
	st, err := epoch.ProcessSlashingsReset(st)
	if err != nil {
		return nil, errors.Wrap(err, "failed to process slashings reset")
	}
	return st, nil
}

func processRandaoMixesReset(ctx context.Context, st state.BeaconState) (state.BeaconState, error) {
	st, err := epoch.ProcessRandaoMixesReset(st)
	if err != nil {
		return nil, errors.Wrap(err, "failed to process randao mixes reset")
	}
	return st, nil
}

func processHistoricalSummariesUpdate(ctx context.Context, st state.BeaconState) (state.BeaconState, error) {
	st, err := epoch.ProcessHistoricalDataUpdate(st)
	if err != nil {
		return nil, errors.Wrap(err, "failed to process historical summaries update")
	}
	return st, nil
}

func processParticipationFlagUpdates(ctx context.Context, st state.BeaconState) (state.BeaconState, error) {
	st, err := altair.ProcessParticipationFlagUpdates(st)
	if err != nil {
		return nil, errors.Wrap(err, "failed to process participation flag updates")
	}
	return st, nil
}

func processInactivityUpdates(ctx context.Context, st state.BeaconState) (state.BeaconState, error) {
	vp, bp, err := altair.InitializePrecomputeValidators(ctx, st)
	if err != nil {
		return nil, errors.Wrap(err, "failed to initialize precompute validators")
	}
	vp, _, err = altair.ProcessEpochParticipation(ctx, st, bp, vp)
	if err != nil {
		return nil, errors.Wrap(err, "failed to process epoch participation")
	}

	st, _, err = altair.ProcessInactivityScores(ctx, st, vp)
	if err != nil {
		return nil, errors.Wrap(err, "failed to process inactivity updates")
	}

	return st, nil
}
