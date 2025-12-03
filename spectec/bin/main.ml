open Runner

let version = "0.1"

let print_to_formatter ?file (f : Format.formatter -> 'a) : 'a =
  match file with
  | None -> f Format.std_formatter
  | Some filename ->
      let oc = open_out filename in
      let fmt = Format.formatter_of_out_channel oc in
      Fun.protect
        (fun () ->
          f fmt;
          Format.pp_print_flush fmt ())
        ~finally:(fun () -> close_out oc)

let print_json ?output_file value_il =
  let json = Interface.JSON.Print.value_to_json value_il in
  match json with
  | Ok json -> (
      let json_string = Yojson.Safe.pretty_to_string json in
      match output_file with
      | Some filename ->
          let oc = open_out filename in
          output_string oc json_string;
          output_string oc "\n";
          close_out oc;
          Format.printf "JSON saved to: %s\n" filename
      | None -> print_endline json_string)
  | Error err ->
      Format.printf "JSON printing failed : %s"
        (Interface.JSON.Print.string_of_error err)

(* Commands *)

let elab_command =
  Core.Command.basic ~summary:"parse and elaborate a spec"
    (let open Core.Command.Let_syntax in
     let open Core.Command.Param in
     let%map filenames = anon (sequence ("spec files" %: string)) in
     fun () ->
       let elaborate_result =
         let* spec = parse_spec_files filenames in
         let* spec_il = elaborate spec in
         Ok spec_il
       in
       match elaborate_result with
       | Ok spec_il ->
           Format.printf "%s\n" (Lang.Il.Print.string_of_spec spec_il)
       | Error e -> Format.printf "%s\n" (Runner.Error.string_of_error e))

let structure_command =
  Core.Command.basic ~summary:"structure a spec"
    (let open Core.Command.Let_syntax in
     let open Core.Command.Param in
     let%map filenames = anon (sequence ("spec files" %: string)) in
     fun () ->
       let structure_result =
         let* spec = parse_spec_files filenames in
         let* spec_il = elaborate spec in
         let spec_sl = structure spec_il in
         Ok spec_sl
       in
       match structure_result with
       | Ok spec_sl ->
           Format.printf "%s\n" (Lang.Sl.Print.string_of_spec spec_sl)
       | Error e -> Format.printf "%s\n" (Runner.Error.string_of_error e))

let parse_json_command =
  Core.Command.basic ~summary:"parse a JSON into IL value"
    (let open Core.Command.Let_syntax in
     let open Core.Command.Param in
     let%map spec_files = anon (sequence ("spec files" %: string))
     (* and includes_target = flag "-i" (listed string) ~doc:"target include paths" *)
     and filename_target =
       flag "-p" (required string) ~doc:"target file to parse"
     and input_type = flag "-t" (required string) ~doc:"type of input JSON"
     and output_file =
       flag "-o" (optional string) ~doc:"output JSON file (default: stdout)"
     in
     fun () ->
       let spec = List.concat_map Frontend.Parse.parse_file spec_files in
       let parse_result =
         let* spec_il = elaborate spec in
         let* value_il = parse_json filename_target input_type spec_il in
         Ok (spec_il, value_il)
       in
       match parse_result with
       | Ok (_, value_il) -> print_json ?output_file value_il
       | Error e ->
           Format.printf "JSON parse failed:\n  %s\n"
             (Runner.Error.string_of_error e))

let p4parse_command =
  Core.Command.basic ~summary:"parse a P4 program"
    (let open Core.Command.Let_syntax in
     let open Core.Command.Param in
     let%map filenames = anon (sequence ("spec files" %: string))
     and includes_target = flag "-i" (listed string) ~doc:"p4 include paths"
     and filename_target = flag "-p" (required string) ~doc:"p4 file to parse"
     and roundtrip =
       flag "-r" no_arg ~doc:"perform a round-trip parse/unparse"
     in
     fun () ->
       let do_roundtrip () =
         let* rountrip_result =
           Runner.parse_p4_file_with_roundtrip roundtrip filenames
             includes_target filename_target
         in
         Ok rountrip_result
       in
       match (roundtrip, Runner.Handlers.il do_roundtrip) with
       | false, Ok unparsed_string ->
           Format.printf "Parse succeeded:\n%s\n" unparsed_string
       | true, Ok unparsed_string ->
           Format.printf "Roundtrip succeeded:\n%s\n" unparsed_string
       | false, Error e ->
           Format.printf "Parse failed:\n  %s\n"
             (Runner.Error.string_of_error e)
       | true, Error e ->
           Format.printf "Roundtrip failed:\n  %s\n"
             (Runner.Error.string_of_error e))

let type_p4_il_command =
  Core.Command.basic
    ~summary:
      "typecheck a P4 program based on a SpecTec spec, using the IL interpreter"
    (let open Core.Command.Let_syntax in
     let open Core.Command.Param in
     let%map filenames_spec = anon (sequence ("spec files" %: string))
     and includes_target = flag "-i" (listed string) ~doc:"p4 include paths"
     and filename_target =
       flag "-p" (required string) ~doc:"p4 file to typecheck"
     and debug = flag "-dbg" no_arg ~doc:"print debug traces"
     and profile = flag "-profile" no_arg ~doc:"profiling" in
     fun () ->
       let interp () =
         let* spec = parse_spec_files filenames_spec in
         let* spec_il = elaborate spec in
         let* value_program = parse_p4_file includes_target filename_target in
         let* _, _ =
           eval_il ~debug ~profile spec_il "Program_ok" [ value_program ]
             filename_target
         in
         Ok ()
       in
       match Runner.Handlers.il interp with
       | Ok () -> Format.printf "Interpreter succeeded\n"
       | Error e ->
           Format.printf "Interpreter failed:\n  %s\n"
             (Runner.Error.string_of_error e))

let type_p4_sl_command =
  Core.Command.basic
    ~summary:
      "typecheck a P4 program based on a SpecTec spec, using the SL interpreter"
    (let open Core.Command.Let_syntax in
     let open Core.Command.Param in
     let%map filenames_spec = anon (sequence ("spec files" %: string))
     and includes_target = flag "-i" (listed string) ~doc:"p4 include paths"
     and filename_target =
       flag "-p" (required string) ~doc:"p4 file to typecheck"
     in
     fun () ->
       let interp () =
         let* spec = parse_spec_files filenames_spec in
         let* spec_il = elaborate spec in
         let spec_sl = structure spec_il in
         let* value_program = parse_p4_file includes_target filename_target in
         let* _, _ =
           eval_sl spec_sl "Program_ok" [ value_program ] filename_target
         in
         Ok ()
       in
       match Runner.Handlers.sl interp with
       | Ok () -> Format.printf "Interpreter succeeded\n"
       | Error e ->
           Format.printf "Interpreter failed:\n  %s\n"
             (Runner.Error.string_of_error e))

let run_eth_il_command =
  Core.Command.basic
    ~summary:
      "typecheck a P4 program based on a SpecTec spec, using the IL interpreter"
    (let open Core.Command.Let_syntax in
     let open Core.Command.Param in
     let%map filenames_spec = anon (sequence ("spec files" %: string))
     and pre_state = flag "--pre" (required string) ~doc:"pre-state JSON"
     and block = flag "--block" (required string) ~doc:"beacon block JSON"
     and debug = flag "-dbg" no_arg ~doc:"print debug traces"
     and profile = flag "-profile" no_arg ~doc:"profiling"
     and output_file =
       flag "-o" (optional string) ~doc:"output JSON file (default: stdout)"
     in
     fun () ->
       let interp () =
         let* spec = parse_spec_files filenames_spec in
         let* spec_il = elaborate spec in
         let* _, values =
           eval_il_eth ~debug ~profile spec_il ~validate:true pre_state block
         in
         Ok (values, spec_il)
       in
       match Runner.Handlers.il interp with
       | Ok (values, _) -> (
           print_to_formatter ?file:output_file (fun fmt ->
               List.iter
                 (fun v ->
                   let json = Interface.JSON.Print.value_to_json v in
                   match json with
                   | Ok json ->
                       let json_string = Yojson.Safe.pretty_to_string json in
                       Format.fprintf fmt "%s\n" json_string
                   | Error err ->
                       Format.printf "JSON printing failed : %s"
                         (Interface.JSON.Print.string_of_error err))
                 values);
           match output_file with
           | Some filename -> Format.printf "JSON saved to: %s\n" filename
           | None -> ())
       | Error e ->
           Format.printf "Interpreter failed:\n  %s\n"
             (Runner.Error.string_of_error e))

let run_eth_sl_command =
  Core.Command.basic
    ~summary:
      "typecheck a P4 program based on a SpecTec spec, using the SL interpreter"
    (let open Core.Command.Let_syntax in
     let open Core.Command.Param in
     let%map filenames_spec = anon (sequence ("spec files" %: string))
     and pre_state = flag "--pre" (required string) ~doc:"pre-state JSON"
     and block = flag "--block" (required string) ~doc:"beacon block JSON"
     and output_file =
       flag "-o" (optional string) ~doc:"output JSON file (default: stdout)"
     in
     fun () ->
       let interp () =
         let* spec = parse_spec_files filenames_spec in
         let* spec_il = elaborate spec in
         let spec_sl = structure spec_il in
         let* beaconState_il = parse_json pre_state "beaconState" spec_il in
         let* block_il = parse_json block "signedBeaconBlock" spec_il in
         let* _, values =
           eval_sl_eth spec_sl ~validate:true beaconState_il block_il
         in
         Ok (values, spec_sl)
       in
       match Runner.Handlers.il interp with
       | Ok (values, _) -> (
           match output_file with
           | Some filename ->
               let oc = open_out filename in
               List.iter
                 (fun v ->
                   let json = Interface.JSON.Print.value_to_json v in
                   match json with
                   | Ok json ->
                       let json_string = Yojson.Safe.pretty_to_string json in
                       output_string oc json_string;
                       output_string oc "\n"
                   | Error err ->
                       Format.printf "JSON printing failed : %s"
                         (Interface.JSON.Print.string_of_error err))
                 values;
               close_out oc;
               Format.printf "JSON saved to: %s\n" filename
           | None -> List.iter (fun v -> print_json v) values)
       | Error e ->
           Format.printf "Interpreter failed:\n  %s\n"
             (Runner.Error.string_of_error e))

let command =
  Core.Command.group
    ~summary:"p4spec: a language design framework for the p4_16 language"
    [
      ("elab", elab_command);
      ("struct", structure_command);
      ("type-p4-il", type_p4_il_command);
      ("type-p4-sl", type_p4_sl_command);
      ("run-il", run_eth_il_command);
      ("run-sl", run_eth_sl_command);
      ("p4parse", p4parse_command);
      ("parse-json", parse_json_command);
    ]

let () = Command_unix.run ~version command
