"""Minimal GLB reader: meshes -> primitives with positions, indices, joints, weights and material name."""
import json, struct
import numpy as np

COMP = {5120: np.int8, 5121: np.uint8, 5122: np.int16, 5123: np.uint16, 5125: np.uint32, 5126: np.float32}
NCOMP = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}


def load(path):
    data = open(path, "rb").read()
    magic, ver, length = struct.unpack_from("<III", data, 0)
    assert magic == 0x46546C67
    off = 12
    gltf, binchunk = None, None
    while off < length:
        clen, ctype = struct.unpack_from("<II", data, off)
        chunk = data[off + 8: off + 8 + clen]
        if ctype == 0x4E4F534A:
            gltf = json.loads(chunk)
        elif ctype == 0x004E4942:
            binchunk = chunk
        off += 8 + clen

    def acc(i):
        a = gltf["accessors"][i]
        bv = gltf["bufferViews"][a["bufferView"]]
        dt = COMP[a["componentType"]]
        n = NCOMP[a["type"]]
        start = bv.get("byteOffset", 0) + a.get("byteOffset", 0)
        stride = bv.get("byteStride", 0)
        isz = np.dtype(dt).itemsize * n
        if stride and stride != isz:
            raw = np.frombuffer(binchunk, dtype=np.uint8, count=stride * a["count"], offset=start)
            raw = raw.reshape(a["count"], stride)[:, :isz].copy()
            arr = raw.view(dt).reshape(a["count"], n)
        else:
            arr = np.frombuffer(binchunk, dtype=dt, count=a["count"] * n, offset=start).reshape(a["count"], n)
        arr = arr.astype(np.float64) if dt == np.float32 else arr.astype(np.int64)
        if a.get("normalized"):
            arr = arr / float(np.iinfo(dt).max)
        return arr

    out = {"gltf": gltf, "meshes": [], "acc": acc}
    for mi, m in enumerate(gltf.get("meshes", [])):
        prims = []
        for p in m["primitives"]:
            at = p["attributes"]
            prim = {"pos": acc(at["POSITION"]), "idx": acc(p["indices"]).reshape(-1, 3) if "indices" in p else None,
                    "material": gltf["materials"][p["material"]]["name"] if "material" in p else None}
            for k in ("JOINTS_0", "WEIGHTS_0", "JOINTS_1", "WEIGHTS_1"):
                if k in at:
                    prim[k] = acc(at[k])
            prims.append(prim)
        out["meshes"].append({"name": m.get("name"), "prims": prims})
    return out
