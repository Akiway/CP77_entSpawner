"""Regenerates `data/static/bended_collision/`: convex collision sources for every bended mesh.

Each bended mesh becomes a set of convex pieces in rest pose whose vertices carry bone weights, so
the editor can skin them with the node's deformation exactly like the render mesh, and hand them to
PhysX as convex colliders (the engine cooks `physicsColliderConvex.vertices` itself).

Step 1 - export every mesh listed in `data/static/bended_rig_matrices.json` to GLB, highest LOD only,
with its skeleton, into a folder that mirrors depot paths (`<glb>\\base\\...\\name.glb`).
  Most road meshes (`br_<hash>_*.mesh`) are not shipped as files: they are embedded in exterior
  `.streamingsector` files (`Data.EmbeddedFiles`). Extract them to `.mesh` files first, pack them into
  a temporary archive, load it in WolvenKit, then export.

Step 2 - run this script (needs numpy and scipy):

    python build_bended_collision.py <glb folder> [--workers 10] [--filter substring]
    python build_bended_collision.py --faces      (adds `faces` to existing outputs, no GLB needed)

What it writes, under data/static/bended_collision/:

  index.json           lowercase mesh path -> file name (mesh file names collide between base\\ and ep1\\)
  <name>.json          version, mesh, bones, tolerance, materials (per class) and pieces:
                         class    ground / raised / wall, from the piece's height above the slice's
                                  lowest walkable level (sidewalks, curbs, medians are raised)
                         slice    index of the slice along the rig axis
                         points   flat rest positions x, y, z in mesh space
                         weights  per point: bone, second bone, weight of the second bone (0-based)
                         faces    hull triangles as flat point indices, counter-clockwise seen from outside

A run resumes: meshes whose output and `.stats.json` sidecar exist are skipped. Sidecars and
`report.json` (coverage of walkable render surface, excess collision over it) go to --report
(default: `<glb folder>\_report`), never into the mod.
"""
import os
for _v in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS"):
    os.environ.setdefault(_v, "1")   # one BLAS thread per worker
import argparse, json, sys, time, traceback
import numpy as np
from multiprocessing import Pool
from scipy.spatial import ConvexHull
import decompose as D

HERE = os.path.dirname(os.path.abspath(__file__))
MOD = os.path.normpath(os.path.join(HERE, "..", ".."))
RIGS = os.path.join(MOD, "data", "static", "bended_rig_matrices.json")
OUT = os.path.join(MOD, "data", "static", "bended_collision")

RAISED = 0.08       # tops this far above the slice's ground level are raised (sidewalk, curb, median)
WALL_HEIGHT = 1.0   # steep pieces at least this tall are walls


def ground_material(name):
    n = name.lower()
    if "dirt" in n or "sandy" in n:
        return "dirt.physmat"
    if "rt_sidewalk" in n or "spa_" in n or "floor" in n or "stairs" in n or "pillar" in n or "deal_wal" in n:
        return "concrete.physmat"
    if n.startswith("rt_") or "_rt_" in n or "highway" in n or "road" in n:
        return "asphalt.physmat"
    return "concrete.physmat"


def file_name(path):
    return path.split("\\")[-1][:-5]


def classify(pieces):
    """ground / raised / wall per piece, using the slice's lowest walkable top as ground level."""
    by_slice = {}
    for p in pieces:
        by_slice.setdefault(p["slice"], []).append(p)
    for group in by_slice.values():
        flats = []
        for p in group:
            n = np.nan_to_num(p["nsum"] / max(np.linalg.norm(p["nsum"]), 1e-12))
            p["up"] = n[2]
            p["top"] = p["pts"][:, 2].max()
            p["height"] = p["top"] - p["pts"][:, 2].min()
            ext = p["pts"].max(0) - p["pts"].min(0)
            if n[2] > 0.7 and sorted(ext)[1] >= 0.5:
                flats.append(p["top"])
        ground = min(flats) if flats else None
        for p in group:
            if p["up"] < 0.5 and p["height"] >= WALL_HEIGHT:
                p["class"] = "wall"
            elif ground is not None and p["top"] >= ground + RAISED:
                p["class"] = "raised"
            else:
                p["class"] = "ground"


