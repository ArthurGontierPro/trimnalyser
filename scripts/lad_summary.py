#!/usr/bin/env python3
"""Summaries of one lad-* column CSV for the LAD Trimnalysis dashboard.
Usage: lad_summary.py results.csv outdir   -> families.json, composition.json, values.txt"""
import sys, json, os, pandas as pd, numpy as np
src, out = sys.argv[1], sys.argv[2]; os.makedirs(out, exist_ok=True)
d = pd.read_csv(src, low_memory=False)
d = d[~d.instance.astype(str).str.contains(r"\.core", regex=True)].copy()
fam = d.family.map(lambda f: {"images-CVIU11": "images", "meshes-CVIU11": "meshes", "images-PR15": "images-PR15",
                              "biochemicalReactions": "bio"}.get(f, f))
d["fam"] = fam
with open(f"{out}/values.txt", "w") as f:
    for c in ["solve_verdict", "nopl_verdict", "status", "skip_reason", "has_proof", "veri_full_status", "veri_smol_status",
              "cake_full_status", "cakeiso_full_status", "resolv_stop_reason", "error_type"]:
        if c in d: f.write(f"== {c}\n{d[c].value_counts(dropna=False).to_string()}\n")
num = lambda s: pd.to_numeric(s, errors="coerce")
def med(s):
    s = num(s).dropna(); return None if len(s) == 0 else float(s.median())
rows = []
for fname in sorted(d.fam.unique()) + ["ALL"]:
    s = d if fname == "ALL" else d[d.fam == fname]
    sv = s.solve_verdict.astype(str) if "solve_verdict" in s else pd.Series([""]*len(s))
    st = s.status.astype(str) if "status" in s else pd.Series([""]*len(s))
    vf = s.veri_full_status.astype(str); vs = s.veri_smol_status.astype(str)
    kept_opb = num(s.grim_opb_cone) / num(s.inp_opb_nbeq); kept_pbp = num(s.grim_pbp_cone) / num(s.inp_pbp_nbeq)
    rows.append(dict(family=fname, instances=int(len(s)),
        unsat=int(sv.str.upper().eq("UNSAT").sum()), sat=int(sv.str.upper().eq("SAT").sum()),
        timeout=int(st.str.contains("timeout", case=False).sum() + sv.str.contains("timeout", case=False).sum()),
        memout=int(st.str.contains("memout", case=False).sum() + sv.str.contains("memout", case=False).sum()),
        with_proof=int(num(s.inp_pbp_size).gt(0).sum()),
        full_verified=int(vf.eq("VERIFIED").sum()), full_failed=int(vf.eq("FAILED").sum()),
        smol_verified=int(vs.eq("VERIFIED").sum()), smol_failed=int(vs.eq("FAILED").sum()),
        trimmed=int(num(s.grim_trim_time).notna().sum()),
        med_trim_s=med(s.grim_trim_time), med_solve_s=med(s.solve_time), med_veri_full_s=med(s.veri_total_time), med_veri_smol_s=med(s.veri_smol_time),
        med_proof_mb=(None if med(s.inp_pbp_size) is None else med(s.inp_pbp_size)/1e6),
        med_kept_opb=med(kept_opb), med_kept_pbp=med(kept_pbp),
        med_kept_size=med(num(s.grim_total_size)/num(s.inp_total_size)),
        p90_kept_pbp=(None if kept_pbp.dropna().empty else float(kept_pbp.dropna().quantile(.9))),
        med_full_steps=med(s.inp_pbp_nbeq), med_cone_steps=med(s.grim_pbp_cone)))
json.dump({"rows": rows, "meta": [{"label": "Input", "value": os.path.basename(src)}, {"label": "lad_summary.py", "value": open(__file__).read(), "type": "code", "lang": "python"}]},
          open(f"{out}/families.json", "w"), indent=1)
# construct composition, smol-VERIFIED rows only, full certificate vs cone
v = d[d.veri_smol_status.eq("VERIFIED")].copy()
lad = [c[len("grim_full_"):] for c in v.columns if c.startswith("grim_full_lad")]
opb = ["al1", "am1", "inj", "g0adj"]
crow = []
for fname in sorted(v.fam.unique()) + ["ALL"]:
    s = v if fname == "ALL" else v[v.fam == fname]
    tf = sum(num(s[f"grim_full_{t}"]).fillna(0).sum() for t in opb + lad); tc = sum(num(s[f"grim_cone_{t}"]).fillna(0).sum() for t in opb + lad)
    for t in opb + lad:
        fu = float(num(s[f"grim_full_{t}"]).fillna(0).sum()); co = float(num(s[f"grim_cone_{t}"]).fillna(0).sum())
        if fu == 0 and co == 0: continue
        crow.append(dict(family=fname, construct=t, side="model" if t in opb else "derived", n=int(len(s)), full=int(fu), cone=int(co),
                         full_share=fu/max(tf,1), cone_share=co/max(tc,1), kept=(co/fu if fu else None)))
    uf = float(num(s.get("grim_full_unlabeled", 0)).fillna(0).sum()) if "grim_full_unlabeled" in s else 0
    uc = float(num(s.get("grim_cone_unlabeled", 0)).fillna(0).sum()) if "grim_cone_unlabeled" in s else 0
    if uf or uc: crow.append(dict(family=fname, construct="unlabeled", side="derived", n=int(len(s)), full=int(uf), cone=int(uc), full_share=uf/max(tf,1), cone_share=uc/max(tc,1), kept=(uc/uf if uf else None)))
json.dump({"rows": crow, "meta": [{"label": "Input", "value": os.path.basename(src)}, {"label": "Filter", "value": "base instances with veri_smol_status == VERIFIED"}]},
          open(f"{out}/composition.json", "w"), indent=1)
print("families", len(rows), "composition", len(crow)); print(open(f"{out}/values.txt").read()[:3000])
