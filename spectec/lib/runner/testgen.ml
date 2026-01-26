(* Testgen backend - Generates test cases by mutating input data to target uncovered premises.

   Pipeline overview:
   1. Run test suite with node-coverage-il to get premise-to-testid mapping
   2. Human inspects uncovered premises and selects premise UIDs to target
   3. For selected premises, query dependency and path_condition results from checkpoint
   4. Filter out negative dependencies (from path_condition) and use positive dependencies
      (from dependency) to generate mutation targets and strategies
   5. Mutate JSON input files based on mutation constraints

   Usage:
     - Load checkpoint: load_checkpoint "checkpoint.ckpt"
     - List uncovered: get_uncovered_premises coverage
     - Get test cases for premise: get_test_cases_for_premise uid coverage
     - Get mutation suggestions: get_mutation_suggestions_for_premise uid coverage dependency
     - Get blacklisted fields: get_blacklisted_fields uid coverage path_condition
     - Generate test case: generate_test_case uid coverage dependency path_condition None
*)

open Common.Source
module Il = Lang.Il
module Checkpoint = Checkpoint
module Instrumentation = Instrumentation
module Dep = Instrumentation.Dependency.Dep_common

(* Types *)
type premise_uid = int
type test_case_id = string
type field_path = Instrumentation.Dependency.Dep_common.field_path

(* Mutation constraint - what field to mutate and to what values *)
type mutation_constraint = {
  field_path : field_path;
  strategies : Json_mutator.mutation_strategy list;
      (* Strategies to try for this path *)
  suggestion_str : string option;
      (* Original mutation suggestion string for reporting *)
}

(* Premise information *)
type premise_info = {
  uid : premise_uid;
  key : region * string;
  relation : string;
  rule : string;
  content : string;
}

(* Load checkpoint and extract coverage, dependency, and path_condition data.
   
   The checkpoint should contain:
   - Coverage data (node_il): premise-to-testid mapping and uncovered premises
   - Positive results: mutation suggestions organized by relation/rule
   - Path condition results: negative dependencies (fields to avoid mutating)
   
   Note: If dependency/path_condition results are not in the checkpoint, you may
   need to re-run the test suite with those instrumentations enabled on the
   specific test cases that cover your selected premises. *)
let load_checkpoint (checkpoint_file : string) :
    Checkpoint.t
    * Instrumentation.Node_coverage_il.result option
    * Instrumentation.Dependency.Positive.result option
    * Instrumentation.Dependency.Negative.result option =
  let checkpoint =
    match Checkpoint.load_from_file ~file:checkpoint_file with
    | Ok checkpoint -> checkpoint
    | Error e ->
        failwith
          (Printf.sprintf "Failed to load checkpoint: %s"
             (Error.string_of_error e))
  in
  let coverage = checkpoint.Checkpoint.coverage.node_il in
  let dependency = checkpoint.Checkpoint.coverage.dependency in
  let path_condition = checkpoint.Checkpoint.coverage.path_condition in
  (checkpoint, coverage, dependency, path_condition)

(* Get summary of checkpoint contents for debugging *)
let checkpoint_summary (checkpoint_file : string) : string =
  let checkpoint, coverage, dependency, path_condition =
    load_checkpoint checkpoint_file
  in
  let buf = Buffer.create 256 in
  let fmt = Format.formatter_of_buffer buf in
  Format.fprintf fmt "Checkpoint: %s\n" checkpoint_file;
  Format.fprintf fmt "  Completed tests: %d\n"
    (List.length checkpoint.Checkpoint.completed_inputs);
  Format.fprintf fmt "  Coverage data: %s\n"
    (if Option.is_some coverage then "present" else "missing");
  (match coverage with
  | Some cov ->
      Format.fprintf fmt "    Total premises: %d\n" cov.total_prems;
      Format.fprintf fmt "    Premises with UIDs: %d\n"
        (List.length cov.prem_to_uid);
      Format.fprintf fmt "    Premises succeeded: %d\n"
        (List.length cov.prems_succeeded);
      (* Compute uncovered count inline - premises with UIDs that never succeeded *)
      let succeeded_keys =
        List.fold_left (fun acc (key, _) -> key :: acc) [] cov.prems_succeeded
      in
      let uncovered_count =
        List.fold_left
          (fun count ((region, content_str), _) ->
            let premise_key = (region, content_str) in
            if not (List.mem premise_key succeeded_keys) then count + 1
            else count)
          0 cov.prem_to_uid
      in
      Format.fprintf fmt "    Uncovered premises: %d\n" uncovered_count
  | None -> ());
  Format.fprintf fmt "  Positive data: %s\n"
    (if Option.is_some dependency then "present" else "missing");
  (match dependency with
  | Some dep ->
      let total_mutations =
        List.fold_left
          (fun acc (_, test_muts) ->
            List.fold_left
              (fun acc (_, muts) -> acc + List.length muts)
              acc test_muts)
          0 dep.per_test_sym_mutations
      in
      Format.fprintf fmt "    Total mutation suggestions: %d\n" total_mutations
  | None -> ());
  Format.fprintf fmt "  Path condition data: %s\n"
    (if Option.is_some path_condition then "present" else "missing");
  (match path_condition with
  | Some pc ->
      Format.fprintf fmt "    Premises with blacklists: %d\n"
        (List.length pc.blacklists)
  | None -> ());
  Format.pp_print_flush fmt ();
  Buffer.contents buf

