(* Testgen checkpoint data - serializable state for test generation across runs.
   
   This module defines the data structures that can be saved to and restored from
   checkpoints, enabling resumable test generation without re-running analysis. *)

open Instrumentation.Dependency

(* Serialized mutation suggestion - simplified for marshaling *)
type mutation_suggestion_serial =
  | ToValueSerial of string (* Serialized symbolic expression *)
  | ToRelationSerial of
      Dep_common.field_path * string (* field_path, serialized sym_expr *)
  | UnresolvedSerial of string (* Reason *)

(* Serialized mutation - can be marshaled *)
type mutation_serial = {
  target_path : Dep_common.field_path option;
  suggestion : mutation_suggestion_serial;
  mutation_target : Dep_common.mutation_target;
  debug_info : string option;
}
[@@warning "-69"]
(* Fields used for serialization *)

(* Main checkpoint data structure *)
type t = {
  (* Tests already analyzed (for resume support) *)
  analyzed_tests : string list;
  (* Mapping from premise UID to test IDs that covered it *)
  premise_to_tests : (int * string list) list;
  (* Mapping from premise UID to test ID to mutations *)
  premise_to_mutations : (int * (string * mutation_serial list) list) list;
}

let empty =
  { analyzed_tests = []; premise_to_tests = []; premise_to_mutations = [] }

(* Filter out already-analyzed tests from a list *)
let filter_remaining (data : t) (all_tests : string list) : string list =
  let analyzed_set = Hashtbl.create (List.length data.analyzed_tests) in
  List.iter (fun t -> Hashtbl.replace analyzed_set t ()) data.analyzed_tests;
  List.filter (fun t -> not (Hashtbl.mem analyzed_set t)) all_tests

(* Convert Positive.sym_mutation to serializable form *)
let serialize_mutation (mut : Positive.sym_mutation) : mutation_serial =
  let serialize_suggestion = function
    | Positive.ToValue sym_expr ->
        ToValueSerial (Positive.string_of_sym_expr sym_expr)
    | Positive.ToRelation (_op, sym_expr) ->
        (* For now, just serialize the sym_expr string *)
        let path = { Dep_common.source = Dep_common.Unknown; steps = [] } in
        ToRelationSerial (path, Positive.string_of_sym_expr sym_expr)
    | Positive.Unresolved reason -> UnresolvedSerial reason
  in
  {
    target_path = mut.target_path;
    suggestion = serialize_suggestion mut.suggestion;
    mutation_target = mut.mutation_target;
    debug_info = mut.debug_info;
  }

(* Convert from Positive.result to serializable form *)
let of_positive_result ?(analyzed : string list = []) (result : Positive.result)
    : t =
  {
    analyzed_tests = analyzed;
    premise_to_tests = [];
    premise_to_mutations =
      List.map
        (fun (uid, test_muts) ->
          let serialized_test_muts =
            List.map
              (fun (test_id, muts) ->
                (test_id, List.map serialize_mutation muts))
              test_muts
          in
          (uid, serialized_test_muts))
        result.per_test_sym_mutations;
  }

(* Merge two testgen data structures *)
let merge (t1 : t) (t2 : t) : t =
  (* Merge premise_to_tests *)
  let merged_tests = Hashtbl.create 256 in
  List.iter
    (fun (uid, tests) -> Hashtbl.replace merged_tests uid tests)
    t1.premise_to_tests;
  List.iter
    (fun (uid, tests) ->
      let existing =
        Hashtbl.find_opt merged_tests uid |> Option.value ~default:[]
      in
      let combined = existing @ tests |> List.sort_uniq String.compare in
      Hashtbl.replace merged_tests uid combined)
    t2.premise_to_tests;

  (* Merge premise_to_mutations *)
  let merged_mutations = Hashtbl.create 256 in
  List.iter
    (fun (uid, test_muts) -> Hashtbl.replace merged_mutations uid test_muts)
    t1.premise_to_mutations;
  List.iter
    (fun (uid, test_muts) ->
      let existing =
        Hashtbl.find_opt merged_mutations uid |> Option.value ~default:[]
      in
      let combined = existing @ test_muts in
      Hashtbl.replace merged_mutations uid combined)
    t2.premise_to_mutations;

  (* Merge analyzed_tests *)
  let analyzed =
    t1.analyzed_tests @ t2.analyzed_tests |> List.sort_uniq String.compare
  in
  {
    analyzed_tests = analyzed;
    premise_to_tests = Hashtbl.to_seq merged_tests |> List.of_seq;
    premise_to_mutations = Hashtbl.to_seq merged_mutations |> List.of_seq;
  }

(* Accessor for analyzed tests *)
let analyzed_tests t = t.analyzed_tests
