let builtins =
  [
    BlsImpl.builtins;
    Bytes.builtins;
    Debug.builtins;
    HashImpl.builtins;
    Lists.builtins;
    Math.builtins;
    MerkleImpl.builtins;
  ]
  |> List.concat
