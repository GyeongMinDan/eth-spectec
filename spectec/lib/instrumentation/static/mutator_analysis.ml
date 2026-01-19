open Common.Source
module Il = Lang.Il

(* === Types === *)

(* Field path types - duplicated to avoid circular dependency *)
type input_source = State | Block | Unknown

type index_expr = ConstInt of int | PathRef of field_path
and field_step = FieldAccess of string | IndexAccess of index_expr
and field_path = { source : input_source; steps : field_step list }

(* Helper to append a step to a field path *)
let append_step (path : field_path) (step : field_step) : field_path =
  { path with steps = path.steps @ [ step ] }

(* Information about a mutator relation/function *)
type mutator_info = { relation_id : string; mutated_paths : field_path list }

(* Block input pattern - describes what part of block a relation takes *)
type block_input_pattern =
  | FullBlock (* signedBeaconBlock - full signed block *)
  | BlockMessage (* beaconBlock = signedBeaconBlock.MESSAGE *)
  | BlockBody (* beaconBlockBody = block.BODY *)
  | ExecutionPayload (* executionPayload = block.BODY.EXECUTION_PAYLOAD *)
  | SyncAggregate (* syncAggregate = block.BODY.SYNC_AGGREGATE *)
  | Custom of field_path (* Custom path - fallback *)

(* Information about relation inputs *)
type relation_input_info = {
  input_var_names : string list;
  input_positions : int list; (* Which positions are inputs *)
  block_pattern : block_input_pattern option; (* Block input pattern, if any *)
}

(* Analysis result *)
type analysis_result = {
  mutators : (string, mutator_info) Hashtbl.t;
  getters : string list;
}

(* === State === *)

module State = struct
  let mutators : (string, mutator_info) Hashtbl.t = Hashtbl.create 50
  let getters : string list ref = ref []

  let relation_inputs : (string, relation_input_info) Hashtbl.t =
    Hashtbl.create 50

  let reset () =
    Hashtbl.clear mutators;
    Hashtbl.clear relation_inputs;
    getters := []
end

(* === Whitelist Check === *)

(* Relations to analyze - matches dep_common.ml *)
let eth_whitelist =
  [
    (* Top-level *)
    "State_transition";
    (* Block Processing *)
    "ProcessBlockHeader";
    "ProcessWithdrawals";
    "ProcessExecutionPayload";
    "ProcessRandao";
    "ProcessEth1Data";
    "ProcessSyncAggregate";
    (* Operations *)
    "ProcessProposerSlashing";
    "ProcessAttesterSlashing";
    "ProcessAttestation";
    "ProcessDeposit";
    "ProcessVoluntaryExit";
    "ProcessBlsToExecutionChange";
    (* Slot *)
    "ProcessSlot";
    (* Epoch *)
    "ProcessJustificationAndFinalization";
    "ProcessInactivityUpdates";
    "ProcessRewardsAndPenalties";
    "ProcessRegistryUpdates";
    "ProcessSlashings";
    "ProcessEth1DataReset";
    "ProcessEffectiveBalanceUpdates";
    "ProcessSlashingsReset";
    "ProcessRandaoMixesReset";
    "ProcessHistoricalSummariesUpdate";
    "ProcessParticipationFlagUpdates";
    "ProcessSyncCommitteeUpdates";
  ]

let is_whitelisted (rel : string) : bool = List.mem rel eth_whitelist

(* === Relation Input Extraction === *)

(* Extract variable name from expression *)
let extract_var_name (exp : Il.exp) : string option =
  match exp.it with Il.VarE id -> Some id.it | _ -> None

(* Detect block input pattern from input expression (recursive) *)
let rec detect_block_pattern (exp : Il.exp) : block_input_pattern option =
  match exp.it with
  | Il.VarE id -> (
      (* Check variable name to infer pattern *)
      match id.it with
      | "signedBeaconBlock" -> Some FullBlock
      | "beaconBlock" | "block" -> Some BlockMessage
      | "beaconBlockBody" | "body" -> Some BlockBody
      | "executionPayload" -> Some ExecutionPayload
      | "syncAggregate" -> Some SyncAggregate
      | _ -> None)
  | Il.DotE (base, atom) -> (
      (* Check for block.BODY.EXECUTION_PAYLOAD pattern *)
      let field_name = Lang.Xl.Atom.string_of_atom atom.it in
      match detect_block_pattern base with
      | Some BlockBody when field_name = "EXECUTION_PAYLOAD" ->
          Some ExecutionPayload
      | Some BlockMessage when field_name = "BODY" -> Some BlockBody
      | Some BlockMessage when field_name = "SYNC_AGGREGATE" ->
          Some SyncAggregate
      | _ -> None)
  | _ -> None

