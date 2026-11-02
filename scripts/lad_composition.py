#!/usr/bin/env python3
"""LAD construct composition, full certificate vs cone (the fig:composition reading).
# Moved from /scratch/arthur/ladlabels/ (node-local, volatile) into the repo 2026-11-02.
Usage: lad_composition.py results.csv  -- rows with veri_smol_status == VERIFIED, base instances only."""
import sys, pandas as pd
d = pd.read_csv(sys.argv[1], low_memory=False)
d = d[~d.instance.str.contains(r"\.core", regex=True)]
print("rows", len(d), "smol VERIFIED", int(d.veri_smol_status.eq("VERIFIED").sum()),
      "full VERIFIED", int(d.veri_full_status.eq("VERIFIED").sum()) if "veri_full_status" in d else "?")
d = d[d.veri_smol_status.eq("VERIFIED")].copy()
lad = [c[len("grim_full_"):] for c in d.columns if c.startswith("grim_full_lad")]
opb = ["al1", "am1", "inj", "g0adj"]
fam = d.family.map(lambda f: {"images-CVIU11": "images", "meshes-CVIU11": "meshes"}.get(f, f))
for f in sorted(fam.unique()) + ["ALL"]:
    s = d if f == "ALL" else d[fam == f]
    full = {t: s[f"grim_full_{t}"].fillna(0).sum() for t in opb + lad}
    cone = {t: s[f"grim_cone_{t}"].fillna(0).sum() for t in opb + lad}
    tot_full = sum(full.values()); tot_cone = sum(cone.values())
    unl_f = s.grim_full_unlabeled.fillna(0).sum(); unl_c = s.grim_cone_unlabeled.fillna(0).sum()
    print(f"\n## {f}  n={len(s)}  steps full={int(tot_full)} cone={int(tot_cone)} ({tot_cone/max(tot_full,1):.3%})  unlabeled {int(unl_c)}/{int(unl_f)}")
    print(f"{'construct':12} {'full':>10} {'share':>7} {'cone':>8} {'share':>7} {'kept':>7}")
    for t in opb + lad:
        if full[t] == 0: continue
        print(f"{t:12} {int(full[t]):10d} {full[t]/tot_full:7.2%} {int(cone[t]):8d} {cone[t]/max(tot_cone,1):7.2%} {cone[t]/full[t]:7.2%}")
    # derived-only view
    df = sum(full[t] for t in lad); dc = sum(cone[t] for t in lad)
    print(f"derived only: full={int(df)} cone={int(dc)} kept={dc/max(df,1):.2%}")
