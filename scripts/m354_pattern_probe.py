#!/usr/bin/env python3
"""M3.5.4 pattern-level probe — the follow-up that decides the verdict.

Two questions the row-level feasibility numbers cannot answer:
  (a) is the images-CVIU11 signal anything beyond pattern identity and the
      pattern-order/density collinearity that sank the notes.tex sec.7 claim?
  (b) would a per-TARGET framing have more degrees of freedom than per-pattern?

Usage: python3 scripts/m354_pattern_probe.py 8-3-fullrun 6-29-fullrun
"""
import os, sys
import numpy as np, pandas as pd

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from m354_feasibility import load, icc_binary, PREDS

def part_a_collinearity(runs):
    for run in sys.argv[1:]:
        df, _, _ = load(run)
        for fam in ["images-CVIU11", "bio", "LV"]:
            sub = df[df.family == fam].copy()
            if sub["g1adj_used"].std() == 0:
                continue
            print("=" * 76)
            print(f"{run}  /  {fam}   rows={len(sub)}")
            print("=" * 76)
    
            # --- pattern-level aggregation: the honest unit of observation ---
            agg = sub.groupby("pat").agg(
                n=("g1adj_used", "size"),
                rate=("g1adj_used", "mean"),
                pat_nodes=("pat_nodes", "first"),
                pat_edges=("pat_edges", "first"),
                pat_triangles=("pat_triangles", "first"),
                pat_clustering=("pat_clustering", "first"),
                pat_deg_var=("pat_deg_var", "first"),
                density_ratio=("density_ratio", "median"),
                node_ratio=("node_ratio", "median"),
            )
            agg["pat_density"] = 2 * agg.pat_edges / (agg.pat_nodes * (agg.pat_nodes - 1))
            pure0 = int((agg.rate == 0).sum()); pure1 = int((agg.rate == 1).sum())
            print(f"pattern-level units: {len(agg)}   "
                  f"all-negative patterns={pure0}  all-positive patterns={pure1}  "
                  f"mixed={len(agg)-pure0-pure1}")
            print(f"  -> a per-pattern LOOKUP TABLE gets "
                  f"{(agg.n*np.maximum(agg.rate,1-agg.rate)).sum()/agg.n.sum():.4f} accuracy "
                  f"on these rows by construction (43-cell memorisation, 0 generalisation)")
    
            # --- collinearity among candidate predictors AT PATTERN LEVEL ---
            cols = ["pat_nodes", "pat_edges", "pat_density", "pat_triangles",
                    "pat_clustering", "pat_deg_var"]
            print("\nCollinearity between candidate predictors, across DISTINCT PATTERNS "
                  f"(n={len(agg)}):")
            C = agg[cols].corr(method="spearman")
            print(C.round(3).to_string())
    
            # --- predictor vs outcome at pattern level ---
            print(f"\nPattern-level correlation with pattern g1adj rate (n={len(agg)}):")
            for c in cols + ["density_ratio", "node_ratio"]:
                v = agg[c].to_numpy(float); y = agg["rate"].to_numpy(float)
                m = np.isfinite(v) & np.isfinite(y)
                if m.sum() < 5 or np.std(v[m]) == 0:
                    print(f"  {c:15s}  constant / too few")
                    continue
                r = np.corrcoef(v[m], y[m])[0, 1]
                rs = pd.Series(v[m]).rank().corr(pd.Series(y[m]).rank())
                # weighted by rows, for reference only
                print(f"  {c:15s}  pearson r={r:+.3f}  spearman={rs:+.3f}  "
                      f"r^2={r*r:.3f}   (n_units={m.sum()})")
    
            # --- can pat_triangles beat pat_nodes at all? partial check ---
            if fam == "images-CVIU11":
                y = agg["rate"].to_numpy(float)
                for a, b in [("pat_triangles", "pat_nodes"), ("density_ratio", "pat_nodes"),
                             ("pat_triangles", "pat_density")]:
                    xa = agg[a].to_numpy(float); xb = agg[b].to_numpy(float)
                    m = np.isfinite(xa) & np.isfinite(xb) & np.isfinite(y)
                    if m.sum() < 6:
                        continue
                    # residualise a on b, then correlate residual with y
                    A = np.c_[np.ones(m.sum()), xb[m]]
                    beta = np.linalg.lstsq(A, xa[m], rcond=None)[0]
                    res = xa[m] - A @ beta
                    r_raw = np.corrcoef(xa[m], y[m])[0, 1]
                    r_par = np.corrcoef(res, y[m])[0, 1] if np.std(res) > 0 else np.nan
                    print(f"  partial: {a} | controlling for {b}:  "
                          f"raw r={r_raw:+.3f} -> partial r={r_par:+.3f}")
    
            # --- how many distinct pattern *sizes* are there really ---
            print(f"\ndistinct pat_nodes values among patterns: "
                  f"{agg.pat_nodes.nunique()}  -> {sorted(agg.pat_nodes.unique())[:20]}")
            print()