(* Get uncovered premises with UIDs from coverage data *)
let get_uncovered_premises
    (coverage : Instrumentation.Node_coverage_il.result option) :
    premise_info list =
  match coverage with
  | None -> []
  | Some cov ->
      (* Build a map from premise key to UID *)
      (* premise_uid_map is ((region * string) * int) list *)
      let key_to_uid = cov.prem_to_uid in

      (* Build a set of succeeded premise keys (as a list for membership check) *)
      let succeeded_keys =
        List.fold_left (fun acc (key, _) -> key :: acc) [] cov.prems_succeeded
      in

      (* Find uncovered premises - those with UIDs but not in succeeded *)
      let uncovered = ref [] in
      List.iter
        (fun ((region, content_str), uid) ->
          let premise_key = (region, content_str) in
          if not (List.mem premise_key succeeded_keys) then
            (* Extract relation and rule from premise key if possible *)
            (* For now, we'll use placeholder values - this can be enhanced *)
            uncovered :=
              {
                uid;
                key = premise_key;
                relation = "unknown";
                rule = "unknown";
                content = content_str;
              }
              :: !uncovered)
        key_to_uid;
      !uncovered

(* Get mutation suggestions for a premise from dependency analysis.
   Since dependency results are now organized per-test, we collect all mutations
   for this premise across all test cases. *)
let get_mutation_suggestions_for_premise (premise_uid : premise_uid)
    (_coverage : Instrumentation.Node_coverage_il.result option)
    (dependency : Instrumentation.Dependency.Positive.result option) :
    Instrumentation.Dependency.Positive.sym_mutation list =
  match dependency with
  | None -> []
  | Some dep -> (
      (* Find mutations for this premise UID *)
      match List.assoc_opt premise_uid dep.per_test_sym_mutations with
      | None -> []
      | Some test_muts ->
          (* Collect all mutations across all test cases *)
          let all_muts =
            List.fold_left (fun acc (_, muts) -> acc @ muts) [] test_muts
          in
          (* Filter invalid mutations *)
          let module Dep = Instrumentation.Dependency.Dep_common in
          let is_valid_mutation
              (mut : Instrumentation.Dependency.Positive.sym_mutation) : bool =
            match mut.target_path with
            | None -> false
            | Some path ->
                (* Filter out state as whole *)
                if path.source = Dep.State && path.steps = [] then false
                  (* Filter out Unknown source *)
                else if path.source = Dep.Unknown then false
                else true
          in
          let filtered_muts = List.filter is_valid_mutation all_muts in
          (* De-duplicate mutations based on target_path and suggestion *)
          let module Pos = Instrumentation.Dependency.Positive in
          let mutation_key (mut : Pos.sym_mutation) : string =
            let path_str =
              match mut.target_path with
              | None -> "None"
              | Some path -> Dep.string_of_field_path path
            in
            let suggestion_str =
              match mut.suggestion with
              | Pos.ToConst (op, v) ->
                  Printf.sprintf "ToConst(%s,%s)" (Pos.string_of_cmp_op op)
                    (Il.Print.string_of_value v)
              | Pos.ToLength (op, v) ->
                  Printf.sprintf "ToLength(%s,%s)" (Pos.string_of_cmp_op op)
                    (Il.Print.string_of_value v)
              | Pos.Unknown typ ->
                  Printf.sprintf "Unknown(%s)"
                    (match typ with
                    | Some t -> Il.Print.string_of_typ t
                    | None -> "None")
            in
            Printf.sprintf "%s|%s" path_str suggestion_str
          in
          let seen = Hashtbl.create (List.length filtered_muts) in
          let deduplicated_muts =
            List.filter
              (fun mut ->
                let key = mutation_key mut in
                if Hashtbl.mem seen key then false
                else (
                  Hashtbl.replace seen key ();
                  true))
              filtered_muts
          in
          deduplicated_muts)

(* Convert Il.Value.t to JSON value for mutation *)
let value_to_json (v : Il.Value.t) : (Yojson.Safe.t, string) result =
  match Interface.JSON.Print.value_to_json v with
  | Ok json -> Ok json
  | Error err -> Error (Interface.JSON.Print.string_of_error err)

(* Load type aliases from elaborated IL spec. *)
let spec_il_ref : Il.spec option ref = ref None
let type_aliases_cache : (string, Il.typ) Hashtbl.t option ref = ref None

let set_spec_il (spec_il : Il.spec) : unit =
  spec_il_ref := Some spec_il;
  type_aliases_cache := None

let load_type_aliases () : (string, Il.typ) Hashtbl.t =
  match !type_aliases_cache with
  | Some aliases -> aliases
  | None ->
      let aliases = Hashtbl.create 256 in
      let spec_il = Option.value ~default:[] !spec_il_ref in
      List.iter
        (fun def ->
          match def.it with
          | Il.TypD (typid, _tparams, deftyp) -> (
              match deftyp.it with
              | Il.PlainT typ ->
                  Hashtbl.replace aliases (String.lowercase_ascii typid.it) typ
              | _ -> ())
          | _ -> ())
        spec_il;
      type_aliases_cache := Some aliases;
      aliases

let is_bytes_type_name name =
  String.length name >= 5 && String.sub name 0 5 = "bytes"

let is_uint_type_name name =
  match name with
  | "uint" | "uint8" | "uint16" | "uint32" | "uint64" | "uint256" -> true
  | _ -> false

let is_base_primitive name =
  match name with "nat" | "int" | "bool" | "text" -> true | _ -> false

type primitive_kind = Bytes of int | Nat | Int | Bool | Text | Unknown

let resolve_alias_kind (type_name : string) : primitive_kind =
  let aliases = load_type_aliases () in
  let rec go name visited =
    let lname = String.lowercase_ascii name in
    if is_bytes_type_name lname then
      try
        let len_str = String.sub lname 5 (String.length lname - 5) in
        Bytes (int_of_string len_str)
      with _ -> Unknown
    else if is_uint_type_name lname then Nat
    else if List.mem lname visited then Unknown
    else
      match Hashtbl.find_opt aliases lname with
      | Some typ -> (
          match typ.it with
          | Il.NumT `NatT -> Nat
          | Il.NumT `IntT -> Int
          | Il.BoolT -> Bool
          | Il.TextT -> Text
          | Il.VarT (id, _) -> go id.it (lname :: visited)
          | _ -> Unknown)
      | None -> Unknown
  in
  go type_name []

(* Helper: check if string ends with suffix *)
let ends_with s suffix =
  let len_s = String.length s in
  let len_suffix = String.length suffix in
  if len_s < len_suffix then false
  else String.sub s (len_s - len_suffix) len_suffix = suffix

(* Resolve VarT type name to primitive type information *)
(* Returns: (is_bytes, byte_size_opt, is_nat) where:
   - is_bytes: true if this is a bytes type
   - byte_size_opt: Some size if bytes type, None otherwise
   - is_nat: true if nat/uint type, false if int/signed *)
let resolve_type_to_primitive (type_name : string) : bool * int option * bool =
  let name = String.lowercase_ascii type_name in
  let kind = resolve_alias_kind name in
  (* Check for bytes types first *)
  match kind with
  | Bytes len -> (true, Some len, false)
  | Nat -> (false, None, true)
  | Int -> (false, None, false)
  | Bool -> (false, None, true)
  | Text -> (false, None, true)
  | Unknown ->
      (* Fallback to pattern-based heuristics for legacy names *)
      if is_bytes_type_name name then
        try
          let len_str = String.sub name 5 (String.length name - 5) in
          let len = int_of_string len_str in
          if len >= 1 then (true, Some len, false) else (false, None, true)
        with _ -> (false, None, true)
      else if is_uint_type_name name then (false, None, true)
      else if name = "int" then (false, None, false)
      else (false, None, true)

(* Get max bytes value for a given byte size (all 0xFF bytes) *)
let max_bytes_value_for_size (len : int) : Yojson.Safe.t =
  if len <= 0 then `String "0x"
  else
    (* Generate hex string with all 0xFF bytes *)
    let hex_str = "0x" ^ String.make (len * 2) 'f' in
    `String hex_str

(* Get MAX value for a type as JSON *)
let max_value_for_type (typ : Il.typ') : Yojson.Safe.t =
  match typ with
  | Il.NumT `NatT -> `Intlit "18446744073709551615" (* max uint64 *)
  | Il.NumT `IntT -> `Intlit "9223372036854775807" (* max int64 *)
  | Il.BoolT -> `Bool true
  | Il.TextT -> `String "max_string"
  | Il.VarT (id, _) -> (
      let is_bytes, byte_size_opt, is_nat = resolve_type_to_primitive id.it in
      match (is_bytes, byte_size_opt) with
      | true, Some len -> max_bytes_value_for_size len
      | true, None -> `String "0xff" (* fallback for bytes without size *)
      | false, _ ->
          if is_nat then `Intlit "18446744073709551615" (* max uint64 *)
          else `Intlit "9223372036854775807" (* max int64 *))
  | _ -> `Intlit "18446744073709551615" (* default to max uint64 *)

(* Get MIN value for a type as JSON *)
let min_value_for_type (typ : Il.typ') : Yojson.Safe.t =
  match typ with
  | Il.NumT `NatT -> `Int 0
  | Il.NumT `IntT -> `Intlit "-9223372036854775808" (* min int64 *)
  | Il.BoolT -> `Bool false
  | Il.TextT -> `String ""
  | Il.VarT (id, _) -> (
      let is_bytes, byte_size_opt, is_nat = resolve_type_to_primitive id.it in
      match (is_bytes, byte_size_opt) with
      | true, Some len -> `String ("0x" ^ String.make (len * 2) '0')
      | true, None -> `String "0x00" (* fallback for bytes without size *)
      | false, _ ->
          if is_nat then `Int 0
          else `Intlit "-9223372036854775808" (* min int64 *))
  | _ -> `Int 0 (* default to 0 *)

(* Extract byte size from BytesV value *)
let bytes_size_from_value (value : Il.Value.t) : int option =
  match value.it with Il.BytesV { len; _ } -> Some len | _ -> None

(* Infer mutation constraints from dependency analysis. *)
let infer_mutation_constraints (premise_uid : premise_uid)
    (coverage : Instrumentation.Node_coverage_il.result option)
    (dependency : Instrumentation.Dependency.Positive.result option) :
    mutation_constraint list =
  let suggestions =
    get_mutation_suggestions_for_premise premise_uid coverage dependency
  in
  (* Convert sym_mutation to mutation constraints using new types *)
  let module Pos = Instrumentation.Dependency.Positive in
  let module Dep = Instrumentation.Dependency.Dep_common in
  (* Helper to convert field_path to string list *)
  let constraints =
    List.filter_map
      (fun (sym_mut : Pos.sym_mutation) ->
        (* Convert target_path to string list *)
        match sym_mut.target_path with
        | None -> None
        | Some target_path ->
            let strategies =
              match sym_mut.suggestion with
              | Pos.ToConst (op, value) -> (
                  (* Check if value is BytesV to preserve byte size *)
                  let bytes_size_opt = bytes_size_from_value value in
                  (* Get type information from value *)
                  let value_typ = value.note.Il.typ in
                  match value_to_json value with
                  | Ok json -> (
                      (* Generate mutation strategies based on operator *)
                      match op with
                      | `EqOp -> (
                          (* For ==, generate not-equal values: (value+1), (value-1), and MAX *)
                          match json with
                          | `Int n ->
                              [
                                Json_mutator.SetValue (`Int (n + 1));
                                Json_mutator.SetValue
                                  (if n > 0 then `Int (n - 1) else `Int 0);
                                Json_mutator.SetValue
                                  (max_value_for_type value_typ);
                              ]
                          | `Bool b ->
                              [
                                Json_mutator.SetValue (`Bool (not b));
                                Json_mutator.SetValue
                                  (max_value_for_type value_typ);
                              ]
                          | `String s -> (
                              (* Check if this is a bytes value (hex string) *)
                              match bytes_size_opt with
                              | Some len ->
                                  [
                                    Json_mutator.SetValue
                                      (`String (s ^ "_mutated"));
                                    Json_mutator.SetValue
                                      (max_bytes_value_for_size len);
                                  ]
                              | None ->
                                  [
                                    Json_mutator.SetValue
                                      (`String (s ^ "_mutated"));
                                    Json_mutator.SetValue
                                      (max_value_for_type value_typ);
                                  ])
                          | _ -> [ Json_mutator.SetValue json ])
                      | `NeOp ->
                          (* For !=, generate equal value *)
                          [ Json_mutator.SetValue json ]
                      | `LtOp -> (
                          (* For <, generate lhs = rhs and lhs = MAX *)
                          match json with
                          | `Int _ ->
                              [
                                Json_mutator.SetValue json;
                                Json_mutator.SetValue
                                  (max_value_for_type value_typ);
                              ]
                          | `String _ -> (
                              (* Check if this is a bytes value *)
                              match bytes_size_opt with
                              | Some len ->
                                  [
                                    Json_mutator.SetValue json;
                                    Json_mutator.SetValue
                                      (max_bytes_value_for_size len);
                                  ]
                              | None ->
                                  [
                                    Json_mutator.SetValue json;
                                    Json_mutator.SetValue
                                      (max_value_for_type value_typ);
                                  ])
                          | _ -> [ Json_mutator.SetValue json ])
                      | `GtOp -> (
                          (* For >, generate lhs = rhs and lhs = 0 *)
                          match json with
                          | `Int _ ->
                              [
                                Json_mutator.SetValue json;
                                Json_mutator.SetValue
                                  (min_value_for_type value_typ);
                              ]
                          | `String _ -> (
                              (* For bytes, generate zero bytes of same size *)
                              match bytes_size_opt with
                              | Some len ->
                                  [
                                    Json_mutator.SetValue json;
                                    Json_mutator.SetValue
                                      (`String ("0x" ^ String.make (len * 2) '0'));
                                  ]
                              | None ->
                                  [
                                    Json_mutator.SetValue json;
                                    Json_mutator.SetValue
                                      (min_value_for_type value_typ);
                                  ])
                          | _ -> [ Json_mutator.SetValue json ])
                      | `LeOp -> (
                          (* For <=, generate lhs = rhs + 1 and lhs = MAX *)
                          match json with
                          | `Int n ->
                              [
                                Json_mutator.SetValue (`Int (n + 1));
                                Json_mutator.SetValue
                                  (max_value_for_type value_typ);
                              ]
                          | `String _ -> (
                              (* For bytes, generate max bytes of same size *)
                              match bytes_size_opt with
                              | Some len ->
                                  [
                                    Json_mutator.SetValue json;
                                    Json_mutator.SetValue
                                      (max_bytes_value_for_size len);
                                  ]
                              | None ->
                                  [
                                    Json_mutator.SetValue json;
                                    Json_mutator.SetValue
                                      (max_value_for_type value_typ);
                                  ])
                          | _ -> [ Json_mutator.SetValue json ])
                      | `GeOp -> (
                          (* For >=, generate lhs = rhs - 1 and lhs = 0 *)
                          match json with
                          | `Int n when n > 0 ->
                              [
                                Json_mutator.SetValue (`Int (n - 1));
                                Json_mutator.SetValue
                                  (min_value_for_type value_typ);
                              ]
                          | `Int _ ->
                              [
                                Json_mutator.SetValue (`Int 0);
                                Json_mutator.SetValue
                                  (min_value_for_type value_typ);
                              ]
                          | `String _ -> (
                              (* For bytes, generate zero bytes of same size *)
                              match bytes_size_opt with
                              | Some len ->
                                  [
                                    Json_mutator.SetValue json;
                                    Json_mutator.SetValue
                                      (`String ("0x" ^ String.make (len * 2) '0'));
                                  ]
                              | None ->
                                  [
                                    Json_mutator.SetValue json;
                                    Json_mutator.SetValue
                                      (min_value_for_type value_typ);
                                  ])
                          | _ -> [ Json_mutator.SetValue json ]))
                  | Error _err -> [])
              | Pos.ToLength (op, _value) -> (
                  (* For len>0 constraints, create empty list *)
                  match op with
                  | `GtOp ->
                      (* len > 0 means we should create empty list (len == 0) *)
                      [ Json_mutator.SetValue (`List []) ]
                  | _ ->
                      (* For other length constraints, use append/remove *)
                      [ Json_mutator.AppendItem; Json_mutator.RemoveItem ])
              | Pos.Unknown typ_opt -> (
                  (* Generate MAX and MIN based on type (uses resolve_type_to_primitive) *)
                  match typ_opt with
                  | None -> []
                  | Some typ ->
                      [
                        Json_mutator.SetValue (max_value_for_type typ.it);
                        Json_mutator.SetValue (min_value_for_type typ.it);
                      ])
            in
            (* Only include if we have strategies *)
            if strategies = [] then None
            else
              (* Get the original mutation suggestion string *)
              let suggestion_str = Some (Pos.string_of_sym_mutation sym_mut) in
              Some { field_path = target_path; strategies; suggestion_str })
      suggestions
  in
  constraints

