open Common.Source
module Il = Lang.Il

(* === Types === *)

(* Field path types - duplicated to avoid circular dependency *)
type input_source = State | Block | Unknown

type index_expr = ConstInt of int | PathRef of field_path
and field_step = FieldAccess of string | IndexAccess of index_expr
and field_path = { source : input_source; steps : field_step list }

(* Block input pattern - describes what part of block a relation takes *)

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
  input_types : Il.typ list; (* Types of input variables *)
  input_positions : int list; (* Which positions are inputs *)
  block_pattern : block_input_pattern option; (* Block input pattern, if any *)
}

(* Analysis result - simplified *)
type analysis_result = (string, relation_input_info) Hashtbl.t

(* === State === *)

module State = struct
  let relation_inputs : (string, relation_input_info) Hashtbl.t =
    Hashtbl.create 50

  let reset () = Hashtbl.clear relation_inputs
end

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
let extract_relation_input_info (_id : string) (arg_types : Il.typ list)
    (input_hints : int list) (rules : Il.rule list) : relation_input_info option
    =
  (* Get input expressions from first rule's notexp *)
  let rule = List.hd rules in
  let _, notexp, _ = rule.it in
  let _, exps = notexp in

  (* Combined extraction of expressions and types based on indices *)
  let exps_input, types_input =
    let indexed =
      List.combine exps arg_types
      |> List.mapi (fun idx (exp, typ) -> (idx, exp, typ))
    in
    let filtered =
      List.filter (fun (idx, _, _) -> List.mem idx input_hints) indexed
    in
    ( List.map (fun (_, e, _) -> e) filtered,
      List.map (fun (_, _, t) -> t) filtered )
  in

  (* Extract variable names and types, keeping them aligned *)
  let input_vars, input_types =
    List.combine exps_input types_input
    |> List.filter_map (fun (exp, typ) ->
           match extract_var_name exp with
           | Some name -> Some (name, typ)
           | None -> None)
    |> List.split
  in

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
      input_types;
      input_positions = input_hints;
      block_pattern;
    }

(* === Static Analysis Interface === *)

let init spec =
  State.reset ();
  match spec with
  | Static.IlSpec il_spec ->
      List.iter
        (fun def ->
          match def.it with
          | Il.RelD (id, nottyp, input_hints, rules) -> (
              let _, arg_types = nottyp.it in
              match
                extract_relation_input_info id.it arg_types input_hints rules
              with
              | Some input_info ->
                  Hashtbl.replace State.relation_inputs id.it input_info
              | None -> ())
          (* We don't analyze functions (DecD) anymore as we only care about relation inputs *)
          | _ -> ())
        il_spec
  | Static.SlSpec _ -> ()

let reset () = State.reset ()
let export () = Some (Hashtbl.to_seq State.relation_inputs |> List.of_seq)

let restore relation_inputs_list =
  State.reset ();
  List.iter
    (fun (k, v) -> Hashtbl.replace State.relation_inputs k v)
    relation_inputs_list

(* Get relation input info *)
let get_relation_input_info (relation_id : string) : relation_input_info option
    =
  Hashtbl.find_opt State.relation_inputs relation_id

(* Print analysis results for debugging *)
let print_results (fmt : Format.formatter) : unit =
  Format.fprintf fmt "@.=== Mutator Analysis Results ===@.";
  Format.fprintf fmt "@.Relation Inputs (%d):@."
    (Hashtbl.length State.relation_inputs);
  Hashtbl.iter
    (fun rel_id info ->
      Format.fprintf fmt "  %s: %s@." rel_id
        (String.concat ", " info.input_var_names);
      Format.fprintf fmt "    Types: %s@."
        (String.concat ", " (List.map Il.Print.string_of_typ info.input_types)))
    State.relation_inputs;
  Format.fprintf fmt "@."

(* Implement Static.S signature as submodule (for static_dependencies) *)
module Mutator_analysis : Static.S = struct
  type export_data = (string * relation_input_info) list

  let name = "mutator_analysis"
  let init = init
  let reset = reset
  let export () = export ()
  let restore data = restore data
end
