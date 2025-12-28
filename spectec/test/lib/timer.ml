(** Simple timing utilities using monotonic clock. *)

let now () =
  Core.Time_ns.now () |> Core.Time_ns.to_span_since_epoch
  |> Core.Time_ns.Span.to_sec

let time f =
  let start = now () in
  let result = f () in
  let duration = now () -. start in
  (duration, result)
