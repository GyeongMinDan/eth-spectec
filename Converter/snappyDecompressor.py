import snappy, sys

def snappy_uncompress(path_in: str) -> bytes:
    data = open(path_in, "rb").read()
    try:
        return snappy.decompress(data)
    except Exception:
        return data

if __name__ == "__main__":
    #Usage: python snappydecompress.py <input_file> <output_file>
    inp, outp = sys.argv[1], sys.argv[2]
    raw = safe_uncompress(inp)
    with open(outp, "wb") as f:
        f.write(raw)
    print("wrote", outp, "bytes:", len(raw))