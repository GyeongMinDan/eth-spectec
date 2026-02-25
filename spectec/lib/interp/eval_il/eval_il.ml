open Lang.Il
module F = Format
open Attempt
open Common.Source

let run_relation (filename : string) (builtins : Builtins.t) (cache : Cache.t)
    (spec : spec) (rid : id') (values : value list) : Ctx.t * value list =
  let ctx = Interp.load_spec filename builtins cache spec in
  let+ ctx, values = Interp.invoke_rel ctx (rid $ no_region) values in
  (ctx, values)

let run_relation_fresh (filename : string) (builtins : Builtins.t)
    (cache : Cache.t) (spec : spec) (rid : id') (values : value list) :
    Ctx.t * value list =
  Cache.clear cache;
  run_relation filename builtins cache spec rid values

module Ctx = Ctx

exception Error = Error.InterpError
