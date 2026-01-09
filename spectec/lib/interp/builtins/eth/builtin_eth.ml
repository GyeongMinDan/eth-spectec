(* builtins/eth/eth.ml *)
module Engine = Engine

let builtins =
  [
    BlsImpl.builtins;
    Bytes.builtins;
    Debug.builtins;
    Engine.builtins;
    HashImpl.builtins;
    Lists.builtins;
    Math.builtins;
    MerkleImpl.builtins;
  ]
  |> List.concat
