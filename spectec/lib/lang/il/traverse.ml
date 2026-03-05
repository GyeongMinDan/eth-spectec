open Common.Source
open Types

(** Apply [f] to every immediate child [exp] of [exp]; reconstruct if any
    changed. Caller is responsible for recursion — this only goes one level
    deep. Use it as the default case in a recursive traversal:

    let rec my_traversal exp = match exp.it with | VarE id -> handle_var id |
    UpdE _ when too_deep -> exp | _ -> Map.map_children_exp my_traversal exp *)
let map_children_exp (f : exp -> exp) (exp : exp) : exp =
  let same2 a a' b b' = a' == a && b' == b in
  let map_args args =
    List.map
      (fun arg ->
        match arg.it with
        | ExpA e ->
            let e' = f e in
            if e' == e then arg else { arg with it = ExpA e' }
        | _ -> arg)
      args
  in
  match exp.it with
  | BoolE _ | NumE _ | TextE _ | VarE _ -> exp
  | UnE (op, t, e) ->
      let e' = f e in
      if e' == e then exp else { exp with it = UnE (op, t, e') }
  | BinE (op, t, a, b) ->
      let a' = f a and b' = f b in
      if same2 a a' b b' then exp else { exp with it = BinE (op, t, a', b') }
  | CmpE (op, t, a, b) ->
      let a' = f a and b' = f b in
      if same2 a a' b b' then exp else { exp with it = CmpE (op, t, a', b') }
  | DotE (base, atom) ->
      let base' = f base in
      if base' == base then exp else { exp with it = DotE (base', atom) }
  | IdxE (base, idx) ->
      let base' = f base and idx' = f idx in
      if same2 base base' idx idx' then exp
      else { exp with it = IdxE (base', idx') }
  | SliceE (b, hi, lo) ->
      let b' = f b and hi' = f hi and lo' = f lo in
      if b' == b && hi' == hi && lo' == lo then exp
      else { exp with it = SliceE (b', hi', lo') }
  | UpdE (inner, path, v) ->
      (* path may contain exp children; we skip them — consistent with all existing traversals *)
      let inner' = f inner and v' = f v in
      if same2 inner inner' v v' then exp
      else { exp with it = UpdE (inner', path, v') }
  | CallE (id, targs, args) ->
      let args' = map_args args in
      if List.for_all2 ( == ) args args' then exp
      else { exp with it = CallE (id, targs, args') }
  | LenE inner ->
      let inner' = f inner in
      if inner' == inner then exp else { exp with it = LenE inner' }
  | MemE (a, b) ->
      let a' = f a and b' = f b in
      if same2 a a' b b' then exp else { exp with it = MemE (a', b') }
  | CatE (a, b) ->
      let a' = f a and b' = f b in
      if same2 a a' b b' then exp else { exp with it = CatE (a', b') }
  | ConsE (a, b) ->
      let a' = f a and b' = f b in
      if same2 a a' b b' then exp else { exp with it = ConsE (a', b') }
  | TupleE es ->
      let es' = List.map f es in
      if List.for_all2 ( == ) es es' then exp else { exp with it = TupleE es' }
  | ListE es ->
      let es' = List.map f es in
      if List.for_all2 ( == ) es es' then exp else { exp with it = ListE es' }
  | OptE None -> exp
  | OptE (Some inner) ->
      let inner' = f inner in
      if inner' == inner then exp else { exp with it = OptE (Some inner') }
  | StrE fields ->
      let fields' = List.map (fun (a, e) -> (a, f e)) fields in
      if List.for_all2 (fun (_, e) (_, e') -> e == e') fields fields' then exp
      else { exp with it = StrE fields' }
  | CaseE (mixop, args) ->
      (* CaseE wraps a notexp = mixop * exp list *)
      let args' = List.map f args in
      if List.for_all2 ( == ) args args' then exp
      else { exp with it = CaseE (mixop, args') }
  | HoldE (id, (mixop, args)) ->
      (* HoldE wraps an id * notexp *)
      let args' = List.map f args in
      if List.for_all2 ( == ) args args' then exp
      else { exp with it = HoldE (id, (mixop, args')) }
  | SubE (inner, t) ->
      let inner' = f inner in
      if inner' == inner then exp else { exp with it = SubE (inner', t) }
  | UpCastE (t, inner) ->
      let inner' = f inner in
      if inner' == inner then exp else { exp with it = UpCastE (t, inner') }
  | DownCastE (t, inner) ->
      let inner' = f inner in
      if inner' == inner then exp else { exp with it = DownCastE (t, inner') }
  | IterE (inner, iter) ->
      let inner' = f inner in
      if inner' == inner then exp else { exp with it = IterE (inner', iter) }
  | MatchE (inner, pat) ->
      let inner' = f inner in
      if inner' == inner then exp else { exp with it = MatchE (inner', pat) }

(** Combine [f] applied to each immediate child exp of [exp] using [combine],
    with base [empty]. Like [map_children_exp] but for aggregation instead of
    transformation:

    let rec collect_calls exp = match exp.it with | CallE (fname, _, args) ->
    [(fname, args)] (* don't recurse into call args *) | _ ->
    Map.fold_children_exp (@) [] collect_calls exp *)
let fold_children_exp (combine : 'a -> 'a -> 'a) (empty : 'a) (f : exp -> 'a)
    (exp : exp) : 'a =
  let fold_args args =
    List.fold_left
      (fun acc arg ->
        match arg.it with ExpA e -> combine acc (f e) | _ -> acc)
      empty args
  in
  match exp.it with
  | BoolE _ | NumE _ | TextE _ | VarE _ -> empty
  | UnE (_, _, e)
  | LenE e
  | DotE (e, _)
  | SubE (e, _)
  | UpCastE (_, e)
  | DownCastE (_, e)
  | IterE (e, _)
  | MatchE (e, _) ->
      f e
  | BinE (_, _, a, b)
  | CmpE (_, _, a, b)
  | IdxE (a, b)
  | CatE (a, b)
  | ConsE (a, b)
  | MemE (a, b) ->
      combine (f a) (f b)
  | SliceE (b, hi, lo) -> combine (combine (f b) (f hi)) (f lo)
  | UpdE (inner, _path, v) -> combine (f inner) (f v)
  | CallE (_, _, args) -> fold_args args
  | TupleE es | ListE es ->
      List.fold_left (fun acc e -> combine acc (f e)) empty es
  | OptE None -> empty
  | OptE (Some inner) -> f inner
  | StrE fields ->
      List.fold_left (fun acc (_, e) -> combine acc (f e)) empty fields
  | CaseE (_, args) | HoldE (_, (_, args)) ->
      List.fold_left (fun acc e -> combine acc (f e)) empty args
