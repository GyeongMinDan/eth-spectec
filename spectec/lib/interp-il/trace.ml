open Il
open Util.Source

(* Execution trace *)

type time =
  | ING of float
  (* start time *)
  | END of (float * float)
  (* accumulated duration, duration *)
  | CACHED

type t =
  | Rel of {
      id_rel : id;
      id_rule : id;
      values_input : value list;
      time : time;
      subtraces_rev : t list;
    }
  | Dec of {
      id_func : id;
      idx_clause : int;
      values_input : value list;
      time : time;
      subtraces_rev : t list;
    }
  | Iter of { inner : string; time : time; subtraces_rev : t list }
  | Prem of prem
  | Empty

(* Openers *)

let open_time () : time = ING (Unix.gettimeofday ())

let open_rel (id_rel : id) (id_rule : id) (values_input : value list) : t =
  let time = open_time () in
  Rel { id_rel; id_rule; values_input; time; subtraces_rev = [] }

let open_dec (id_func : id) (idx_clause : int) (values_input : value list) : t =
  let time = open_time () in
  Dec { id_func; idx_clause; values_input; time; subtraces_rev = [] }

let open_iter (inner : string) : t =
  let time = open_time () in
  Iter { inner; time; subtraces_rev = [] }

(* Closers *)

let close_time (time_start : time) (subtraces_rev : t list) : time =
  let time_start =
    match time_start with ING time_start -> time_start | _ -> assert false
  in
  let time_end = Unix.gettimeofday () in
  let time_sub =
    subtraces_rev
    |> List.rev_map (fun trace ->
           match trace with
           | Rel { time; _ } | Dec { time; _ } | Iter { time; _ } -> (
               match time with
               | END (duration_acc, _) ->
                   if duration_acc < 0.0 then
                     Format.asprintf "negative inner acc: %.6f" duration_acc
                     |> print_endline;
                   duration_acc
               | CACHED -> 0.0
               | _ -> assert false)
           | _ -> 0.0)
    |> List.fold_left ( +. ) 0.0
  in
  let duration_acc = time_end -. time_start in
  let duration = duration_acc -. time_sub in
  END (duration_acc, duration)

let close (trace : t) : t =
  match trace with
  | Rel ({ id_rel; time = ING _; subtraces_rev; _ } as rel) ->
      let time = close_time rel.time subtraces_rev in
      (match time with
      | END (_, dur) -> Profile.record_rule id_rel.it dur
      | _ -> ());
      Rel { rel with time }
  | Dec ({ id_func; time = ING _; subtraces_rev; _ } as dec) ->
      let time = close_time dec.time subtraces_rev in
      (match time with
      | END (_, dur) -> Profile.record_func id_func.it dur
      | _ -> ());
      Dec { dec with time }
  | Iter { inner; time; subtraces_rev } ->
      let time = close_time time subtraces_rev in
      Iter { inner; time; subtraces_rev }
  | _ -> assert false

(* Pretty Printing *)

let pp_time fmt (time : time) =
  match time with
  | ING time_start ->
      Format.fprintf fmt "ING: %.6f ago" (Unix.gettimeofday () -. time_start)
  | END (_, dur) -> Format.fprintf fmt "%.6f" dur
  | CACHED -> Format.fprintf fmt "[cached]"

(* Caching *)

let rec wipe_time (trace : t) : t =
  match trace with
  | Rel { id_rel; id_rule; values_input; subtraces_rev; _ } ->
      let time = CACHED in
      let subtraces_rev = List.map wipe_time subtraces_rev in
      Rel { id_rel; id_rule; values_input; time; subtraces_rev }
  | Dec { id_func; idx_clause; values_input; subtraces_rev; _ } ->
      let time = CACHED in
      let subtraces_rev = List.map wipe_time subtraces_rev in
      Dec { id_func; idx_clause; values_input; time; subtraces_rev }
  | Iter { inner; subtraces_rev; _ } ->
      let time = CACHED in
      let subtraces_rev = List.map wipe_time subtraces_rev in
      Iter { inner; time; subtraces_rev }
  | _ -> trace

let wipe_subtraces (trace : t) : t list =
  match trace with
  | Rel { subtraces_rev; _ }
  | Dec { subtraces_rev; _ }
  | Iter { subtraces_rev; _ } ->
      List.map wipe_time subtraces_rev
  | _ -> assert false

let replace_subtraces (trace : t) (subtraces_rev : t list) : t =
  match trace with
  | Rel { id_rel; id_rule; values_input; time; _ } ->
      Rel { id_rel; id_rule; values_input; time; subtraces_rev }
  | Dec { id_func; idx_clause; values_input; time; _ } ->
      Dec { id_func; idx_clause; values_input; time; subtraces_rev }
  | Iter { inner; time; _ } -> Iter { inner; time; subtraces_rev }
  | _ -> assert false

