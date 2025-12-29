open Lang
open Lang.Il
open Pass
open Interface
open Interp
open Common.Source
module Error = Error

type 'a pipeline_result = ('a, Error.t) result

let ( let* ) = Result.bind

module Handlers = struct
  let il f =
    let vid_counter = ref 0 in
    let tid_counter = ref 0 in
    Effect.Deep.try_with f ()
      {
        effc =
          (fun (type a) (eff : a Effect.t) ->
            match eff with
            | Effects.FreshVid ->
                Some
                  (fun (k : (a, _) Effect.Deep.continuation) ->
                    let id = !vid_counter in
                    incr vid_counter;
                    Effect.Deep.continue k (fun () -> id))
            | Effects.FreshTid ->
                Some
                  (fun (k : (a, _) Effect.Deep.continuation) ->
                    let tid = "FRESH__" ^ string_of_int !tid_counter in
                    incr tid_counter;
                    Effect.Deep.continue k (fun () -> tid))
            | Effects.ValueCreated _ ->
                Some
                  (fun (k : (a, _) Effect.Deep.continuation) ->
                    (* No-op *)
                    Effect.Deep.continue k ())
            | _ -> None (* Other effects *));
      }

  (* SL interpreter uses IL handler for now *)
  let sl = il
end

(* --- General runners --- *)

(* Transformations *)

let parse_spec_files filenames : El.spec pipeline_result =
  let parse_spec_files () =
    List.concat_map Frontend.Parse.parse_file filenames |> Result.ok
  in
  try parse_spec_files ()
  with Frontend.Error.ParseError (at, msg) ->
    Error.ParseError (at, msg) |> Result.error

let elaborate spec_el : Il.spec pipeline_result =
  let elaborate () =
    Elaborate.Elab.elab_spec spec_el
    |> Result.map_error (fun elab_err_list -> Error.ElabError elab_err_list)
  in
  try elaborate ()
  with Elaborate.Error.ElabError (at, failtraces) ->
    Error.ElabError [ (at, failtraces) ] |> Result.error

let structure spec_il : Sl.spec = Structure.Struct.struct_spec spec_il

(* Interpreters *)

(* Core IL run function - no init/finish, used by both single and suite runners *)
let eval_il_run spec_il rid values_input filename_target :
    (Eval_Il.Ctx.t * Il.Value.t list) pipeline_result =
  let run () =
    Eval_Il.Runner.run_relation_fresh spec_il rid values_input filename_target
    |> Result.ok
  in
  try Handlers.il run
  with Eval_Il.Error.InterpError (at, msg) ->
    Error.IlInterpError (at, msg) |> Result.error

(* Core SL run function - no init/finish, used by both single and suite runners *)
let eval_sl_run spec_sl rid values_input filename_target :
    (Eval_Sl.Ctx.t * Il.Value.t list) pipeline_result =
  let run () =
    Eval_Sl.Runner.run_relation_fresh spec_sl rid values_input filename_target
    |> Result.ok
  in
  try Handlers.sl run
  with Eval_Sl.Error.InterpError (at, msg) ->
    Error.SlInterpError (at, msg) |> Result.error

(* Single-run wrappers that set up handlers, init, run, and finish *)
let eval_il ?(config = Instrumentation.Config.default) spec_il rid values_input
    filename_target : (Eval_Il.Ctx.t * Il.Value.t list) pipeline_result =
  let handlers = Instrumentation.Config.to_handlers config in
  Instrumentation.Hooks.set_handlers handlers;
  Instrumentation.Hooks.init ~spec:(Instrumentation.Hooks.IlSpec spec_il);
  let result = eval_il_run spec_il rid values_input filename_target in
  Instrumentation.Hooks.finish ();
  result

let eval_sl ?(config = Instrumentation.Config.default) spec_sl rid values_input
    filename_target : (Eval_Sl.Ctx.t * Il.Value.t list) pipeline_result =
  let handlers = Instrumentation.Config.to_handlers config in
  Instrumentation.Hooks.set_handlers handlers;
  Instrumentation.Hooks.init ~spec:(Instrumentation.Hooks.SlSpec spec_sl);
  let result = eval_sl_run spec_sl rid values_input filename_target in
  Instrumentation.Hooks.finish ();
  result

(* Coverage suite runners - init once, run all files, finish once *)

type suite_result = { passed : int; failed : int; total : int }
type suite_input = (string * Il.Value.t list * string, Error.t) result

