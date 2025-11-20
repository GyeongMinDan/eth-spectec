(* Cache entry for relation and function invocations *)

module Entry = struct
  type t = string * Il.Value.t list

  let equal (id_a, values_a) (id_b, values_b) =
    id_a = id_b
    && List.compare (fun v_a v_b -> Il.Value.compare v_a v_b) values_a values_b
       = 0

  let hash = Hashtbl.hash
end

(* LFU (with LRU tiebreak) cache over Entry keys *)

module Cache = struct
  module Table = Hashtbl.Make (Entry)

  let create ~size = Table.create size
  let clear cache = Table.clear cache
  let find cache key = Table.find_opt cache key
  let add cache key value = Table.add cache key value
end

(* Cache targets *)

let is_cached_func = function
  | name when String.starts_with ~prefix:"debug_print_label_" name -> false
  (* State-modifying functions: do not cache (side-effects) *)
  | "apply_one_round_captured" -> false
  | "apply_one_round" -> false
  | "apply_one_delta" -> false
  | "increase_balance" -> false
  | "decrease_balance" -> false
  | "apply_one_decrease" -> false
  | "reward_proposer" -> false
  | "initiate_validator_exit" -> false
  (* Functions that read/derive from state.BALANCES: do not cache *)
  | "rebalance_validator_enumerated" -> false
  | "expected_withdrawals_loop" -> false
  | "get_expected_withdrawals" -> false
  | "flag_reward_one" -> false
  | "flag_reward_one_eligible" -> false
  | "flag_penalty_one" -> false
  | "flag_penalty_one_eligible" -> false
  | "inact_penalty_one" -> false
  | "get_flag_index_deltas" -> false
  | "get_inactivity_penalty_deltas" -> false
  | "get_total_balance" -> false
  | "get_base_reward_per_increment" -> false
  | "get_base_reward" -> false
  | "compute_slash_penalty_en" -> false
  | _ -> true
let is_cached_rule = function
  (* Relations that update state.BALANCES: do not cache *)
  | "Process_rewards_and_penalties" -> false
  | "Process_slashings" -> false
  | "ProcessProposerSlashing" -> false
  | "ProcessAttesterSlashing" -> false
  | "ProcessAttestation" -> false
  | "ProcessDeposit" -> false
  | "Process_withdrawals" -> false
  | "Process_sync_aggregate" -> false
  (* Apply relations that call balance-updating rules: do not cache *)
  | "Apply_proposer_slashings" -> false
  | "Apply_attester_slashings" -> false
  | "Apply_attestations" -> false
  | "Apply_deposits" -> false
  | _ -> true