(* Check if a test case ID corresponds to a state transition test.
   State transition tests are identified by having 'state_transition' in their path. *)
let is_state_transition_test (test_case_id : test_case_id) : bool =
  try
    let _ =
      Str.search_forward (Str.regexp_string "state_transition") test_case_id 0
    in
    true
  with Not_found -> false

(* Reverse prem_to_test mapping: (test_id -> premise_uid list)
   Only includes premises from the supplied premise_uids list *)
let get_test_to_premises (premise_uids : premise_uid list)
    (coverage : Instrumentation.Node_coverage_il.result option) :
    (test_case_id * premise_uid list) list =
  match coverage with
  | None -> []
  | Some cov ->
      (* Build premise_key -> uid map *)
      let key_to_uid = Hashtbl.create 256 in
      List.iter
        (fun (key, uid) -> Hashtbl.add key_to_uid key uid)
        cov.prem_to_uid;

      (* Build test_id -> premise_uid list map *)
      let test_to_prems = Hashtbl.create 256 in
      List.iter
        (fun (prem_key, test_ids) ->
          match Hashtbl.find_opt key_to_uid prem_key with
          | Some uid when List.mem uid premise_uids ->
              (* This premise is in our target list *)
              List.iter
                (fun test_id ->
                  let existing =
                    Hashtbl.find_opt test_to_prems test_id
                    |> Option.value ~default:[]
                  in
                  if not (List.mem uid existing) then
                    Hashtbl.replace test_to_prems test_id (uid :: existing))
                test_ids
          | _ -> ())
        cov.prem_to_test;

      (* Convert to list and sort *)
      Hashtbl.to_seq test_to_prems
      |> List.of_seq
      |> List.map (fun (test_id, uids) -> (test_id, List.sort compare uids))
      |> List.sort (fun (a, _) (b, _) -> String.compare a b)

