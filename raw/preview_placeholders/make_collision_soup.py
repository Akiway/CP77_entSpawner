"""Builds the bended collision preview meshes: base\\spawner\\bended_collision_<colour>.mesh.

Usage: python make_collision_soup.py <template_mesh.json> <out_dir>

The template is the WolvenKit JSON export of
engine\\meshes\\bended_nodes\\stripes\\bended_mesh_template250x1sub4.mesh (251 bones, skinned layout of a
vanilla bended mesh). Each output keeps that skeleton with identity bind matrices and holds one
triangle per bone at (0,0,0) (1,0,0) (0,1,0), weighted to that bone only, so a bone's deformation
matrix places its triangle anywhere: rows X and Y are two edges, Z the face normal, W the first corner.

Convert each JSON with WolvenKit (json_to_cr2w, rebuilding buffers) into source\\archive\\base\\spawner\\.

Material: worldBendedMeshNode ignores meshAppearance (always the first appearance), so the colour is
baked per mesh. hologram_two_sided.mt has no shader for the bended vertex factory and renders a
default white; hologram_txaa.mt is used by vanilla bended meshes. Values are the collider preview
cube's holo.mi, flattened. txaa culls back faces: the editor winds triangles to face outward.
"""
import base64
import json
import os
import struct
import sys

import numpy as np

template_path, out_dir = sys.argv[1:3]

COLOURS = {
    "red": (255, 0, 0),
    "green": (0, 128, 0),
    "blue": (0, 0, 255),
}

