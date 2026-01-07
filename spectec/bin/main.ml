open Runner

let version = "0.1"

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

(* Instantiate CLI commands for P4 *)
module P4_Cmd = Cli.Command.Make (Targets_p4.P4.Target)

let p4_command =
  let tasks = [ P4_Cmd.Pack (module Targets_p4.P4.Typecheck) ] in
  Core.Command.group ~summary:"P4 commands"
    [
      ("typecheck", Targets.P4.command); ("coverage", P4_Cmd.make_coverage tasks);
    ]

(* Instantiate CLI commands for Ethereum *)
module Eth_Cmd = Cli.Command.Make (Targets_eth.Eth.Target)

let eth_command =
  let tasks = [ Eth_Cmd.Pack (module Targets_eth.Eth.StateTransition) ] in
  Core.Command.group ~summary:"Ethereum commands"
    [ ("run", Targets.Eth.command); ("coverage", Eth_Cmd.make_coverage tasks) ]

let command =
  Core.Command.group ~summary:"SpecTec command line tools"
    [
      ("elab", elab_command);
      ("struct", structure_command);
      ("p4parse", p4parse_command);
      ("parse-json", parse_json_command);
      ("p4", p4_command);
      ("eth", eth_command);
    ]

let () = Command_unix.run ~version command