(* Committing *)

let commit (trace : t) (trace_sub : t) : t =
  match trace with
  | Rel ({ subtraces_rev; _ } as rel) ->
      let subtraces_rev = trace_sub :: subtraces_rev in
      Rel { rel with subtraces_rev }
  | Dec ({ subtraces_rev; _ } as dec) ->
      let subtraces_rev = trace_sub :: subtraces_rev in
      Dec { dec with subtraces_rev }
  | Iter { inner; time; subtraces_rev } ->
      let subtraces_rev = trace_sub :: subtraces_rev in
      Iter { inner; time; subtraces_rev }
  | Prem _ -> assert false
  | Empty -> trace_sub

(* Extension *)

let extend (trace : t) (prem : prem) : t =
  match trace with
  | Rel { id_rel; id_rule; values_input; time; subtraces_rev } ->
      let subtraces_rev = Prem prem :: subtraces_rev in
      Rel { id_rel; id_rule; values_input; time; subtraces_rev }
  | Dec { id_func; idx_clause; values_input; time; subtraces_rev } ->
      let subtraces_rev = Prem prem :: subtraces_rev in
      Dec { id_func; idx_clause; values_input; time; subtraces_rev }
  | Iter { inner; time; subtraces_rev } ->
      let subtraces_rev = Prem prem :: subtraces_rev in
      Iter { inner; time; subtraces_rev }
  | Prem _ | Empty -> assert false

(* Printing *)

module Tagger = Map.Make (Int)

type tagger = int Tagger.t

let tag (tagger : tagger) (depth : int) : string =
  let tag = Tagger.find depth tagger in
  Format.asprintf "%d@%d" depth tag

let update_tagger (tagger : tagger) (depth : int) : tagger =
  let tag =
    match Tagger.find_opt depth tagger with None -> 0 | Some tag -> tag
  in
  Tagger.add depth (tag + 1) tagger

let rec log ?(tagger = Tagger.empty) ?(depth = 0) ?(idx = 0) ?(verbose = false)
    (trace : t) : string =
  let log_values values =
    match (verbose, values) with
    | false, _ | true, [] -> ""
    | _ ->
        Format.asprintf "--- input ---\n%s\n-------------\n"
          (String.concat "\n" (List.map Print.string_of_value values))
  in
  let log_time fmt time =
    match time with ING _ -> assert false | _ -> pp_time fmt time
  in
  match trace with
  | Rel { id_rel; id_rule; values_input; time; subtraces_rev } ->
      let depth = depth + 1 in
      let tagger = update_tagger tagger depth in
      Format.asprintf "[>>> %s] Rule %s/%s\n%s%s[<<< %s] Rule %s/%s %a"
        (tag tagger depth) id_rel.it id_rule.it (log_values values_input)
        (logs ~tagger ~depth ~verbose subtraces_rev)
        (tag tagger depth) id_rel.it id_rule.it log_time time
  | Dec { id_func; idx_clause; values_input; time; subtraces_rev } ->
      let depth = depth + 1 in
      let tagger = update_tagger tagger depth in
      Format.asprintf "[>>> %s] Clause %s/%d\n%s%s[<<< %s] Clause %s/%d %a"
        (tag tagger depth) id_func.it idx_clause (log_values values_input)
        (logs ~tagger ~depth ~verbose subtraces_rev)
        (tag tagger depth) id_func.it idx_clause log_time time
  | Iter { inner; time; subtraces_rev } ->
      let depth = depth + 1 in
      let tagger = update_tagger tagger depth in
      Format.asprintf "[>>> %s] Iteration %s\n%s[<<< %s] Iteration %a"
        (tag tagger depth) inner
        (logs ~tagger ~depth ~verbose subtraces_rev)
        (tag tagger depth) log_time time
  | Prem prem ->
      Format.asprintf "[%s-%d] %s" (tag tagger depth) idx
        (Print.string_of_prem prem)
  | Empty -> ""

and logs ?(tagger = Tagger.empty) ?(depth = 0) ?(verbose = false)
    (traces_rev : t list) : string =
  match traces_rev with
  | [] -> ""
  | _ ->
      List.fold_left
        (fun (idx, straces_rev) trace ->
          let idx = match trace with Prem _ -> idx + 1 | _ -> idx in
          let strace = log ~tagger ~depth ~idx ~verbose trace in
          (idx, strace :: straces_rev))
        (0, []) (List.rev traces_rev)
      |> snd |> List.rev |> String.concat "\n" |> Format.asprintf "%s\n"
