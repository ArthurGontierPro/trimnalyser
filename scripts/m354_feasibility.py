#!/usr/bin/env python3
"""M3.5.4 feasibility assessment. Stdlib + pandas/numpy only, no scipy.

Answers 5 questions per family, for BOTH runs (6-29 default adjacency, 8-3 lazy):
  1. base rate of gNadj>0 + majority-class baseline
  2. effective n (distinct patterns / targets / pairs)
  3. between-DISTINCT-GRAPH variance of candidate predictors
  4. outcome variance explained by family alone
  5. point-biserial r with effective-n correction + pattern-clustered permutation
"""
import sys, re, math
import numpy as np
import pandas as pd

FAMS = ["LV", "bio", "images-CVIU11", "meshes-CVIU11"]
PREDS = ["pat_triangles", "pat_clustering", "density_ratio",
         "node_ratio", "pat_deg_var", "diameter_ratio"]

RES_COLS = ["instance", "family", "grim_cone_g1adj", "grim_cone_g2adj",
            "grim_cone_g3adj", "grim_cone_g0adj", "grim_full_g1adj",
            "solver_nodes", "has_proof", "is_unsat", "grim_total_cone"]
GF_COLS = ["instance"] + PREDS + ["pat_nodes", "pat_edges", "tar_nodes", "tar_edges"]


def graph_key(name):
    """(pattern_id, target_id) from instance name. None if unparsed."""
    m = re.match(r"^LV(g\d+)(g\d+)$", name)
    if m:
        return m.group(1), m.group(2)
    m = re.match(r"^bio(\d{3})(\d{3})$", name)
    if m:
        return "b" + m.group(1), "b" + m.group(2)
    m = re.match(r"^(cviu11|mesh11)_(p\d+)_(t\d+)$", name)
    if m:
        return m.group(1) + "_" + m.group(2), m.group(1) + "_" + m.group(3)
    return None


def load(run):
    res = pd.read_csv(f"{run}/cluster_results.csv", usecols=lambda c: c in RES_COLS,
                      low_memory=False)
    gf = pd.read_csv(f"{run}/graph_features.csv",
                     usecols=lambda c: c in GF_COLS, low_memory=False)
    for d in (res, gf):
        d["instance"] = d["instance"].astype(str).str.strip('"')
    df = res.merge(gf, on="instance", how="inner")
    n_all = len(df)
    # exclude resolv-iteration rows: not independent observations of a graph pair
    df = df[~df["instance"].str.contains(r"\.core", regex=True)]
    n_nocore = len(df)
    # need a trimmed cone to have a label count at all
    df = df[pd.to_numeric(df["grim_total_cone"], errors="coerce").fillna(0) > 0]
    keys = df["instance"].map(graph_key)
    df = df[keys.notna()].copy()
    kk = df["instance"].map(graph_key)
    df["pat"] = [k[0] for k in kk]
    df["tar"] = [k[1] for k in kk]
    for c in ["grim_cone_g1adj", "grim_cone_g2adj", "grim_cone_g3adj",
              "grim_cone_g0adj", "grim_full_g1adj", "solver_nodes"]:
        df[c] = pd.to_numeric(df[c], errors="coerce").fillna(0)
    for c in PREDS:
        df[c] = pd.to_numeric(df[c], errors="coerce")
    df["g1adj_used"] = (df["grim_cone_g1adj"] > 0).astype(int)
    df["g2adj_used"] = (df["grim_cone_g2adj"] > 0).astype(int)
    df["g3adj_used"] = (df["grim_cone_g3adj"] > 0).astype(int)
    df["searched"] = (df["solver_nodes"] > 1).astype(int)
    return df, n_all, n_nocore


def sanity_graph_ids(df, fam):
    """A pattern id must map to ONE graph. Check pat_nodes/pat_edges constancy."""
    sub = df[df.family == fam]
    bad = 0
    g = sub.groupby("pat")[["pat_nodes", "pat_edges"]].nunique()
    bad = int(((g > 1).any(axis=1)).sum())
    gt = sub.groupby("tar")[["tar_nodes", "tar_edges"]].nunique()
    badt = int(((gt > 1).any(axis=1)).sum())
    return bad, len(g), badt, len(gt)


def icc_binary(y, groups):
    """One-way random-effects ICC of a binary outcome across clusters."""
    dfy = pd.DataFrame({"y": y, "g": groups})
    k = dfy.groupby("g")["y"].size()
    if len(k) < 2:
        return np.nan, np.nan
    means = dfy.groupby("g")["y"].mean()
    grand = dfy["y"].mean()
    n = len(dfy)
    ngroups = len(k)
    msb = (k * (means - grand) ** 2).sum() / (ngroups - 1)
    ssw = ((dfy["y"] - dfy["g"].map(means)) ** 2).sum()
    msw = ssw / (n - ngroups) if n > ngroups else np.nan
    k0 = (n - (k ** 2).sum() / n) / (ngroups - 1)
    if not np.isfinite(msw) or msb + (k0 - 1) * msw == 0:
        return np.nan, k.mean()
    icc = (msb - msw) / (msb + (k0 - 1) * msw)
    return float(np.clip(icc, 0, 1)), float(k.mean())


