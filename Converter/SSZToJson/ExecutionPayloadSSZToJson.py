import argparse
import importlib
import json
import os
import sys
from typing import Any

# Add eth2spec to path
# Get the absolute path to ensure it works from any directory
script_dir = os.path.dirname(os.path.abspath(__file__))
consensus_specs_path = os.path.abspath(os.path.join(script_dir, '../../consensus-specs/tests/core/pyspec'))
if consensus_specs_path not in sys.path:
    sys.path.insert(0, consensus_specs_path)

from remerkleable.basic import boolean, bit, uint8, uint16, uint32, uint64, uint128, uint256
from remerkleable.byte_arrays import ByteVector, ByteList
from remerkleable.bitfields import Bitlist, Bitvector
from remerkleable.complex import Container, List, Vector

BASIC_INT_TYPES = (uint8, uint16, uint32, uint64, uint128, uint256)
BASIC_BOOL_TYPES = (boolean, bit)

def _to_hex(b: bytes) -> str:
    return "0x" + b.hex()

def bitfield_to_bool_list(v):
    L = v.length()
    return [bool(v.get(i)) for i in range(L)]


def view_to_jsonable(v: Any) -> Any:
    # 1) Container
    if isinstance(v, Container):
        out = {}
        for fname in v.fields():
            sub = getattr(v, fname)
            out[fname] = view_to_jsonable(sub)
        return out

    # 2) Vectors/Lists (of anything)
    if isinstance(v, (Vector, List)):
        return [view_to_jsonable(e) for e in v]

    # 3) Byte arrays → hex
    if isinstance(v, (ByteVector, ByteList)):
        return _to_hex(bytes(v))

    # 4) Bitfields → bit value
    if isinstance(v, (Bitvector, Bitlist)):
        return bitfield_to_bool_list(v) 

    # 5) Basic ints/bools
    if isinstance(v, BASIC_INT_TYPES):
        # Cast to Python int
        return int(v)
    if isinstance(v, BASIC_BOOL_TYPES):
        return bool(v)

    # 6) Raw Python primitives (int/bytes/str/bool)
    if isinstance(v, (int, bool)):
        return v
    if isinstance(v, (bytes, bytearray, memoryview)):
        return _to_hex(bytes(v))
    if v is None:
        return None

    get = getattr(v, "get", None)
    if callable(get):
        try:
            return view_to_jsonable(get())
        except Exception:
            pass

    # If we reach here, we don't know how to render it; fall back to str()
    return str(v)

def main():
    # Usage: python ExecutionPayloadSSZToJson.py --in /path/to/execution_payload_input.ssz --out /path/to/execution_payload_output.json

    p = argparse.ArgumentParser(description="Convert ExecutionPayload SSZ to JSON using remerkleable types.")
    p.add_argument("--type-module", default="eth2spec.capella.mainnet", help="Python module path containing the remerkleable type (default: eth2spec.capella.mainnet)")
    p.add_argument("--type", dest="type_name", default="BeaconBlockBody", help="Type name inside the module (default: ExecutionPayload)")
    p.add_argument("--in", dest="in_path", required=True, help="Input SSZ file path")
    p.add_argument("--out", dest="out_path", required=True, help="Output JSON file path")
    args = p.parse_args()

    # 1) Load type
    mod = importlib.import_module(args.type_module)
    typ = getattr(mod, args.type_name, None)
    if typ is None:
        raise SystemExit(f"Type {args.type_name!r} not found in module {args.type_module!r}")

    # 2) Read SSZ bytes
    with open(args.in_path, "rb") as f:
        ssz_bytes = f.read()

    # 3) Deserialize: use decode_bytes class method
    try:
        view = typ.decode_bytes(ssz_bytes)
    except Exception as e:
        raise SystemExit(f"Failed to deserialize SSZ as {args.type_name}: {e}")
    py_obj = view_to_jsonable(view)

    # Dump JSON
    with open(args.out_path, "w", encoding="utf-8") as f:
        json.dump(py_obj, f, ensure_ascii=False, indent=2)

    print(f"OK: wrote {args.out_path}")

if __name__ == "__main__":
    main()

