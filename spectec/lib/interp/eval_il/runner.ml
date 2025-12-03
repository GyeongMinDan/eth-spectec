open Lang.Il
module Cache = Semantics.Dynamic.Cache
open Attempt
open Common.Source

let run_relation (ctx : Ctx.t) (spec : spec) (rid : id') (values : value list) :
    Ctx.t * value list =
  let ctx = Interp.load_spec ctx spec in
  let+ ctx, values = Interp.invoke_rel ctx (rid $ no_region) values in
  (ctx, values)

let init ~(debug : bool) ~(profile : bool) (filename_target : string) : Ctx.t =
  Cache.Cache.clear !Interp.func_cache;
  Cache.Cache.clear !Interp.rule_cache;
  (* Profile.reset (); *)
  (* if profile then ( *)
  (*   at_exit (fun () -> Profile.dump ()); *)
  (*   Sys.catch_break true; *)
  (*   let handler _ = *)
  (*     Format.printf "@.Interrupted; dumping profile...@."; *)
  (*     Profile.dump (); *)
  (*     exit 1 *)
  (*   in *)
  (*   Sys.set_signal Sys.sigint (Sys.Signal_handle handler); *)
  (*   Sys.set_signal Sys.sigterm (Sys.Signal_handle handler)); *)
  Ctx.empty ~debug ~profile filename_target

let run_relation_fresh ?(debug : bool = false) ?(profile : bool = false)
    (spec : spec) (rid : id') (values : value list) (filename_target : string) :
    Ctx.t * value list =
  let ctx = init ~debug ~profile filename_target in
  run_relation ctx spec rid values
