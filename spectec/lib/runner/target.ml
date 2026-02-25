(** Target - Defines a target's configuration.

    A target specifies:
    - name: Target identifier (e.g., "p4", "ethereum")
    - spec_dir: Directory containing the target's spec files
    - test_dir: Directory containing test inputs
    - builtins: OCaml implementations for library functions
    - handler: Wrapper that provides global mutable state to runtime
    - is_impure_func/rel: Functions known to have side effects but safe to cache
    - state_version: Shared ref incremented by side-effecting builtins *)

module type S = sig
  val name : string
  val spec_dir : string
  val test_dir : string
  val builtins : (string * Interp.Builtins.Define.t) list
  val handler : (unit -> 'a) -> 'a
  val is_impure_func : string -> bool
  val is_impure_rel : string -> bool
  val state_version : int ref
end