HOLO = {
    "AdditiveAlphaBlend": 1, "Normal": "base\\materials\\placeholder\\normal.xbm",
    "Diffuse": "engine\\textures\\small_white.xbm",
    "Scanline": "base\\fx\\_textures\\masks\\gradients\\fx_reflected_vertical_gradient_03_alpha_d.xbm",
    "DotsTexture": "base\\fx\\_textures\\quests\\q105\\fx_pointcloud_dot.xbm",
    "Projector1Position": {"X": 0, "Y": 0, "Z": 1, "W": 0}, "OpaqueScanlineDensity": 0, "DotsSize": 100,
    "DotsColor": {"Red": 255, "Green": 0, "Blue": 0, "Alpha": 255},
    "SurfaceShadows": {"Red": 0, "Green": 0, "Blue": 0, "Alpha": 255},
    "GradientOffset": -100, "GradientLength": 1, "FresnelStrength": 0.93117398, "DotsFresnelStrength": 2.29268289,
    "GlowStrength": 0.075000003, "DesaturationStrength": 0, "FlickerThreshold": 0, "FlickerChance": 0,
    "ArtifactsChance": 0, "LightBleed": 5, "NormalStrength": 1, "ScreenSpaceFlicker": 0, "UseIsobars": 0,
    "IsobarsOffsets": {"X": 320, "Y": 120, "Z": 0, "W": 0}, "EntropyThreshold": 0, "UseMovingDots": 0, "IsHair": 0,
    "ScanlineThickness": 0.5, "Opacity": 0.349999994, "GlobalTint": 0, "SampledOrProceduralDots": 0,
    "FullColorOrGrayscale": 0,
}
REF = [(0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (0.0, 1.0, 0.0)]


def cname(value):
    return {"$type": "CName", "$storage": "string", "$value": value}


def material_value(key, v):
    if isinstance(v, dict) and "Red" in v:
        return {"$type": "Color", key: {"$type": "Color", "Alpha": v["Alpha"], "Blue": v["Blue"], "Green": v["Green"], "Red": v["Red"]}}
    if isinstance(v, dict):
        return {"$type": "Vector4", key: {"$type": "Vector4", "W": v["W"], "X": v["X"], "Y": v["Y"], "Z": v["Z"]}}
    if isinstance(v, str):
        return {"$type": "rRef:ITexture", key: {"DepotPath": {"$type": "ResourcePath", "$storage": "string", "$value": v}, "Flags": "Default"}}
    return {"$type": "Float", key: v}


def short_n(v, offset, scale):
    return int(round(max(-1.0, min(1.0, (v - offset) / scale)) * 32767))


def dec4(x, y, z, w):
    q = lambda c: int(round((c + 1) * 511.5)) & 1023
    return q(x) | (q(y) << 10) | (q(z) << 20) | (w << 30)


def build_geometry(root):
    bones = len(root["boneNames"])
    verts = 3 * bones
    qo, qs = (0.5, 0.5, 0.0), (0.5, 0.5, 0.5)
    s0, s1, s2, s3 = bytearray(), bytearray(), bytearray(), bytearray()
    for b in range(bones):
        for p in REF:
            s0 += struct.pack("<4h", *(short_n(p[a], qo[a], qs[a]) for a in range(3)), 32767)
            s0 += bytes((b, 0, 0, 0)) + bytes((255, 0, 0, 0))
            s1 += np.array(p[:2], dtype=np.float16).tobytes()
            s2 += struct.pack("<2I", dec4(0, 0, 1, 1), dec4(1, 0, 0, 3))
            s3 += bytes((255, 255, 255, 255)) + np.array((0, 0), dtype=np.float16).tobytes()

    vbuf = bytes(s0 + s1 + s2 + s3)
    index_offset = (len(vbuf) + 4095) // 4096 * 4096
    indices = struct.pack("<%dH" % verts, *range(verts))

    blob = root["renderResourceBlob"]["Data"]
    header = blob["header"]
    chunk = header["renderChunkInfos"][0]
    chunk["chunkVertices"]["byteOffsets"]["Elements"] = [0, len(s0), len(s0) + len(s1), len(s0) + len(s1) + len(s2), 0]
    chunk["numVertices"] = verts
    chunk["numIndices"] = verts
    chunk["renderMask"] = "MCF_RenderInScene"
    header["vertexBufferSize"] = len(vbuf)
    header["indexBufferOffset"] = index_offset
    header["indexBufferSize"] = len(indices)
    header["quantizationOffset"].update({"X": qo[0], "Y": qo[1], "Z": qo[2], "W": 1})
    header["quantizationScale"].update({"X": qs[0], "Y": qs[1], "Z": qs[2], "W": 0})
    for p in header["bonePositions"]:
        p.update({"X": 0, "Y": 0, "Z": 0, "W": 1})
    blob["renderBuffer"]["Bytes"] = base64.b64encode(vbuf + bytes(index_offset - len(vbuf)) + indices).decode()

    identity = {"X": (1, 0, 0, 0), "Y": (0, 1, 0, 0), "Z": (0, 0, 1, 0), "W": (0, 0, 0, 1)}
    for m in root["boneRigMatrices"]:
        for row, v in identity.items():
            m[row].update({"X": v[0], "Y": v[1], "Z": v[2], "W": v[3]})

    root["boundingBox"]["Min"].update({"X": 0, "Y": 0, "Z": 0})
    root["boundingBox"]["Max"].update({"X": 1, "Y": 1, "Z": 0})
    root["geometryHash"] = "0"
    return bones


def set_material(root, colour):
    values = dict(HOLO)
    r, g, b = colour
    values["SurfaceColor"] = values["FallofColor"] = {"Red": r, "Green": g, "Blue": b, "Alpha": 255}

    root["appearances"] = [{"HandleId": "0", "Data": {"$type": "meshMeshAppearance", "chunkMaterials": [cname("collision")],
                                                      "name": cname("default"), "tags": []}}]
    root["materialEntries"] = [{"$type": "CMeshMaterialEntry", "index": 0, "isLocalInstance": 1, "name": cname("collision")}]
    root["localMaterialBuffer"] = {"$type": "meshMeshMaterialBuffer", "materials": [], "rawData": None, "rawDataHeaders": []}
    root["localMaterialInstances"] = []
    root["externalMaterials"] = []
    root["preloadExternalMaterials"] = []
    root["preloadLocalMaterialInstances"] = [{"HandleId": "1", "Data": {
        "$type": "CMaterialInstance", "audioTag": cname("None"),
        "baseMaterial": {"DepotPath": {"$type": "ResourcePath", "$storage": "string", "$value": "base\\fx\\shaders\\hologram_txaa.mt"}, "Flags": "Default"},
        "cookingPlatform": "PLATFORM_None", "enableMask": 0, "metadata": None, "resourceVersion": 4,
        "values": [material_value(k, v) for k, v in values.items()]}}]
    root["renderResourceBlob"]["HandleId"] = "2"


os.makedirs(out_dir, exist_ok=True)
for name, colour in COLOURS.items():
    doc = json.load(open(template_path, encoding="utf-8-sig"))
    root = doc["Data"]["RootChunk"]
    bones = build_geometry(root)
    set_material(root, colour)
    out = os.path.join(out_dir, "bended_collision_%s.mesh.json" % name)
    json.dump(doc, open(out, "w", encoding="utf-8"), indent=2)
    print(out, bones, "triangles")