def pointbiserial(x, y):
    m = np.isfinite(x) & np.isfinite(y)
    x, y = x[m], y[m]
    if len(x) < 3 or np.std(x) == 0 or np.std(y) == 0:
        return np.nan, len(x)
    return float(np.corrcoef(x, y)[0, 1]), len(x)


def cluster_perm_p(x, y, clusters, r_obs, nperm=2000, seed=0):
    """Permute the OUTCOME at cluster (pattern) level, as sec.7's test does.

    Whole clusters swap their outcome vectors, so within-pattern dependence is
    preserved under the null.
    """
    rng = np.random.default_rng(seed)
    m = np.isfinite(x) & np.isfinite(y)
    x, y, c = x[m], y[m], np.asarray(clusters)[m]
    if len(x) < 3 or np.std(x) == 0 or np.std(y) == 0 or not np.isfinite(r_obs):
        return np.nan, np.nan
    codes, _ = pd.factorize(c)
    ncl = codes.max() + 1
    if ncl < 3:
        return np.nan, ncl
    order = np.argsort(codes, kind="stable")
    xs, ys, cs = x[order], y[order], codes[order]
    bounds = np.searchsorted(cs, np.arange(ncl + 1))
    hits = 0
    for _ in range(nperm):
        perm = rng.permutation(ncl)
        # rebuild outcome by pasting permuted clusters' y-blocks onto the x-order,
        # only valid when block sizes match; otherwise resample cluster means
        idx = np.concatenate([np.arange(bounds[p], bounds[p + 1]) for p in perm])
        yp = ys[idx]
        if len(yp) != len(xs):
            continue
        if np.std(yp) == 0:
            continue
        r = np.corrcoef(xs, yp)[0, 1]
        if abs(r) >= abs(r_obs):
            hits += 1
    return (hits + 1) / (nperm + 1), ncl


def eta2_family(df, col):
    """Fraction of outcome variance explained by family membership alone."""
    y = df[col].to_numpy(float)
    grand = y.mean()
    sst = ((y - grand) ** 2).sum()
    if sst == 0:
        return 1.0
    ssb = 0.0
    for _, sub in df.groupby("family"):
        yy = sub[col].to_numpy(float)
        ssb += len(yy) * (yy.mean() - grand) ** 2
    return float(ssb / sst)