def qa(mesh, pieces):
    """Share of walkable, sky-open render surface left uncovered, and of points 10 cm above it inside a piece."""
    pos, tris = mesh["pos"], mesh["tris"]
    tp = pos[tris]
    n = np.cross(tp[:, 1] - tp[:, 0], tp[:, 2] - tp[:, 0])
    area = np.linalg.norm(n, axis=1) / 2
    ok = area > 1e-6
    tp, n, area = tp[ok], n[ok] / (2 * area[ok, None]), area[ok]
    walk = n[:, 2] > 0.7
    if not walk.any() or not pieces:
        return None
    tp, n, area = tp[walk], n[walk], area[walk]
    rng = np.random.default_rng(1)
    k = min(3000, max(200, int(area.sum() * 4)))
    idx = rng.choice(len(tp), k, p=area / area.sum())
    u, v = rng.random(k), rng.random(k)
    flip = u + v > 1
    u[flip], v[flip] = 1 - u[flip], 1 - v[flip]
    a = tp[idx]
    s = a[:, 0] + (a[:, 1] - a[:, 0]) * u[:, None] + (a[:, 2] - a[:, 0]) * v[:, None]
    allp = pos[tris]
    an = np.cross(allp[:, 1] - allp[:, 0], allp[:, 2] - allp[:, 0])
    an /= np.maximum(np.linalg.norm(an, axis=1, keepdims=True), 1e-12)
    up = np.tile([0.0, 0.0, 1.0], (k, 1))
    hit = np.minimum(D.ray_depth(s + up * 0.01, up, allp, an), D.ray_depth(s + up * 0.01, up, allp, -an))
    open_sky = ~(hit < 2.0)
    s, n = s[open_sky], n[idx][open_sky]
    if len(s) == 0:
        return None
    above = s + n * 0.10
    din = np.full(len(s), np.inf)
    dab = np.full(len(s), np.inf)
    for p in pieces:
        try:
            e = ConvexHull(p["pts"]).equations
        except Exception:
            continue
        din = np.minimum(din, np.max(s @ e[:, :3].T + e[:, 3], axis=1))
        dab = np.minimum(dab, np.max(above @ e[:, :3].T + e[:, 3], axis=1))
    return {"miss": float((din > 0.03).mean()), "excess": float((dab < 0).mean()), "maxMiss": float(din.max()),
            "openSky": round(float(open_sky.mean()), 3)}


def hull_faces(flat):
    """Hull triangles of a piece's points, wound counter-clockwise seen from outside."""
    pts = np.asarray(flat, dtype=float).reshape(-1, 3)
    try:
        hull = ConvexHull(pts)
    except Exception:
        return []
    faces = []
    for (a, b, c), eq in zip(hull.simplices, hull.equations):
        if np.dot(np.cross(pts[b] - pts[a], pts[c] - pts[a]), eq[:3]) < 0:
            b, c = c, b
        faces.extend((int(a), int(b), int(c)))
    return faces


def add_faces():
    """Writes `faces` into every existing output from its stored points."""
    names = [f for f in os.listdir(OUT) if f.endswith(".json") and f != "index.json"]
    for name in names:
        full = os.path.join(OUT, name)
        data = json.load(open(full))
        for piece in data["pieces"]:
            piece["faces"] = hull_faces(piece["points"])
        with open(full, "w") as f:
            json.dump(data, f, separators=(",", ":"))
    print("faces written to", len(names), "files")


def top2(w):
    order = np.argsort(-w)
    b0 = int(order[0])
    b1 = int(order[1]) if len(w) > 1 else b0
    w0, w1 = w[b0], (w[b1] if b1 != b0 else 0.0)
    if w1 < 0.005:
        return b0, b0, 0.0
    return b0, b1, round(float(w1 / (w0 + w1)), 3)


def glb_path(glb_root, path):
    return os.path.join(glb_root, path.replace("\\", os.sep)[:-5] + ".glb")