(* General IL suite runner - takes a list of result-wrapped inputs *)
let eval_il_suite ?(config = Instrumentation.Config.default) spec_il
    (inputs : suite_input list) : suite_result =
  let handlers = Instrumentation.Config.to_handlers config in
  Instrumentation.Hooks.set_handlers handlers;
  Instrumentation.Hooks.init ~spec:(Instrumentation.Hooks.IlSpec spec_il);
  let passed, failed =
    List.fold_left
      (fun (p, f) input ->
        match input with
        | Error _ -> (p, f + 1)
        | Ok (rid, values, filename) -> (
            let result = eval_il_run spec_il rid values filename in
            match result with Ok _ -> (p + 1, f) | Error _ -> (p, f + 1)))
      (0, 0) inputs
  in
  Instrumentation.Hooks.finish ();
  { passed; failed; total = List.length inputs }

(* General SL suite runner - takes a list of result-wrapped inputs *)
let eval_sl_suite ?(config = Instrumentation.Config.default) spec_sl
    (inputs : suite_input list) : suite_result =
  let handlers = Instrumentation.Config.to_handlers config in
  Instrumentation.Hooks.set_handlers handlers;
  Instrumentation.Hooks.init ~spec:(Instrumentation.Hooks.SlSpec spec_sl);
  let passed, failed =
    List.fold_left
      (fun (p, f) input ->
        match input with
        | Error _ -> (p, f + 1)
        | Ok (rid, values, filename) -> (
            let result = eval_sl_run spec_sl rid values filename in
            match result with Ok _ -> (p + 1, f) | Error _ -> (p, f + 1)))
      (0, 0) inputs
  in
  Instrumentation.Hooks.finish ();
  { passed; failed; total = List.length inputs }

(* --- P4 runners --- *)

(* P4 Parsing *)

let parse_p4_file includes_target filename_target : Il.Value.t pipeline_result =
  let parse_p4_file () =
    P4.Parse.parse_file includes_target filename_target |> Result.ok
  in
  try Handlers.il parse_p4_file
  with P4.Error.P4ParseError (at, msg) ->
    Error.P4ParseError (at, msg) |> Result.error

let parse_p4_string filename_target string : Il.Value.t pipeline_result =
  let parse_p4_string () =
    P4.Parse.parse_string filename_target string |> Result.ok
  in
  try Handlers.il parse_p4_string
  with P4.Error.P4ParseError (at, msg) ->
    Error.P4ParseError (at, msg) |> Result.error

(* Composed functions *)

let eval_il_p4_typechecker ?(config = Instrumentation.Config.default) spec_il
    includes_target filename_target :
    (Eval_Il.Ctx.t * Il.Value.t list) pipeline_result =
  let* value_program = parse_p4_file includes_target filename_target in
  eval_il ~config spec_il "Program_ok" [ value_program ] filename_target

let eval_sl_p4_typechecker ?(config = Instrumentation.Config.default) spec_sl
    includes_target filename_target :
    (Eval_Sl.Ctx.t * Il.Value.t list) pipeline_result =
  let* value_program = parse_p4_file includes_target filename_target in
  eval_sl ~config spec_sl "Program_ok" [ value_program ] filename_target

(* P4 coverage suite functions - compose P4 parsing with general suite runners *)

let eval_il_suite_p4_typechecker ?(config = Instrumentation.Config.default)
    spec_il includes_target filenames : suite_result =
  let inputs =
    List.map
      (fun filename ->
        parse_p4_file includes_target filename
        |> Result.map (fun value -> ("Program_ok", [ value ], filename)))
      filenames
  in
  eval_il_suite ~config spec_il inputs

let eval_sl_suite_p4_typechecker ?(config = Instrumentation.Config.default)
    spec_sl includes_target filenames : suite_result =
  let inputs =
    List.map
      (fun filename ->
        parse_p4_file includes_target filename
        |> Result.map (fun value -> ("Program_ok", [ value ], filename)))
      filenames
  in
  eval_sl_suite ~config spec_sl inputs

let parse_p4_file_with_roundtrip roundtrip filenames_spec includes_target
    filename_target : string pipeline_result =
  let* spec_el = parse_spec_files filenames_spec in
  let* spec_il = elaborate spec_el in
  let* value_program = parse_p4_file includes_target filename_target in
  let unparsed_string =
    Format.asprintf "%a\n" (Concrete.Pp.pp_program spec_il) value_program
  in
  if roundtrip then
    let* value_program_rt = parse_p4_string filename_target unparsed_string in
    let eq = Il.Eq.eq_value ~dbg:true value_program value_program_rt in
    if eq then unparsed_string |> Result.ok
    else Error.RoundtripError (no_region, "Roundtrip failed") |> Result.error
  else unparsed_string |> Result.ok

(* --- Ethereum runners --- *)

(* JSON parsing *)

