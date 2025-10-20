import argparse
import importlib
import json
from typing import Any

from remerkleable.basic import boolean, bit, uint8, uint16, uint32, uint64, uint128, uint256
from remerkleable.byte_arrays import ByteVector, ByteList
from remerkleable.bitfields import Bitlist, Bitvector
from remerkleable.complex import Container, List, Vector

BASIC_INT_TYPES = (uint8, uint16, uint32, uint64, uint128, uint256)
BASIC_BOOL_TYPES = (boolean, bit)

def _from_hex(s: str) -> bytes:
    if not isinstance(s, str) or not s.startswith("0x"):
        raise ValueError("Expected 0x-prefixed hex string")
    return bytes.fromhex(s[2:])

def _elem_type_of(seq_type):
    # remerkleable의 element_cls() 메서드 사용
    if hasattr(seq_type, 'element_cls') and callable(seq_type.element_cls):
        return seq_type.element_cls()
    for attr in ("elem_type", "element_type", "item_elem_type"):
        if hasattr(seq_type, attr):
            return getattr(seq_type, attr)
    return getattr(seq_type, "__args__", [None])[0]

def json_to_view(j: Any, typ) -> Any:
    # 1) Container
    if hasattr(typ, 'fields') and callable(typ.fields):
        if not isinstance(j, dict):
            raise TypeError(f"Container expects dict, got {type(j)}")
        kwargs = {}
        for fname, ftype in typ.fields().items():
            if fname not in j:
                raise KeyError(f"Missing field '{fname}' for {typ.__name__}")
            kwargs[fname] = json_to_view(j[fname], ftype)
        return typ(**kwargs)

    # 2) Byte arrays
    if 'ByteVector' in str(typ) or 'ByteList' in str(typ):
        if not isinstance(j, str):
            raise TypeError(f"{typ.__name__} expects 0x-hex string")
        b = _from_hex(j)
        return typ(b)

    # 3) Lists/Vectors
    if hasattr(typ, '__args__') or 'Vector' in str(typ) or 'List' in str(typ):
        if not isinstance(j, list):
            raise TypeError(f"{typ.__name__} expects list JSON")
        elem_t = _elem_type_of(typ)
        if elem_t:
            elems = [json_to_view(e, elem_t) for e in j]
        else:
            elems = j
        try:
            return typ(elems)
        except TypeError:
            return typ(*elems)

    # 4) Bitfields
    if 'Bitvector' in str(typ) or 'Bitlist' in str(typ):
        if not isinstance(j, str):
            raise TypeError(f"{typ.__name__} expects 0x-hex string (SSZ-encoded)")
        ssz_bytes = _from_hex(j)
        try:
            import io
            stream = io.BytesIO(ssz_bytes)
            return typ.deserialize(stream, len(ssz_bytes))
        except Exception:
            try:
                return typ(ssz_bytes)
            except Exception:
                return typ()

    # 5) Basic ints/bools
    try:
        if typ in BASIC_INT_TYPES:
            if not isinstance(j, int):
                raise TypeError(f"{typ.__name__} expects int")
            return typ(j)
    except (TypeError, AttributeError):
        pass

    try:
        if typ in BASIC_BOOL_TYPES:
            if not isinstance(j, bool):
                if isinstance(j, int) and j in (0, 1):
                    return typ(bool(j))
                raise TypeError(f"{typ.__name__} expects bool")
            return typ(j)
    except (TypeError, AttributeError):
        pass

    # 6) 기타 프리미티브 (bytes, str 등)
    if typ in (bytes, bytearray, memoryview):
        if isinstance(j, str):
            return _from_hex(j)
        raise TypeError(f"bytes-like expected 0x-hex string")

    try:
        return typ(j)
    except Exception as e:
        raise TypeError(f"Cannot coerce JSON value {j!r} to {typ}: {e}")

def main():
    # Usage : python BeaconStateJsonToSSZ.py --in <input_json_file> --out <output_ssz_file> [--type-module <module_path>] [--type <type_name>]
    p = argparse.ArgumentParser(description="Convert BeaconState JSON to SSZ using remerkleable types.")
    p.add_argument("--type-module", default="eth2spec.capella.mainnet", help="Python module path containing the remerkleable type (default: eth2spec.capella.mainnet)")
    p.add_argument("--type", dest="type_name", default="BeaconState", help="Type name inside the module (default: BeaconState)")
    p.add_argument("--in", dest="in_path", required=True, help="Input BeaconState JSON file path")
    p.add_argument("--out", dest="out_path", required=True, help="Output BeaconState SSZ file path")
    args = p.parse_args()

    # 1) Load remerkleable type
    mod = importlib.import_module(args.type_module)
    typ = getattr(mod, args.type_name, None)
    if typ is None:
        raise SystemExit(f"Type {args.type_name!r} not found in module {args.type_module!r}")

    # 2) Read JSON
    with open(args.in_path, "r", encoding="utf-8") as f:
        j = json.load(f)

    # 3) Build view/value from JSON
    view = json_to_view(j, typ)

    # 4) Serialize to SSZ
    try:
        ssz_bytes = view.encode_bytes()
    except AttributeError:
        raise SystemExit(f"{typ.__name__} instance has no .serialize(); ensure the top-level type is an SSZ container/list/vector, not a bare basic type.")
    with open(args.out_path, "wb") as f:
        f.write(ssz_bytes)

    print(f"OK: wrote {args.out_path}")

if __name__ == "__main__":
    main()