def run(job):
    path, out_name, glb_root, report_dir = job
    t = time.time()
    glb = glb_path(glb_root, path)
    if not os.path.exists(glb):
        return path, None, "no glb"
    done = os.path.join(report_dir, out_name + ".stats.json")
    if os.path.exists(done) and os.path.exists(os.path.join(OUT, out_name + ".json")):
        return path, json.load(open(done)), None
    try:
        mesh = D.read_mesh(glb)
        if mesh is None:
            return path, None, "no skin"
        res, err = D.decompose(glb, mesh["bones"])
        if err:
            return path, None, err
        pieces = res["pieces"]
        classify(pieces)
        out = {"version": 1, "mesh": path, "bones": res["nbones"], "tolerance": D.TOL,
               "materials": {"ground": ground_material(file_name(path)), "raised": "concrete.physmat",
                             "wall": "concrete.physmat"},
               "pieces": []}
        for p in pieces:
            weights = []
            for w in p["w"]:
                weights.extend(top2(w))
            points = [float(x) for x in np.round(p["pts"], 3).reshape(-1)]
            out["pieces"].append({"class": p["class"], "slice": p["slice"], "points": points, "weights": weights,
                                  "faces": hull_faces(points)})
        stats = {"pieces": len(pieces), "tris": res["tris"], "time": round(time.time() - t, 2),
                 "verts": int(sum(len(p["pts"]) for p in pieces)), "qa": qa(mesh, pieces),
                 "classes": {c: sum(1 for p in pieces if p["class"] == c) for c in ("ground", "raised", "wall")}}
        with open(os.path.join(OUT, out_name + ".json"), "w") as f:
            json.dump(out, f, separators=(",", ":"))
        with open(done, "w") as f:
            json.dump(stats, f)
        return path, stats, None
    except Exception:
        return path, None, traceback.format_exc()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("glb", nargs="?", help="folder holding the exported GLBs, mirroring depot paths")
    ap.add_argument("--workers", type=int, default=max(1, (os.cpu_count() or 2) - 2))
    ap.add_argument("--filter", default="", help="only meshes whose path contains this")
    ap.add_argument("--report", default=None, help="folder for stats sidecars and report.json")
    ap.add_argument("--faces", action="store_true", help="only add hull faces to the existing outputs")
    args = ap.parse_args()
    if args.faces:
        return add_faces()
    if not args.glb:
        ap.error("the GLB folder is required")
    args.report = args.report or os.path.join(args.glb, "_report")

    paths = [e["meshPath"] for e in json.load(open(RIGS))]
    os.makedirs(OUT, exist_ok=True)
    os.makedirs(args.report, exist_ok=True)
    jobs, used = [], set()
    for p in sorted(paths, key=str.lower):
        name, k = file_name(p).lower(), 2
        while name in used:
            name, k = file_name(p).lower() + "_" + str(k), k + 1
        used.add(name)
        jobs.append((p, name, args.glb, args.report))
    selected = [j for j in jobs if args.filter.lower() in j[0].lower()]
    # largest first, so the long ones do not end the run alone
    selected.sort(key=lambda j: -os.path.getsize(glb_path(args.glb, j[0])) if os.path.exists(glb_path(args.glb, j[0])) else 0)

    t = time.time()
    report = {}
    with Pool(args.workers) as pool:
        for path, stats, err in pool.imap_unordered(run, selected):
            report[path] = {"stats": stats, "error": err}
            print(len(report), "/", len(selected), "%.0fs" % (time.time() - t), path.split("\\")[-1], flush=True)
    json.dump(report, open(os.path.join(args.report, "report.json"), "w"), indent=1)

    # the index lists every mesh with an output, whatever this run covered
    index = {p.lower(): name for p, name, _, _ in jobs if os.path.exists(os.path.join(OUT, name + ".json"))}
    with open(os.path.join(OUT, "index.json"), "w") as f:
        json.dump(index, f, separators=(",", ":"), sort_keys=True)
    errors = {p: r["error"] for p, r in report.items() if r["error"]}
    print("done", len(report) - len(errors), "/", len(report), "in %.0fs" % (time.time() - t))
    for p, e in errors.items():
        print("ERR", p, e.strip().splitlines()[-1])


if __name__ == "__main__":
    sys.exit(main())