let parse_json filename_target input_type spec_il : Il.Value.t pipeline_result =
  let parse_json () =
    let ctx_init = Eval_Il.Ctx.empty filename_target in
    let ctx = Eval_Il.Interp.load_spec ctx_init spec_il in
    let json_data = Yojson.Safe.from_file filename_target in
    let* value_il =
      Interface.JSON.Parse.json_to_value ctx.global.tdenv
        (Il.Typ.var input_type []) json_data
      |> Result.map_error (fun err ->
             let msg = Interface.JSON.Parse.string_of_error err in
             Error.JsonParseError (no_region, msg))
    in
    Ok value_il
  in
  Handlers.il parse_json

(* let print_json values *)

let eval_il_eth ?(config = Instrumentation.Config.default) spec_il ~validate
    pre_state block : (Eval_Il.Ctx.t * Il.Value.t list) pipeline_result =
  let* beaconState_il = parse_json pre_state "beaconState" spec_il in
  let* block_il = parse_json block "signedBeaconBlock" spec_il in
  eval_il ~config spec_il "State_transition"
    [ beaconState_il; block_il; Il.Value.bool validate ]
    "runner_il"

let eval_sl_eth ?(config = Instrumentation.Config.default) spec_sl ~validate
    beaconState_il block_il : (Eval_Sl.Ctx.t * Il.Value.t list) pipeline_result
    =
  eval_sl ~config spec_sl "State_transition"
    [ beaconState_il; block_il; Il.Value.bool validate ]
    "runner_sl"

(* --- ETH Test Suite Runner --- *)

type eth_test_case = {
  name : string;
  pre_file : string;
  block_file : string;
  is_positive : bool;
}

(* Helper to check if a directory exists *)
let dir_exists path = Sys.file_exists path && Sys.is_directory path

(* Helper to check if a file exists *)
let file_exists path = Sys.file_exists path && not (Sys.is_directory path)

(* Discover and validate ETH test directory structure *)
let discover_eth_tests (dir : string) : (eth_test_case list, Error.t) result =
  let positive_dir = Filename.concat dir "positive" in
  let negative_dir = Filename.concat dir "negative" in
  (* Validate top-level structure *)
  if not (dir_exists dir) then
    Error
      (Error.DirectoryError (Printf.sprintf "Directory does not exist: %s" dir))
  else if (not (dir_exists positive_dir)) && not (dir_exists negative_dir) then
    Error
      (Error.DirectoryError
         (Printf.sprintf
            "Directory must contain 'positive' and/or 'negative' \
             subdirectories: %s"
            dir))
  else
    let collect_tests is_positive test_dir =
      if not (dir_exists test_dir) then []
      else
        let subdirs =
          Sys.readdir test_dir |> Array.to_list
          |> List.filter (fun name ->
                 dir_exists (Filename.concat test_dir name))
          |> List.sort String.compare
        in
        List.filter_map
          (fun name ->
            let case_dir = Filename.concat test_dir name in
            let pre_file = Filename.concat case_dir "pre.json" in
            let block_file = Filename.concat case_dir "block.json" in
            if file_exists pre_file && file_exists block_file then
              Some { name; pre_file; block_file; is_positive }
            else None)
          subdirs
    in
    let positive_tests = collect_tests true positive_dir in
    let negative_tests = collect_tests false negative_dir in
    let all_tests = positive_tests @ negative_tests in
    if all_tests = [] then
      Error
        (Error.DirectoryError
           (Printf.sprintf "No valid test cases found in: %s" dir))
    else Ok all_tests

(* ETH test suite result tracking *)
type eth_suite_result = {
  passed : int;
  failed : int;
  total : int;
  positive_passed : int;
  positive_failed : int;
  negative_passed : int;
  negative_failed : int;
}

