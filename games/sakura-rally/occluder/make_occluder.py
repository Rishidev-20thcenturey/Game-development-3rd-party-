#!/usr/bin/env python3
"""Builds mobile/terrain_occluder.bin: a lowered copy of the Sakura Rally terrain for
Godot's occlusion culling (Game-development-3rd-party, MIT).

Godot culls an object when every ray of its small CPU depth buffer that could see it hits an
occluder first. The occluder here is a regular G-metre grid that is guaranteed to lie at least
MARGIN metres *below* every terrain surface the game draws (near chunks, their far LODs and the
unranged chunks): nothing that is visible over a ridge can be culled, only what the hill really
hides. So the picture stays the same; the GPU just stops drawing forest behind mountains.

How "below" is guaranteed: the near terrain is a 4 m grid aligned with the occluder's 8 m grid,
so every vertex of the overlay of the two triangulations lies on a 2 m lattice. Both surfaces
are linear between those points, so checking the 2 m lattice checks every point. The occluder
starts at terrain height - MARGIN at its nodes; any lattice sample still above
(terrain - MARGIN) lowers the three nodes of its triangle, until none is. The far LOD meshes are
not on the lattice; their sampling error is far below MARGIN at the distances they are drawn.

  python3 make_occluder.py <upstream checkout> <out.bin>
Needs numpy. Output (gzip): b"SROC", u32 version, u32 vertex count, u32 index count,
f32 grid, f32 margin, then vertices (f32 x,y,z) and indices (u32), little endian.
"""
import gzip
import json
import struct
import sys

import numpy as np

G = 8.0        # occluder grid (m); the terrain grid is 4 m
LATTICE = 2.0  # sampling lattice (m): every overlay vertex lies on it
MARGIN = 1.0   # occluder sits at least this far below every drawn terrain surface (m)


def load(root):
    info = json.load(open(root + "/assets/maps/world/map.json"))
    data = open(root + "/" + info["bin"].replace("res://", ""), "rb").read()
    return info, data


def mesh(data, m):
    off = m["offset"]
    vc = m["vcount"]
    pos = idx = None
    for a in m["attrs"]:
        if a == "pos":
            pos = np.frombuffer(data, np.float32, vc * 3, off).reshape(-1, 3).astype(np.float64)
            off += vc * 12
        elif a == "nrm":
            off += vc * 12
        elif a == "col":
            off += vc * 16
        elif a == "uv":
            off += vc * 8
        elif a == "idx":
            idx = np.frombuffer(data, np.int32, m["icount"], off).reshape(-1, 3)
            off += m["icount"] * 4
    return pos, idx


def rasterize_min(tris, x0, z0, nx, nz, step, out):
    """out[j, i] = min over triangles covering lattice point (x0 + i*step, z0 + j*step) of the
    triangle's height there (points on edges count for both sides)."""
    ax, az, ay = tris[:, 0, 0], tris[:, 0, 2], tris[:, 0, 1]
    bx, bz, by = tris[:, 1, 0], tris[:, 1, 2], tris[:, 1, 1]
    cx, cz, cy = tris[:, 2, 0], tris[:, 2, 2], tris[:, 2, 1]
    i0 = np.ceil((np.minimum(np.minimum(ax, bx), cx) - x0) / step - 1e-6).astype(int)
    i1 = np.floor((np.maximum(np.maximum(ax, bx), cx) - x0) / step + 1e-6).astype(int)
    j0 = np.ceil((np.minimum(np.minimum(az, bz), cz) - z0) / step - 1e-6).astype(int)
    j1 = np.floor((np.maximum(np.maximum(az, bz), cz) - z0) / step + 1e-6).astype(int)
    den = (bz - cz) * (ax - cx) + (cx - bx) * (az - cz)
    ok = np.abs(den) > 1e-9
    span = int(max((i1 - i0).max(), (j1 - j0).max())) + 1
    for di in range(span):
        for dj in range(span):
            i = i0 + di
            j = j0 + dj
            sel = ok & (i <= i1) & (j <= j1) & (i >= 0) & (j >= 0) & (i < nx) & (j < nz)
            if not sel.any():
                continue
            px = x0 + i[sel] * step
            pz = z0 + j[sel] * step
            d = den[sel]
            w1 = ((bz[sel] - cz[sel]) * (px - cx[sel]) + (cx[sel] - bx[sel]) * (pz - cz[sel])) / d
            w2 = ((cz[sel] - az[sel]) * (px - cx[sel]) + (ax[sel] - cx[sel]) * (pz - cz[sel])) / d
            w3 = 1.0 - w1 - w2
            inside = (w1 >= -1e-6) & (w2 >= -1e-6) & (w3 >= -1e-6)
            h = w1 * ay[sel] + w2 * by[sel] + w3 * cy[sel]
            np.minimum.at(out, (j[sel][inside], i[sel][inside]), h[inside])