def part_b_decisive(runs):
    rng = np.random.default_rng(7)
    
    for run in sys.argv[1:]:
        df, _, _ = load(run)
        print("#" * 76)
        print("RUN", run)
        print("#" * 76)
        for fam in ["images-CVIU11", "bio", "LV"]:
            sub = df[df.family == fam].copy()
            if sub["g1adj_used"].std() == 0:
                print(f"\n{fam}: outcome constant, skipped"); continue
            y = sub["g1adj_used"].to_numpy(float)
            icc_p, kp = icc_binary(y, sub["pat"].to_numpy())
            icc_t, kt = icc_binary(y, sub["tar"].to_numpy())
            print(f"\n--- {fam}  rows={len(sub)} ---")
            print(f"  ICC by PATTERN = {icc_p:.4f}  (clusters={sub.pat.nunique()}, "
                  f"mean size {kp:.1f})  n_eff={len(sub)/(1+(kp-1)*icc_p):.1f}")
            print(f"  ICC by TARGET  = {icc_t:.4f}  (clusters={sub.tar.nunique()}, "
                  f"mean size {kt:.1f})  n_eff={len(sub)/(1+(kt-1)*icc_t):.1f}")
    
            agg = sub.groupby("pat").agg(n=("g1adj_used", "size"),
                                         rate=("g1adj_used", "mean"),
                                         pat_nodes=("pat_nodes", "first"),
                                         pat_triangles=("pat_triangles", "first"))
            if agg.pat_triangles.nunique() < 3:
                print("  pat_triangles constant across patterns -- nothing to partial out")
                continue
            yv = agg.rate.to_numpy(float)
            xa = agg.pat_triangles.to_numpy(float)
            xb = agg.pat_nodes.to_numpy(float)
            A = np.c_[np.ones(len(xb)), xb]
            res = xa - A @ np.linalg.lstsq(A, xa, rcond=None)[0]
            r_par = np.corrcoef(res, yv)[0, 1]
            # permutation on the 43 pattern units: the honest test
            null = np.array([abs(np.corrcoef(res, rng.permutation(yv))[0, 1])
                             for _ in range(20000)])
            p = (np.sum(null >= abs(r_par)) + 1) / (len(null) + 1)
            print(f"  pat_triangles partial-on-pat_nodes at PATTERN level: "
                  f"r={r_par:+.3f}  r^2={r_par**2:.3f}  n_units={len(agg)}  "
                  f"permutation p={p:.4f}")
            r_raw = np.corrcoef(xa, yv)[0, 1]
            nullr = np.array([abs(np.corrcoef(xa, rng.permutation(yv))[0, 1])
                              for _ in range(20000)])
            pr = (np.sum(nullr >= abs(r_raw)) + 1) / (len(nullr) + 1)
            print(f"  pat_triangles RAW at pattern level: r={r_raw:+.3f} "
                  f"permutation p={pr:.4f}")
            # what does the best single-threshold rule on pat_triangles actually buy?
            best = None
            for thr in np.unique(xa):
                for sign in (1, -1):
                    pred = (sign * xa >= sign * thr)
                    if pred.sum() == 0 or pred.sum() == len(pred):
                        continue
                    # row-weighted precision for predicting "g1adj used"
                    tp = (agg.n * agg.rate * pred).sum()
                    fp = (agg.n * (1 - agg.rate) * pred).sum()
                    prec = tp / (tp + fp)
                    rec = tp / (agg.n * agg.rate).sum()
                    npat = int(pred.sum())
                    if best is None or prec > best[0]:
                        best = (prec, rec, thr, sign, npat)
            base = (agg.n * agg.rate).sum() / agg.n.sum()
            print(f"  best single threshold on pat_triangles: precision={best[0]:.3f} "
                  f"recall={best[1]:.3f} (thr={best[2]:g}, sign={best[3]}, "
                  f"{best[4]}/{len(agg)} patterns selected)  vs base rate {base:.3f}")
            print("     ^ this is the IN-SAMPLE optimum over all thresholds, "
                  "no held-out patterns -- an upper bound, not an estimate")


if __name__ == "__main__":
    runs = sys.argv[1:]
    part_a_collinearity(runs)
    part_b_decisive(runs)