(* Find test cases that covered a premise, filtered to only state transition tests *)
let get_test_cases_for_premise (premise_uid : premise_uid)
    (coverage : Instrumentation.Node_coverage_il.result option) :
    test_case_id list =
  match coverage with
  | None -> []
  | Some cov -> (
      (* Find the premise key for this UID *)
      let uid_to_key =
        List.fold_left
          (fun acc (uid, key) -> (uid, key) :: acc)
          [] cov.uid_to_prem
        |> List.to_seq |> Hashtbl.of_seq
      in
      match Hashtbl.find_opt uid_to_key premise_uid with
      | None -> []
      | Some key -> (
          (* Find test cases for this premise key *)
          let key_to_test_cases =
            List.fold_left
              (fun acc (k, test_cases) -> (k, test_cases) :: acc)
              [] cov.prem_to_test
            |> List.to_seq |> Hashtbl.of_seq
          in
          match Hashtbl.find_opt key_to_test_cases key with
          | None -> []
          | Some test_cases ->
              (* Filter removed to allow all test cases *)
              test_cases))

(* Get premise information including test cases that covered it *)
let get_premise_info (premise_uid : premise_uid)
    (coverage : Instrumentation.Node_coverage_il.result option) :
    (premise_info * test_case_id list) option =
  match coverage with
  | None -> None
  | Some cov -> (
      (* Find premise key for this UID *)
      let premise_key =
        List.find_map
          (fun (uid, key) -> if uid = premise_uid then Some key else None)
          cov.uid_to_prem
      in
      match premise_key with
      | None -> None
      | Some key ->
          let _region, content_str = key in
          let test_cases = get_test_cases_for_premise premise_uid coverage in
          Some
            ( {
                uid = premise_uid;
                key;
                relation = "unknown";
                (* TODO: extract from spec *)
                rule = "unknown";
                (* TODO: extract from spec *)
                content = content_str;
              },
              test_cases ))

(* Check if a field path is blacklisted *)
let is_blacklisted (path : field_path) (blacklist : field_path list) : bool =
  (* Check if path starts with any blacklisted prefix - logic simplified for structured paths if needed *)
  (* For now, exact match or simple containment *)
  List.mem path blacklist

(* Mutate JSON input files based on mutation constraints.
   Returns paths to the mutated files (or originals if mutation failed). *)
let mutate_json_input ~(output_dir : string) (test_case_id : test_case_id)
    (constraints : mutation_constraint list) (blacklisted : field_path list)
    (pre_json_path : string) (block_json_path : string) : string * string =
  (* Create mutation-specific directory within output_dir *)
  let flat_test_id =
    String.map (fun c -> if c = '/' then '_' else c) test_case_id
  in
  let mutation_dir = Filename.concat output_dir flat_test_id in
  (* Ensure mutation directory exists *)
  (try Unix.mkdir mutation_dir 0o755
   with Unix.Unix_error (Unix.EEXIST, _, _) -> ());

  (* Load JSON files *)
  let pre_json =
    try Some (Json_mutator.load_json pre_json_path) with _ -> None
  in
  let block_json =
    try Some (Json_mutator.load_json block_json_path) with _ -> None
  in

  match (pre_json, block_json) with
  | None, _ | _, None ->
      (* Could not load files, return original paths *)
      (pre_json_path, block_json_path)
  | Some pre, Some block ->
      (* Apply mutations, skipping blacklisted fields and respecting source file *)
      let apply_constraints json target_source =
        List.fold_left
          (fun json_acc constraint_ ->
            if is_blacklisted constraint_.field_path blacklisted then json_acc
            else
              match constraint_.field_path.source with
              | Dep.State when target_source = "state" -> (
                  (* Path matches target source, apply mutation to rest of path *)
                  match constraint_.strategies with
                  | [] -> json_acc
                  | strategy :: _ ->
                      Json_mutator.mutate_json_file json_acc
                        constraint_.field_path strategy)
              | Dep.Block when target_source = "block" -> (
                  (* Path matches target source, apply mutation to rest of path *)
                  match constraint_.strategies with
                  | [] -> json_acc
                  | strategy :: _ ->
                      Json_mutator.mutate_json_file json_acc
                        constraint_.field_path strategy)
              | _ -> json_acc (* Constraint is for other file, skip *))
          json constraints
      in
      let mutated_pre = apply_constraints pre "state" in
      let mutated_block = apply_constraints block "block" in

      (* Save mutated JSON files as pre.json and block.json in the mutation directory *)
      let output_pre_path = Filename.concat mutation_dir "pre.json" in
      let output_block_path = Filename.concat mutation_dir "block.json" in
      Json_mutator.save_json output_pre_path mutated_pre;
      Json_mutator.save_json output_block_path mutated_block;
      (output_pre_path, output_block_path)

