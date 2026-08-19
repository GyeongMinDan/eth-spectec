(* Golden characterization of the json interface's BytesV handling: hex
   round-trips and the beacon byte-length tables. R3 relocates those tables
   into the ethereum target; this pins their values across the move. *)

let show_len_opt = function
  | Some n -> Printf.sprintf "Some %d" n
  | None -> "None"

let roundtrip hex =
  match Json.Parse.hex_string_to_bytes hex with
  | Ok (num, len) ->
      Printf.printf "roundtrip %s -> %s (len %d)\n" hex
        (Json.Print.bytes_to_hex_string num len)
        len
  | Error _ -> Printf.printf "roundtrip %s -> error\n" hex

let () =
  List.iter roundtrip
    [
      "0xdeadbeef"; "0x00ff"; "0x0"; "0x"; "deadbeef"; "0x" ^ String.make 64 'a';
    ];
  (match Json.Parse.hex_string_to_bytes "0x01" with
  | Ok (num, _) ->
      Printf.printf "print len 0 -> %s\n" (Json.Print.bytes_to_hex_string num 0)
  | Error _ -> Printf.printf "print len 0 -> parse error\n");
  List.iter
    (fun field ->
      Printf.printf "field %s -> %s\n" field
        (show_len_opt (Json.Print.bytes_len_from_field_name field)))
    [
      "pubkey";
      "signature";
      "state_root";
      "block_hash";
      "fee_recipient";
      "logs_bloom";
      "previous_version";
      "withdrawal_credentials";
      "graffiti";
    ]
