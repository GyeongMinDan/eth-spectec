# Magic bytes compare example : pre.ssz_snappy: 919e a901,  post.ssz_snappy: d59f a901
# There are no snappy magic bytes in the file, so we can just read the file and decompress it
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