def main(runs):
    out = []
    P = out.append
    for run in runs:
        df, n_all, n_nocore = load(run)
        P("=" * 78)
        P(f"RUN {run}   rows(joined)={n_all}  after .core drop={n_nocore}  "
          f"after cone-present+parsable={len(df)}")
        P("=" * 78)

        d4 = df[df.family.isin(FAMS)]
        P("\n[Q4] variance of outcome explained by FAMILY alone (eta^2, 4 families)")
        for tgt in ["g1adj_used", "g2adj_used", "g3adj_used"]:
            P(f"   {tgt:12s} eta^2 = {eta2_family(d4, tgt):.4f}")
        P(f"   {'searched':12s} eta^2 = {eta2_family(d4, 'searched'):.4f}   "
          "(solver did any search at all)")
        # family+search two-way
        d4 = d4.copy()
        d4["fam_search"] = d4["family"] + "|" + d4["searched"].astype(str)
        y = d4["g1adj_used"].to_numpy(float)
        sst = ((y - y.mean()) ** 2).sum()
        ssb = sum(len(s) * (s["g1adj_used"].mean() - y.mean()) ** 2
                  for _, s in d4.groupby("fam_search"))
        P(f"   g1adj_used   eta^2 = {ssb/sst:.4f}   (family x searched, 8 cells)")

        for fam in FAMS:
            sub = df[df.family == fam]
            if len(sub) == 0:
                P(f"\n### {fam}: no rows")
                continue
            P("\n" + "-" * 74)
            P(f"### {fam}   n_rows = {len(sub)}")
            P("-" * 74)

            # Q1 base rates
            P("[Q1] base rate / majority-class baseline")
            for tgt in ["g1adj_used", "g2adj_used", "g3adj_used"]:
                p = sub[tgt].mean()
                k = int(sub[tgt].sum())
                P(f"   {tgt:12s} P(>0) = {p:6.4f}  ({k}/{len(sub)})   "
                  f"majority baseline acc = {max(p,1-p):6.4f}  "
                  f"majority class = {'POS' if p>0.5 else 'NEG'}")
            ns = sub[sub.searched == 0]
            ws = sub[sub.searched == 1]
            P(f"   search split: no-search n={len(ns)} g1rate={ns.g1adj_used.mean() if len(ns) else float('nan'):.4f}"
              f" | with-search n={len(ws)} g1rate={ws.g1adj_used.mean() if len(ws) else float('nan'):.4f}")

            # Q2 effective n
            bad_p, npat, bad_t, ntar = sanity_graph_ids(df, fam)
            npair = sub.groupby(["pat", "tar"]).ngroups
            P("[Q2] effective n")
            P(f"   rows={len(sub)}  distinct patterns={npat}  distinct targets={ntar}"
              f"  distinct (pat,tar) pairs={npair}")
            P(f"   id sanity: patterns with non-constant (pat_nodes,pat_edges) = {bad_p}; "
              f"targets non-constant = {bad_t}")
            P(f"   rows per pattern (mean) = {len(sub)/max(npat,1):.1f}")
            for tgt in ["g1adj_used"]:
                icc, kbar = icc_binary(sub[tgt].to_numpy(float), sub["pat"].to_numpy())
                if np.isfinite(icc):
                    deff = 1 + (kbar - 1) * icc
                    P(f"   {tgt}: ICC(pattern) = {icc:.4f}  mean cluster = {kbar:.1f}  "
                      f"design effect = {deff:.2f}  n_eff = {len(sub)/deff:.1f}")
                    P(f"   -> real degrees of freedom for a per-family rule: "
                      f"min(n_eff, distinct patterns) = {min(len(sub)/deff, npat):.1f}")
                else:
                    P(f"   {tgt}: ICC undefined (outcome constant or <2 clusters); "
                      f"n_eff capped by distinct patterns = {npat}")

            # Q3 between-distinct-graph variance
            P("[Q3] predictor variance BETWEEN DISTINCT GRAPHS (not rows)")
            P(f"   {'feature':16s} {'n_uniq_vals':>11s} {'median':>12s} {'IQR':>12s} "
              f"{'CV':>8s} {'modal_frac':>10s}  level")
            pat_lvl = sub.drop_duplicates("pat")
            pair_lvl = sub.drop_duplicates(["pat", "tar"])
            for f in PREDS:
                lvl, d = ("pattern", pat_lvl) if f.startswith("pat_") else ("pair", pair_lvl)
                v = d[f].dropna().to_numpy(float)
                if len(v) == 0:
                    P(f"   {f:16s} {'--- all NaN ---':>11s}")
                    continue
                q1, med, q3 = np.percentile(v, [25, 50, 75])
                cv = v.std() / abs(v.mean()) if v.mean() != 0 else np.inf
                vals, cnts = np.unique(v, return_counts=True)
                P(f"   {f:16s} {len(vals):11d} {med:12.5g} {q3-q1:12.5g} "
                  f"{cv:8.3f} {cnts.max()/len(v):10.3f}  {lvl} (n={len(v)})")

            # Q5 point-biserial, effective-n corrected, pattern-clustered permutation
            P("[Q5] point-biserial r vs g1adj_used  (clustered by pattern)")
            y = sub["g1adj_used"].to_numpy(float)
            if y.std() == 0:
                P("   outcome is constant in this family -- correlation undefined, "
                  "no classifier is even definable here")
            else:
                icc_y, kbar = icc_binary(y, sub["pat"].to_numpy())
                P(f"   {'feature':16s} {'r_pb':>8s} {'r^2':>7s} {'n':>7s} "
                  f"{'n_eff':>8s} {'naive p':>9s} {'eff-n p':>9s} {'clust p':>9s}")
                for f in PREDS:
                    x = sub[f].to_numpy(float)
                    r, n = pointbiserial(x, y)
                    if not np.isfinite(r):
                        P(f"   {f:16s} {'n/a (const or all-NaN)':>8s}")
                        continue
                    icc_x, _ = icc_binary(
                        pd.Series(x).rank(pct=True).fillna(0.5).to_numpy(),
                        sub["pat"].to_numpy())
                    rho = (icc_x or 0) * (icc_y or 0)
                    deff = max(1.0, 1 + (kbar - 1) * rho)
                    neff = n / deff
                    t = abs(r) * np.sqrt(max(n - 2, 1) / max(1 - r * r, 1e-12))
                    pn = 2 * (1 - _norm_cdf(t))
                    te = abs(r) * np.sqrt(max(neff - 2, 1) / max(1 - r * r, 1e-12))
                    pe = 2 * (1 - _norm_cdf(te))
                    pc, ncl = cluster_perm_p(x, y, sub["pat"].to_numpy(), r)
                    P(f"   {f:16s} {r:8.4f} {r*r:7.4f} {n:7d} {neff:8.1f} "
                      f"{pn:9.2e} {pe:9.2e} "
                      f"{pc if np.isfinite(pc) else float('nan'):9.4f}")
                # reference: how well does 'searched' alone do
                r_s, _ = pointbiserial(sub["searched"].to_numpy(float), y)
                P(f"   {'[ref] searched':16s} {r_s:8.4f} {r_s*r_s:7.4f}   "
                  "<- non-structural, not available pre-solve")
    print("\n".join(out))


def _norm_cdf(z):
    return 0.5 * (1 + math.erf(z / math.sqrt(2)))


if __name__ == "__main__":
    main(sys.argv[1:])
