(* Profiling *)

module Counter = Map.Make (String)

type snapshot = {
  rules : (int * float) Counter.t;
  funcs : (int * float) Counter.t;
}

let current : snapshot ref =
  ref { rules = Counter.empty; funcs = Counter.empty }

let reset () = current := { rules = Counter.empty; funcs = Counter.empty }

let record_rule (id : string) (duration : float) : unit =
  let count, total =
    match Counter.find_opt id !current.rules with
    | None -> (0, 0.0)
    | Some (count, total) -> (count, total)
  in
  let rules = Counter.add id (count + 1, total +. duration) !current.rules in
  current := { !current with rules }

let record_func (id : string) (duration : float) : unit =
  let count, total =
    match Counter.find_opt id !current.funcs with
    | None -> (0, 0.0)
    | Some (count, total) -> (count, total)
  in
  let funcs = Counter.add id (count + 1, total +. duration) !current.funcs in
  current := { !current with funcs }

let dump () =
  let pp counter =
    Counter.bindings counter
    |> List.sort (fun (_, (_, a)) (_, (_, b)) -> Float.compare b a)
    |> List.iter (fun (id, (count, total)) ->
           Format.printf "   [ %s ]: %d (%.6f / %.6f)@." id count total
             (total /. float_of_int count))
  in
  Format.printf "Profiling snapshot (rules):@.";
  pp !current.rules;
  Format.printf "Profiling snapshot (functions):@.";
  pp !current.funcs