def build(root):
    info, data = load(root)
    x0, z0, x1, z1 = info["bounds"]
    nx = int(round((x1 - x0) / LATTICE)) + 1
    nz = int(round((z1 - z0) / LATTICE)) + 1
    truth = np.full((nz, nx), np.inf)
    for m in info["meshes"]:
        if m["material"] != "terrain":
            continue
        pos, idx = mesh(data, m)
        rasterize_min(pos[idx], x0, z0, nx, nz, LATTICE, truth)
    k = int(round(G / LATTICE))
    gx = (nx - 1) // k + 1
    gz = (nz - 1) // k + 1
    limit = truth - MARGIN  # occluder must stay <= this at every lattice sample
    node = limit[::k, ::k][:gz, :gx].copy()
    node[~np.isfinite(node)] = np.nan  # no terrain there: quads touching it are left out

    # lattice samples -> occluder quad (qi, qj), local (u, v) in [0, 1]
    jj, ii = np.nonzero(np.isfinite(limit))
    qi = np.minimum(ii // k, gx - 2)
    qj = np.minimum(jj // k, gz - 2)
    u = ii / k - qi
    v = jj / k - qj
    upper = v > u  # triangle (00, 11, 01) else (00, 10, 11); diagonal 00-11
    lim = limit[jj, ii]
    for it in range(60):
        h00 = node[qj, qi]
        h10 = node[qj, qi + 1]
        h01 = node[qj + 1, qi]
        h11 = node[qj + 1, qi + 1]
        occ = np.where(upper, (1 - v) * h00 + u * h11 + (v - u) * h01,
                       (1 - u) * h00 + (u - v) * h10 + v * h11)
        viol = occ - lim
        viol[~np.isfinite(viol)] = 0.0
        bad = viol > 1e-4
        if not bad.any():
            break
        need = np.zeros_like(node)
        nb = np.nan_to_num(viol[bad])
        bq_i, bq_j, bup = qi[bad], qj[bad], upper[bad]
        for (oj, oi), m_ in (((0, 0), np.ones_like(bup)), ((1, 1), np.ones_like(bup)), ((1, 0), bup), ((0, 1), ~bup)):
            s = m_.astype(bool)
            np.maximum.at(need, (bq_j[s] + oj, bq_i[s] + oi), nb[s])
        node -= need
    else:
        raise SystemExit("occluder fit did not converge")
    # quads whose four nodes all exist
    q = np.isfinite(node[:-1, :-1]) & np.isfinite(node[1:, :-1]) & np.isfinite(node[:-1, 1:]) & np.isfinite(node[1:, 1:])
    vid = -np.ones(node.shape, np.int64)
    used = np.zeros(node.shape, bool)
    qj_, qi_ = np.nonzero(q)
    for oj, oi in ((0, 0), (0, 1), (1, 0), (1, 1)):
        used[qj_ + oj, qi_ + oi] = True
    vj, vi = np.nonzero(used)
    vid[vj, vi] = np.arange(len(vj))
    verts = np.stack([x0 + vi * G, node[vj, vi], z0 + vj * G], 1).astype(np.float32)
    a = vid[qj_, qi_]
    b_ = vid[qj_, qi_ + 1]
    c = vid[qj_ + 1, qi_ + 1]
    d_ = vid[qj_ + 1, qi_]
    idx = np.concatenate([np.stack([a, b_, c], 1), np.stack([a, c, d_], 1)]).astype(np.uint32)
    gap = (truth[::k, ::k][:gz, :gx] - node)[np.isfinite(node) & np.isfinite(truth[::k, ::k][:gz, :gx])]
    stats = {"iterations": it, "vertices": len(verts), "triangles": len(idx),
             "gap_median": float(np.median(gap)), "gap_p90": float(np.percentile(gap, 90))}
    return verts, idx, stats


def main():
    root, out = sys.argv[1], sys.argv[2]
    verts, idx, stats = build(root)
    head = b"SROC" + struct.pack("<IIIff", 1, len(verts), idx.size, G, MARGIN)
    with open(out, "wb") as f:
        f.write(gzip.compress(head + verts.astype("<f4").tobytes() + idx.astype("<u4").tobytes(), 9, mtime=0))
    print("occluder:", stats)


if __name__ == "__main__":
    main()