(* Extract relation input information *)
let extract_relation_input_info (id : string) (input_hints : int list)
    (rules : Il.rule list) : relation_input_info option =
  if not (is_whitelisted id) then None
  else if rules = [] then None
  else
    (* Get input expressions from first rule's notexp *)
    let rule = List.hd rules in
    let _, notexp, _ = rule.it in
    let _, exps = notexp in
    (* Split expressions based on input_hints (indices) *)
    let exps_input =
      exps
      |> List.mapi (fun idx exp -> (idx, exp))
      |> List.filter (fun (idx, _) -> List.mem idx input_hints)
      |> List.map snd
    in
    (* Extract variable names from input expressions *)
    let input_vars = List.filter_map extract_var_name exps_input in
    (* Detect block pattern from first block-like input *)
    let block_pattern =
      List.find_map
        (fun exp ->
          match detect_block_pattern exp with
          | Some pattern -> Some pattern
          | None -> None)
        exps_input
    in
    Some
      {
        input_var_names = input_vars;
        input_positions = input_hints;
        block_pattern;
      }

(* === UpdE Detection === *)

(* Extract field path from UpdE path expression *)
let rec extract_path_from_upd (path : Il.path) : field_path option =
  match path.it with
  | Il.RootP -> Some { source = State; steps = [] }
  | Il.DotP (base, atom) -> (
      match extract_path_from_upd base with
      | Some base_path ->
          Some
            (append_step base_path
               (FieldAccess (Lang.Xl.Atom.string_of_atom atom.it)))
      | None -> None)
  | Il.IdxP (base, idx) -> (
      match extract_path_from_upd base with
      | Some base_path -> (
          match idx.it with
          | Il.NumE n -> (
              match n with
              | `Nat bi -> (
                  try
                    let i = Bigint.to_int_exn bi in
                    Some (append_step base_path (IndexAccess (ConstInt i)))
                  with _ -> None)
              | _ -> None)
          | _ -> None)
      | None -> None)
  | Il.SliceP _ -> None (* Slices not supported *)

(* Recursively find all UpdE in an expression *)
let rec find_upd_in_exp (exp : Il.exp) : field_path list =
  match exp.it with
  | Il.UpdE (_, path, _) -> (
      match extract_path_from_upd path with Some p -> [ p ] | None -> [])
  | Il.UnE (_, _, e) -> find_upd_in_exp e
  | Il.BinE (_, _, e1, e2)
  | Il.CmpE (_, _, e1, e2)
  | Il.MemE (e1, e2)
  | Il.ConsE (e1, e2)
  | Il.CatE (e1, e2) ->
      find_upd_in_exp e1 @ find_upd_in_exp e2
  | Il.SubE (e, _)
  | Il.UpCastE (_, e)
  | Il.DownCastE (_, e)
  | Il.LenE e
  | Il.DotE (e, _)
  | Il.IdxE (e, _) ->
      find_upd_in_exp e
  | Il.SliceE (e1, e2, e3) ->
      find_upd_in_exp e1 @ find_upd_in_exp e2 @ find_upd_in_exp e3
  | Il.TupleE es | Il.ListE es | Il.CaseE (_, es) ->
      List.concat_map find_upd_in_exp es
  | Il.StrE fields -> List.concat_map (fun (_, e) -> find_upd_in_exp e) fields
  | Il.CallE (_, _, args) ->
      List.concat_map
        (fun arg ->
          match arg.it with Il.ExpA e -> find_upd_in_exp e | _ -> [])
        args
  | Il.IterE (e, _) -> find_upd_in_exp e
  | Il.MatchE (e, _) -> find_upd_in_exp e
  | Il.OptE (Some e) -> find_upd_in_exp e
  | _ -> []

(* Find UpdE in premises *)
let rec find_upd_in_prem (prem : Il.prem) : field_path list =
  match prem.it with
  | Il.IfPr e | Il.LetPr (_, e) -> find_upd_in_exp e
  | Il.IterPr (p, _) -> find_upd_in_prem p
  | _ -> []

(* Analyze a relation for UpdE usage and extract input info *)
let analyze_relation (id : string) (input_hints : int list)
    (rules : Il.rule list) : unit =
  (* Extract input information *)
  (match extract_relation_input_info id input_hints rules with
  | Some input_info -> Hashtbl.replace State.relation_inputs id input_info
  | None -> ());
  (* Analyze for mutator/getter *)
  let all_paths = ref [] in
  List.iter
    (fun rule ->
      let _, _, prems = rule.it in
      List.iter
        (fun prem -> all_paths := find_upd_in_prem prem @ !all_paths)
        prems)
    rules;
  if !all_paths <> [] then
    Hashtbl.replace State.mutators id
      { relation_id = id; mutated_paths = !all_paths }
  else State.getters := id :: !State.getters

(* Analyze a function (DecD) for UpdE usage *)
let analyze_function (id : string) (clauses : Il.clause list) : unit =
  let all_paths = ref [] in
  List.iter
    (fun clause ->
      let _, exp, prems = clause.it in
      all_paths := find_upd_in_exp exp @ !all_paths;
      List.iter
        (fun prem -> all_paths := find_upd_in_prem prem @ !all_paths)
        prems)
    clauses;
  if !all_paths <> [] then
    Hashtbl.replace State.mutators id
      { relation_id = id; mutated_paths = !all_paths }
  else State.getters := id :: !State.getters

(* === Static Analysis Interface === *)

let init spec =
  State.reset ();
  match spec with
  | Static.IlSpec il_spec ->
      List.iter
        (fun def ->
          match def.it with
          | Il.RelD (id, _, input_hints, rules) ->
              analyze_relation id.it input_hints rules
          | Il.DecD (id, _, _, _, clauses) -> analyze_function id.it clauses
          | Il.TypD _ -> ())
        il_spec
  | Static.SlSpec _ -> ()

let reset () = State.reset ()

let export () =
  Some
    ( (Hashtbl.to_seq State.mutators |> List.of_seq, !State.getters),
      Hashtbl.to_seq State.relation_inputs |> List.of_seq )

let restore ((mutators_list, getters_list), relation_inputs_list) =
  State.reset ();
  List.iter (fun (k, v) -> Hashtbl.replace State.mutators k v) mutators_list;
  State.getters := getters_list;
  List.iter
    (fun (k, v) -> Hashtbl.replace State.relation_inputs k v)
    relation_inputs_list

(* Get mutator info for a relation *)
let get_mutator_info (relation_id : string) : mutator_info option =
  Hashtbl.find_opt State.mutators relation_id

(* Get relation input info *)
let get_relation_input_info (relation_id : string) : relation_input_info option
    =
  Hashtbl.find_opt State.relation_inputs relation_id

(* Check if relation is a getter *)
let is_getter (relation_id : string) : bool =
  List.mem relation_id !State.getters

(* Print analysis results for debugging *)
let print_results (fmt : Format.formatter) : unit =
  Format.fprintf fmt "@.=== Mutator Analysis Results ===@.";
  Format.fprintf fmt "@.Mutators (%d):@." (Hashtbl.length State.mutators);
  Hashtbl.iter
    (fun rel_id info ->
      Format.fprintf fmt "  %s:@." rel_id;
      List.iter
        (fun path ->
          let source_str =
            match path.source with
            | State -> "state"
            | Block -> "block"
            | Unknown -> "?"
          in
          let steps_str =
            List.map
              (fun step ->
                match step with
                | FieldAccess f -> "." ^ f
                | IndexAccess (ConstInt i) -> Printf.sprintf "[%d]" i
                | IndexAccess (PathRef _) -> "[...]")
              path.steps
            |> String.concat ""
          in
          Format.fprintf fmt "    -> %s%s@." source_str steps_str)
        info.mutated_paths)
    State.mutators;
  Format.fprintf fmt "@.Getters (%d):@." (List.length !State.getters);
  List.iter (fun g -> Format.fprintf fmt "  %s@." g) !State.getters;
  Format.fprintf fmt "@."

(* Implement Static.S signature as submodule (for static_dependencies) *)
module Mutator_analysis : Static.S = struct
  type export_data =
    ((string * mutator_info) list * string list)
    * (string * relation_input_info) list

  let name = "mutator_analysis"
  let init = init
  let reset = reset
  let export () = export ()
  let restore data = restore data
end