(* Get blacklisted fields from path condition for a premise.
   Path condition results are now organized per-premise with blacklists. *)
let get_blacklisted_fields (premise_uid : premise_uid)
    (_coverage : Instrumentation.Node_coverage_il.result option)
    (path_condition : Instrumentation.Dependency.Negative.result option) :
    field_path list =
  match path_condition with
  | None -> []
  | Some pc -> (
      (* Find blacklists for this premise UID *)
      match List.assoc_opt premise_uid pc.blacklists with
      | None -> []
      | Some path_conditions ->
          (* Flatten all path conditions and convert field_paths to string lists *)
          List.flatten path_conditions)

(* Generate test case for a selected premise.
   
   Parameters:
   - premise_uid: The UID of the premise to target
   - coverage: Coverage data for premise-to-test mapping
   - dependency: Positive analysis results for mutation suggestions
   - path_condition: Path condition results for blacklist
   - base_test_case_id: Optional specific test case to use as base
   - test_dir: Directory containing test case JSON files
   - output_dir: Directory to write mutated files
   
   Returns: List of (mutation_id, mutated_pre_path, mutated_block_path)
*)
let generate_test_case ~(test_dir : string) ~(output_dir : string)
    (premise_uid : premise_uid)
    (coverage : Instrumentation.Node_coverage_il.result option)
    (dependency : Instrumentation.Dependency.Positive.result option)
    (_path_condition : Instrumentation.Dependency.Negative.result option)
    (base_test_case_id : test_case_id option) : (string * string * string) list
    =
  (* Get mutation constraints *)
  let constraints =
    infer_mutation_constraints premise_uid coverage dependency
  in
  (* Negative analysis disabled as per plan *)
  let blacklisted =
    []
    (* get_blacklisted_fields premise_uid coverage path_condition *)
  in
  (* Find a base test case to mutate *)
  let test_case_id_opt =
    match base_test_case_id with
    | Some id -> Some id
    | None -> (
        match get_test_cases_for_premise premise_uid coverage with
        | [] -> None (* No test cases - skip this premise *)
        | first :: _ -> Some first)
  in

  match test_case_id_opt with
  | None -> [] (* Skip when no test cases available *)
  | Some test_id_raw ->
      (* Sanitize test_id: remove /pre.json suffix if present *)
      let test_id =
        if String.ends_with ~suffix:"/pre.json" test_id_raw then
          String.sub test_id_raw 0 (String.length test_id_raw - 9)
        else test_id_raw
      in

      (* test_id is the full path like "eth-tests-sanity/.../pre.json"
         We need to construct paths to pre.json and block.json *)
      let base_path =
        if Filename.check_suffix test_id ".json" then
          Filename.chop_extension test_id
        else test_id
      in
      let base_path =
        if Filename.check_suffix base_path "_pre" then
          Filename.chop_suffix base_path "_pre"
        else if Filename.check_suffix base_path "_block" then
          Filename.chop_suffix base_path "_block"
        else base_path
      in

      let pre_path = Filename.concat test_dir (base_path ^ "_pre.json") in
      let block_path = Filename.concat test_dir (base_path ^ "_block.json") in

      (* Create premise-specific output directory *)
      let premise_output_dir =
        Filename.concat output_dir (Printf.sprintf "premise_%d" premise_uid)
      in
      (try Unix.mkdir premise_output_dir 0o755
       with Unix.Unix_error (Unix.EEXIST, _, _) -> ());

      (* Load JSON for value extraction *)
      let pre_json_opt =
        try Some (Json_mutator.load_json pre_path) with _ -> None
      in
      let block_json_opt =
        try Some (Json_mutator.load_json block_path) with _ -> None
      in

      (* Prepare report file *)
      let report_path = Filename.concat premise_output_dir "report.txt" in
      let report_channel = open_out report_path in
      Printf.fprintf report_channel "Mutation Report for Premise UID %d\n"
        premise_uid;
      Printf.fprintf report_channel "Base Test Case: %s\n\n" test_id;

      (* Iterate over constraints and strategies *)
      let generated_files = ref [] in
      List.iteri
        (fun c_idx constraint_ ->
          (* Check source value first - if not found, skip mutations *)
          let source_value_opt =
            match
              (constraint_.field_path.source, pre_json_opt, block_json_opt)
            with
            | Dep.State, Some pre_json, _ ->
                Json_mutator.get_value_at_path pre_json constraint_.field_path
            | Dep.Block, _, Some block_json ->
                Json_mutator.get_value_at_path block_json constraint_.field_path
            | Dep.Local _, Some pre_json, _ -> (
                (* Try state JSON first for local variables *)
                match
                  Json_mutator.get_value_at_path pre_json constraint_.field_path
                with
                | Some v -> Some v
                | None -> (
                    (* Fallback to block JSON *)
                    match block_json_opt with
                    | Some block_json ->
                        Json_mutator.get_value_at_path block_json
                          constraint_.field_path
                    | None -> None))
            | _ -> None
          in

          match source_value_opt with
          | None ->
              (* Source not found - just report and skip mutations *)
              Printf.fprintf report_channel "Field Path: %s\n"
                (Instrumentation.Dependency.Dep_common.string_of_field_path
                   constraint_.field_path);
              (match constraint_.suggestion_str with
              | Some suggestion ->
                  Printf.fprintf report_channel "  Suggestion: %s\n" suggestion
              | None -> ());
              (match constraint_.field_path.source with
              | Dep.State ->
                  Printf.fprintf report_channel "  From: <not found in state>\n"
              | Dep.Block ->
                  Printf.fprintf report_channel "  From: <not found in block>\n"
              | _ -> Printf.fprintf report_channel "  From: <not found>\n");
              Printf.fprintf report_channel "\n"
          | Some _source_value ->
              (* Source found - generate mutations *)
              List.iteri
                (fun s_idx strategy ->
                  let mut_id =
                    Printf.sprintf "%s_mut%d_%d"
                      (String.map (fun c -> if c = '/' then '_' else c) test_id)
                      c_idx s_idx
                  in
                  let single_constraint =
                    { constraint_ with strategies = [ strategy ] }
                  in

                  (* Mutate and save *)
                  let out_pre, out_block =
                    mutate_json_input ~output_dir:premise_output_dir mut_id
                      [ single_constraint ] blacklisted pre_path block_path
                  in

                  (* Record generated files if successful (paths different from input) *)
                  if out_pre <> pre_path then (
                    generated_files :=
                      (mut_id, out_pre, out_block) :: !generated_files;

                    (* Write to report *)
                    Printf.fprintf report_channel "Mutation ID: %s\n" mut_id;
                    Printf.fprintf report_channel "  Field Path: %s\n"
                      (Instrumentation.Dependency.Dep_common
                       .string_of_field_path constraint_.field_path);
                    (match constraint_.suggestion_str with
                    | Some suggestion ->
                        Printf.fprintf report_channel "  Suggestion: %s\n"
                          suggestion
                    | None -> ());
                    Printf.fprintf report_channel "  Strategy: %s\n"
                      (match strategy with
                      | Json_mutator.SetValue _ -> "SetValue"
                      | Json_mutator.Increment i ->
                          Printf.sprintf "Increment %d" i
                      | Json_mutator.Decrement i ->
                          Printf.sprintf "Decrement %d" i
                      | Json_mutator.SetBoundary -> "SetBoundary"
                      | Json_mutator.AppendItem -> "AppendItem"
                      | Json_mutator.RemoveItem -> "RemoveItem");
                    Printf.fprintf report_channel "\n"))
                constraint_.strategies)
        constraints;

      close_out report_channel;
      List.rev !generated_files