(* IL suite runner for ETH tests - accumulates coverage *)
let eval_il_suite_eth ?(config = Instrumentation.Config.default) spec_il
    (tests : eth_test_case list) : eth_suite_result =
  let handlers = Instrumentation.Config.to_handlers config in
  Instrumentation.Hooks.set_handlers handlers;
  Instrumentation.Hooks.init ~spec:(Instrumentation.Hooks.IlSpec spec_il);
  let total = List.length tests in
  let results =
    List.mapi
      (fun idx test ->
        Printf.printf "[%d/%d] Running %s... " (idx + 1) total test.name;
        flush stdout;
        let pre_result = parse_json test.pre_file "beaconState" spec_il in
        let block_result =
          parse_json test.block_file "signedBeaconBlock" spec_il
        in
        match (pre_result, block_result) with
        | Error e, _ ->
            Printf.printf "FAIL (pre.json parse error)\n";
            Printf.printf "    Error: %s\n" (Error.string_of_error e);
            flush stdout;
            (test.is_positive, false)
        | _, Error e ->
            Printf.printf "FAIL (block.json parse error)\n";
            Printf.printf "    Error: %s\n" (Error.string_of_error e);
            flush stdout;
            (test.is_positive, false)
        | Ok pre_state, Ok block ->
            let run_result =
              eval_il_run spec_il "State_transition"
                [ pre_state; block; Il.Value.bool true ]
                test.name
            in
            let success =
              match (test.is_positive, run_result) with
              | true, Ok _ ->
                  Printf.printf "PASS (positive)\n";
                  true
              | true, Error e ->
                  Printf.printf "FAIL (positive, unexpected error)\n";
                  Printf.printf "    Error: %s\n" (Error.string_of_error e);
                  false
              | false, Error _ ->
                  Printf.printf "PASS (negative, expected error)\n";
                  true
              | false, Ok _ ->
                  Printf.printf
                    "FAIL (negative, expected error but succeeded)\n";
                  false
            in
            flush stdout;
            (test.is_positive, success))
      tests
  in
  (* Don't call finish here - let the CLI handle it for file output *)
  let positive_passed =
    List.length
      (List.filter (fun (is_pos, success) -> is_pos && success) results)
  in
  let positive_failed =
    List.length
      (List.filter (fun (is_pos, success) -> is_pos && not success) results)
  in
  let negative_passed =
    List.length
      (List.filter (fun (is_pos, success) -> (not is_pos) && success) results)
  in
  let negative_failed =
    List.length
      (List.filter
         (fun (is_pos, success) -> (not is_pos) && not success)
         results)
  in
  {
    passed = positive_passed + negative_passed;
    failed = positive_failed + negative_failed;
    total = List.length tests;
    positive_passed;
    positive_failed;
    negative_passed;
    negative_failed;
  }

(* SL suite runner for ETH tests - accumulates coverage *)
let eval_sl_suite_eth ?(config = Instrumentation.Config.default) spec_sl spec_il
    (tests : eth_test_case list) : eth_suite_result =
  let handlers = Instrumentation.Config.to_handlers config in
  Instrumentation.Hooks.set_handlers handlers;
  Instrumentation.Hooks.init ~spec:(Instrumentation.Hooks.SlSpec spec_sl);
  let total = List.length tests in
  let results =
    List.mapi
      (fun idx test ->
        Printf.printf "[%d/%d] Running %s... " (idx + 1) total test.name;
        flush stdout;
        (* Use spec_il for JSON parsing *)
        let pre_result = parse_json test.pre_file "beaconState" spec_il in
        let block_result =
          parse_json test.block_file "signedBeaconBlock" spec_il
        in
        match (pre_result, block_result) with
        | Error e, _ ->
            Printf.printf "FAIL (pre.json parse error)\n";
            Printf.printf "    Error: %s\n" (Error.string_of_error e);
            flush stdout;
            (test.is_positive, false)
        | _, Error e ->
            Printf.printf "FAIL (block.json parse error)\n";
            Printf.printf "    Error: %s\n" (Error.string_of_error e);
            flush stdout;
            (test.is_positive, false)
        | Ok pre_state, Ok block ->
            let run_result =
              eval_sl_run spec_sl "State_transition"
                [ pre_state; block; Il.Value.bool true ]
                test.name
            in
            let success =
              match (test.is_positive, run_result) with
              | true, Ok _ ->
                  Printf.printf "PASS (positive)\n";
                  true
              | true, Error e ->
                  Printf.printf "FAIL (positive, unexpected error)\n";
                  Printf.printf "    Error: %s\n" (Error.string_of_error e);
                  false
              | false, Error _ ->
                  Printf.printf "PASS (negative, expected error)\n";
                  true
              | false, Ok _ ->
                  Printf.printf
                    "FAIL (negative, expected error but succeeded)\n";
                  false
            in
            flush stdout;
            (test.is_positive, success))
      tests
  in
  (* Don't call finish here - let the CLI handle it for file output *)
  let positive_passed =
    List.length
      (List.filter (fun (is_pos, success) -> is_pos && success) results)
  in
  let positive_failed =
    List.length
      (List.filter (fun (is_pos, success) -> is_pos && not success) results)
  in
  let negative_passed =
    List.length
      (List.filter (fun (is_pos, success) -> (not is_pos) && success) results)
  in
  let negative_failed =
    List.length
      (List.filter
         (fun (is_pos, success) -> (not is_pos) && not success)
         results)
  in
  {
    passed = positive_passed + negative_passed;
    failed = positive_failed + negative_failed;
    total = List.length tests;
    positive_passed;
    positive_failed;
    negative_passed;
    negative_failed;
  }