(* Generate test cases for multiple premises *)
let generate_test_cases ~(test_dir : string) ~(output_dir : string)
    (premise_uids : premise_uid list)
    (coverage : Instrumentation.Node_coverage_il.result option)
    (dependency : Instrumentation.Dependency.Positive.result option)
    (path_condition : Instrumentation.Dependency.Negative.result option) :
    (premise_uid * (string * string * string) list) list =
  List.map
    (fun uid ->
      let results =
        generate_test_case ~test_dir ~output_dir uid coverage dependency
          path_condition None
      in
      (uid, results))
    premise_uids

(* Generate tests organized by test case (new test-case-centric approach).
   
   For each test case:
   1. Run on-demand positive dependency analysis with premise filtering
   2. Extract mutations per premise
   3. Generate mutated files in test_case directory
   4. Write enhanced report: [field, from_value, to_value]
   
   Returns: (test_case_id * (premise_uid * mutation_info list) list) list
*)
(* === Checkpoint Support for Testgen === *)

(* Load testgen checkpoint if resuming *)
let load_testgen_checkpoint (file : string) : Testgen_data.t =
  match Checkpoint.load_from_file ~file with
  | Ok checkpoint -> (
      match checkpoint.Checkpoint.coverage.testgen with
      | Some data -> data
      | None -> Testgen_data.empty)
  | Error _ -> Testgen_data.empty

(* Save testgen checkpoint *)
let save_testgen_checkpoint ~(file : string option) ~(analyzed : string list)
    ~(positive_result : Instrumentation.Dependency.Positive.result) : unit =
  match file with
  | None -> ()
  | Some checkpoint_file ->
      (* Create testgen data *)
      let testgen_data =
        Testgen_data.of_positive_result ~analyzed positive_result
      in

      (* Create coverage with testgen data *)
      let coverage =
        {
          Checkpoint.branch = None;
          node_il = None;
          node_sl = None;
          dependency = Some positive_result;
          path_condition = None;
          testgen = Some testgen_data;
        }
      in

      (* Create checkpoint manually *)
      let checkpoint =
        {
          Checkpoint.spec_hash = "";
          (* Empty hash for testgen-only checkpoint *)
          completed_inputs = analyzed;
          coverage;
          timestamp = Unix.gettimeofday ();
        }
      in

      (* Save to file *)
      Checkpoint.save_to_file ~file:checkpoint_file checkpoint;
      Format.printf "Saved testgen checkpoint: %s (%d tests analyzed)\n%!"
        checkpoint_file (List.length analyzed)

(* Filter test cases by seed type *)
let filter_by_seed_type (seed_filter : string option)
    (test_ids : (string * 'a) list) : (string * 'a) list =
  match seed_filter with
  | None -> test_ids
  | Some filter_type ->
      List.filter
        (fun (test_id, _) ->
          let lower_id = String.lowercase_ascii test_id in
          let lower_filter = String.lowercase_ascii filter_type in
          try
            let _ =
              Str.search_forward (Str.regexp_string lower_filter) lower_id 0
            in
            true
          with Not_found -> false)
        test_ids

(* === Test Generation === *)

let generate_tests_by_test_case ~(test_dir : string) ~(output_dir : string)
    (premise_uids : premise_uid list)
    (coverage : Instrumentation.Node_coverage_il.result option)
    (analyze_test_case :
      test_case_id ->
      premise_uid list ->
      Instrumentation.Dependency.Positive.result option) :
    (test_case_id * (premise_uid * (string * string * string) list) list) list =
  (* Get test_id -> premise_uids mapping *)
  let test_to_prems = get_test_to_premises premise_uids coverage in

  (* Process each test case *)
  List.filter_map
    (fun (test_id, prem_uids) ->
      Format.printf "Processing test case: %s (premises: %s)\n%!" test_id
        (String.concat ", " (List.map string_of_int prem_uids));

      (* Run on-demand analysis for this test case *)
      match analyze_test_case test_id prem_uids with
      | None ->
          Format.printf "  Skipped: analysis failed\n%!";
          None
      | Some dependency_result ->
          (* Create test case output directory *)
          let test_case_sanitized =
            String.map (fun c -> if c = '/' then '_' else c) test_id
          in
          let test_case_output_dir =
            Filename.concat output_dir test_case_sanitized
          in
          (try Unix.mkdir test_case_output_dir 0o755
           with Unix.Unix_error (Unix.EEXIST, _, _) -> ());

          (* Construct paths to base test case JSON files *)
          (* test_id includes /pre.json suffix, strip it to get the directory *)
          let test_case_dir =
            if String.ends_with ~suffix:"/pre.json" test_id then
              String.sub test_id 0 (String.length test_id - 9)
              (* Remove "/pre.json" *)
            else test_id
          in
          let pre_path =
            Filename.concat test_dir (test_case_dir ^ "/pre.json")
          in
          let block_path =
            Filename.concat test_dir (test_case_dir ^ "/block.json")
          in

          (* Load JSON for value extraction *)
          let pre_json_opt =
            try Some (Json_mutator.load_json pre_path) with _ -> None
          in
          let block_json_opt =
            try Some (Json_mutator.load_json block_path) with _ -> None
          in

          (* Open report file *)
          let report_path = Filename.concat test_case_output_dir "report.txt" in
          let report_channel = open_out report_path in
          Printf.fprintf report_channel "Test Case: %s\n\n" test_id;

          (* Process each premise *)
          let premise_results =
            List.filter_map
              (fun prem_uid ->
                (* Get mutations for this premise *)
                let constraints =
                  infer_mutation_constraints prem_uid coverage
                    (Some dependency_result)
                in

                if constraints = [] then (
                  Printf.fprintf report_channel
                    "Premise UID %d: No mutations found\n\n" prem_uid;
                  None)
                else (
                  Printf.fprintf report_channel "Premise UID %d:\n" prem_uid;

                  (* Generate mutations *)
                  let generated_files = ref [] in
                  List.iteri
                    (fun c_idx constraint_ ->
                      (* Check source value first - if not found, skip mutations *)
                      let source_value_opt =
                        match
                          ( constraint_.field_path.source,
                            pre_json_opt,
                            block_json_opt )
                        with
                        | Dep.State, Some pre_json, _ ->
                            Json_mutator.get_value_at_path pre_json
                              constraint_.field_path
                        | Dep.Block, _, Some block_json ->
                            Json_mutator.get_value_at_path block_json
                              constraint_.field_path
                        | Dep.Local _, Some pre_json, _ -> (
                            (* Try state JSON first for local variables *)
                            match
                              Json_mutator.get_value_at_path pre_json
                                constraint_.field_path
                            with
                            | Some v -> Some v
                            | None -> (
                                (* Fallback to block JSON *)
                                match block_json_opt with
                                | Some block_json ->
                                    Json_mutator.get_value_at_path block_json
                                      constraint_.field_path
                                | None -> None))
                        | _ -> None
                      in

                      match source_value_opt with
                      | None -> (
                          (* Source not found - just report and skip mutations *)
                          Printf.fprintf report_channel "  - Field: %s\n"
                            (Instrumentation.Dependency.Dep_common
                             .string_of_field_path constraint_.field_path);
                          (match constraint_.suggestion_str with
                          | Some suggestion ->
                              Printf.fprintf report_channel
                                "    Suggestion: %s\n" suggestion
                          | None -> ());
                          match constraint_.field_path.source with
                          | Dep.State ->
                              Printf.fprintf report_channel
                                "    From: <not found in state>\n"
                          | Dep.Block ->
                              Printf.fprintf report_channel
                                "    From: <not found in block>\n"
                          | _ ->
                              Printf.fprintf report_channel
                                "    From: <not found>\n")
                      | Some source_value ->
                          (* Source found - generate mutations *)
                          let source_value_str =
                            Yojson.Safe.to_string source_value
                          in
                          List.iteri
                            (fun s_idx strategy ->
                              let mut_id =
                                Printf.sprintf "mut_prem%d_%d_%d" prem_uid c_idx
                                  s_idx
                              in
                              let single_constraint =
                                { constraint_ with strategies = [ strategy ] }
                              in

                              (* Get destination value from strategy *)
                              let dest_value_str =
                                match strategy with
                                | Json_mutator.SetValue v ->
                                    Yojson.Safe.to_string v
                                | Json_mutator.Increment i ->
                                    Printf.sprintf "+%d" i
                                | Json_mutator.Decrement i ->
                                    Printf.sprintf "-%d" i
                                | Json_mutator.SetBoundary -> "<boundary>"
                                | Json_mutator.AppendItem -> "<append>"
                                | Json_mutator.RemoveItem -> "<remove>"
                              in

                              (* Mutate and save *)
                              let out_pre, out_block =
                                mutate_json_input
                                  ~output_dir:test_case_output_dir mut_id
                                  [ single_constraint ] [] pre_path block_path
                              in

                              (* Record if successful *)
                              if out_pre <> pre_path then (
                                generated_files :=
                                  (mut_id, out_pre, out_block)
                                  :: !generated_files;

                                (* Write to report *)
                                Printf.fprintf report_channel "  - Field: %s\n"
                                  (Instrumentation.Dependency.Dep_common
                                   .string_of_field_path constraint_.field_path);
                                (match constraint_.suggestion_str with
                                | Some suggestion ->
                                    Printf.fprintf report_channel
                                      "    Suggestion: %s\n" suggestion
                                | None -> ());
                                Printf.fprintf report_channel "    From: %s\n"
                                  source_value_str;
                                Printf.fprintf report_channel "    To: %s\n"
                                  dest_value_str))
                            constraint_.strategies)
                    constraints;

                  Printf.fprintf report_channel "\n";

                  if !generated_files = [] then None
                  else Some (prem_uid, List.rev !generated_files)))
              prem_uids
          in

          close_out report_channel;

          if premise_results = [] then None else Some (test_id, premise_results))
    test_to_prems

(* Generate tests with checkpoint support - resumable with progress tracking *)
let generate_tests_with_checkpoint ~(test_dir : string) ~(output_dir : string)
    ~(checkpoint_file : string option) ~(resume_file : string option)
    ~(save_interval : int) ~(filter_seeds : string option)
    ~(select_minimal : bool) (premise_uids : premise_uid list)
    (coverage : Instrumentation.Node_coverage_il.result option)
    (analyze_test_case :
      test_case_id ->
      premise_uid list ->
      Instrumentation.Dependency.Positive.result option) :
    (test_case_id * (premise_uid * (string * string * string) list) list) list =
  (* Load checkpoint if resuming *)
  let testgen_data =
    match resume_file with
    | Some file ->
        Format.printf "Resuming from checkpoint: %s\n%!" file;
        load_testgen_checkpoint file
    | None -> Testgen_data.empty
  in

  (* Get test_id -> premise_uids mapping *)
  let all_test_to_prems = get_test_to_premises premise_uids coverage in

  (* Filter by seed type if requested *)
  let filtered_test_to_prems =
    filter_by_seed_type filter_seeds all_test_to_prems
  in

  (* Apply minimal selection if requested *)
  let test_to_prems =
    if select_minimal then (
      Format.printf "Selecting minimal set of tests (greedy set cover)...\n%!";
      (* Build premise -> tests and test -> prems hashtables *)
      let prem_to_tests = Hashtbl.create 256 in
      let test_to_prems_tbl = Hashtbl.create 256 in
      List.iter
        (fun (test_id, prems) ->
          Hashtbl.replace test_to_prems_tbl test_id prems;
          List.iter
            (fun prem ->
              let existing =
                Hashtbl.find_opt prem_to_tests prem |> Option.value ~default:[]
              in
              if not (List.mem test_id existing) then
                Hashtbl.replace prem_to_tests prem (test_id :: existing))
            prems)
        filtered_test_to_prems;
      (* Run greedy set cover *)
      let selected =
        Source_selector.select_minimal_tests premise_uids prem_to_tests
          test_to_prems_tbl
      in
      Format.printf
        "Selected %d tests (from %d candidates) covering %d premises\n%!"
        (List.length selected)
        (List.length filtered_test_to_prems)
        (List.length premise_uids);
      selected)
    else filtered_test_to_prems
  in

  (* Filter out already-analyzed tests *)
  let test_ids = List.map fst test_to_prems in
  let remaining_test_ids =
    Testgen_data.filter_remaining testgen_data test_ids
  in
  let remaining_test_to_prems =
    List.filter
      (fun (test_id, _) -> List.mem test_id remaining_test_ids)
      test_to_prems
  in

  Format.printf "Total tests: %d, Already analyzed: %d, Remaining: %d\n%!"
    (List.length test_ids)
    (List.length test_ids - List.length remaining_test_ids)
    (List.length remaining_test_ids);

  (* Track analyzed tests for checkpoint *)
  let analyzed = ref (Testgen_data.analyzed_tests testgen_data) in
  let last_dep_result = ref None in

  (* Calculate starting position for progress display *)
  let already_completed =
    List.length test_ids - List.length remaining_test_ids
  in
  let total_tests = List.length test_ids in

  (* Process each test case with periodic checkpointing *)
  let results =
    List.mapi
      (fun idx (test_id, prem_uids) ->
        (* Show absolute progress: already_completed + current position *)
        Format.printf "[%d/%d] Processing test case: %s\n%!"
          (already_completed + idx + 1)
          total_tests test_id;

        (* Run analysis *)
        let result_opt = analyze_test_case test_id prem_uids in
        (match result_opt with
        | Some dep_result -> last_dep_result := Some dep_result
        | None -> ());

        (* Track as analyzed *)
        analyzed := test_id :: !analyzed;

        (* Periodic checkpoint save *)
        if (idx + 1) mod save_interval = 0 then (
          Format.printf "Saving checkpoint at test %d/%d...\n%!" (idx + 1)
            (List.length remaining_test_to_prems);
          match result_opt with
          | Some dep_result ->
              save_testgen_checkpoint ~file:checkpoint_file ~analyzed:!analyzed
                ~positive_result:dep_result;
              Instrumentation.Dependency.Positive.clear_memory ()
          | None -> ());

        (* Generate mutations if analysis succeeded *)
        match result_opt with
        | None ->
            Format.printf "  Skipped: analysis failed\n%!";
            None
        | Some dependency_result ->
            let test_case_sanitized =
              String.map (fun c -> if c = '/' then '_' else c) test_id
            in
            let test_case_output_dir =
              Filename.concat output_dir test_case_sanitized
            in
            Unix.mkdir test_case_output_dir 0o755;

            (* test_id is like "eth-tests-sanity/.../full_random_operations_3/pre.json"
               The actual files are pre.json and block.json in the same directory.
               We need to replace /pre.json with /pre.json or /block.json *)
            let pre_path = Filename.concat test_dir test_id in
            let block_path =
              if Filename.check_suffix test_id "/pre.json" then
                Filename.concat test_dir
                  (Filename.chop_suffix test_id "/pre.json" ^ "/block.json")
              else if Filename.check_suffix test_id "/block.json" then
                Filename.concat test_dir
                  (Filename.chop_suffix test_id "/block.json" ^ "/pre.json")
              else
                (* Fallback: assume test_id is the directory, append /block.json *)
                Filename.concat test_dir (test_id ^ "/block.json")
            in

            let pre_json_opt =
              try Some (Json_mutator.load_json pre_path)
              with e ->
                Format.printf "[DEBUG] Failed to load pre_path: %s\n%!"
                  (Printexc.to_string e);
                None
            in
            let block_json_opt =
              try Some (Json_mutator.load_json block_path)
              with e ->
                Format.printf "[DEBUG] Failed to load block_path: %s\n%!"
                  (Printexc.to_string e);
                None
            in

            let report_path =
              Filename.concat test_case_output_dir "report.txt"
            in
            let report_channel = open_out report_path in
            Printf.fprintf report_channel "Test Case: %s\n\n" test_id;

            let premise_results =
              List.filter_map
                (fun prem_uid ->
                  let constraints =
                    infer_mutation_constraints prem_uid coverage
                      (Some dependency_result)
                  in
                  if constraints = [] then (
                    Printf.fprintf report_channel
                      "Premise UID %d: No mutations found\n\n" prem_uid;
                    None)
                  else (
                    Printf.fprintf report_channel "Premise UID %d:\n" prem_uid;
                    let generated_files = ref [] in
                    List.iteri
                      (fun c_idx constraint_ ->
                        (* Check source value first - if not found, skip mutations *)
                        let source_value_opt =
                          match
                            ( constraint_.field_path.source,
                              pre_json_opt,
                              block_json_opt )
                          with
                          | Dep.State, Some pre_json, _ ->
                              Json_mutator.get_value_at_path pre_json
                                constraint_.field_path
                          | Dep.Block, _, Some block_json ->
                              Json_mutator.get_value_at_path block_json
                                constraint_.field_path
                          | Dep.Local _, Some pre_json, _ -> (
                              (* Try state JSON first for local variables *)
                              match
                                Json_mutator.get_value_at_path pre_json
                                  constraint_.field_path
                              with
                              | Some v -> Some v
                              | None -> (
                                  (* Fallback to block JSON *)
                                  match block_json_opt with
                                  | Some block_json ->
                                      Json_mutator.get_value_at_path block_json
                                        constraint_.field_path
                                  | None -> None))
                          | _ -> None
                        in

                        match source_value_opt with
                        | None -> (
                            (* Source not found - just report and skip mutations *)
                            Printf.fprintf report_channel "  - Field: %s\n"
                              (Instrumentation.Dependency.Dep_common
                               .string_of_field_path constraint_.field_path);
                            (match constraint_.suggestion_str with
                            | Some suggestion ->
                                Printf.fprintf report_channel
                                  "    Suggestion: %s\n" suggestion
                            | None -> ());
                            match constraint_.field_path.source with
                            | Dep.State ->
                                Printf.fprintf report_channel
                                  "    From: <not found in state>\n"
                            | Dep.Block ->
                                Printf.fprintf report_channel
                                  "    From: <not found in block>\n"
                            | _ ->
                                Printf.fprintf report_channel
                                  "    From: <not found>\n")
                        | Some source_value ->
                            (* Source found - generate mutations *)
                            let source_value_str =
                              Yojson.Safe.to_string source_value
                            in
                            List.iteri
                              (fun s_idx strategy ->
                                let mut_id =
                                  Printf.sprintf "mut_prem%d_%d_%d" prem_uid
                                    c_idx s_idx
                                in
                                let single_constraint =
                                  { constraint_ with strategies = [ strategy ] }
                                in

                                (* Get destination value from strategy *)
                                let dest_value_str =
                                  match strategy with
                                  | Json_mutator.SetValue v ->
                                      Yojson.Safe.to_string v
                                  | Json_mutator.Increment i ->
                                      Printf.sprintf "+%d" i
                                  | Json_mutator.Decrement i ->
                                      Printf.sprintf "-%d" i
                                  | Json_mutator.SetBoundary -> "<boundary>"
                                  | Json_mutator.AppendItem -> "<append>"
                                  | Json_mutator.RemoveItem -> "<remove>"
                                in

                                (* Mutate and save *)
                                let out_pre, out_block =
                                  mutate_json_input
                                    ~output_dir:test_case_output_dir mut_id
                                    [ single_constraint ] [] pre_path block_path
                                in

                                (* Record if successful *)
                                if out_pre <> pre_path then (
                                  generated_files :=
                                    (mut_id, out_pre, out_block)
                                    :: !generated_files;

                                  (* Write to report *)
                                  Printf.fprintf report_channel
                                    "  - Field: %s\n"
                                    (Instrumentation.Dependency.Dep_common
                                     .string_of_field_path
                                       constraint_.field_path);
                                  (match constraint_.suggestion_str with
                                  | Some suggestion ->
                                      Printf.fprintf report_channel
                                        "    Suggestion: %s\n" suggestion
                                  | None -> ());
                                  Printf.fprintf report_channel "    From: %s\n"
                                    source_value_str;
                                  Printf.fprintf report_channel "    To: %s\n"
                                    dest_value_str))
                              constraint_.strategies)
                      constraints;

                    Printf.fprintf report_channel "\n";

                    if !generated_files = [] then None
                    else Some (prem_uid, List.rev !generated_files)))
                prem_uids
            in

            close_out report_channel;
            if premise_results = [] then None
            else Some (test_id, premise_results))
      remaining_test_to_prems
    |> List.filter_map Fun.id
  in

  (* Final checkpoint save *)
  (match checkpoint_file with
  | Some _ when results <> [] -> (
      Format.printf "Saving final checkpoint...\n%!";
      match !last_dep_result with
      | Some dep_result ->
          save_testgen_checkpoint ~file:checkpoint_file ~analyzed:!analyzed
            ~positive_result:dep_result
      | None -> ())
  | _ -> ());

  results
