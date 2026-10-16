#!/usr/bin/env python3
"""cake_pb vs veripb: where is the CakeML checker significantly slower, and why.

Reads the appendix-grid CSVs in runs-0903/<config>/cluster_results.csv.
Every number quoted in the accompanying analysis is produced here.

Timing semantics (src/output.jl:certify):
  veri_*_time  = `veripb -e <elab> <opb> <pbp>`  — checks AND writes the elaboration
  cake_*_time  = `cake_pb <opb> <elab>`          — checks the already-elaborated proof
Both are logged as trunc(Int, t), i.e. whole seconds, so ratios are only read on
rows where the veripb side is >= 10 s.
"""
import sys, numpy as np, pandas as pd
pd.set_option("display.width", 250); pd.set_option("display.max_columns", 80)
BASE = sys.argv[1] if len(sys.argv) > 1 else "/home/arthur_gla/trimnalyser/runs-0903/"

GSS = ["sep01-gss-lazy", "sep01-gss-lazy-base", "sep01-gss-proof",
       "sep01-gss-lazy-base-nds", "sep01-gss-proof-nds", "gss-lazy-cliques",
       "gss-lazy-norestarts", "gss-lazy-nostaged", "gss-lazy-nosupp"]
LAD = ["lad-fc-pl", "lad-alldiff-pl"]

def sp(a, b):                      # spearman without scipy
    m = a.notna() & b.notna()
    return a[m].rank().corr(b[m].rank()) if m.sum() >= 10 else float("nan")

def load(cfg):
    return pd.read_csv(f"{BASE}{cfg}/cluster_results.csv", low_memory=False)

def prep(d, tag):
    """tag='full' (<ins>.opb/.pbp) or 'smol' (the trimmed pair). Unified column names."""
    if tag == "full":
        m = dict(vstat="veri_full_status", cstat="cake_full_status", vtime="veri_total_time",
                 ctime="cake_full_time", elab="cake_elab_size", pbp="inp_pbp_size",
                 opb="inp_opb_size"); pre = "grim_full_"
    else:
        m = dict(vstat="veri_smol_status", cstat="cake_smol_status", vtime="veri_smol_time",
                 ctime="cake_smol_time", elab="cake_smol_elab_size", pbp="grim_pbp_size",
                 opb="grim_opb_size"); pre = "grim_cone_"
    x = d.copy()
    for k, v in m.items(): x[k] = x[v]
    for k in ("rup", "pol", "red", "ia"): x[k] = x[pre + k]
    x["steps"] = x[["rup", "pol", "red", "ia"]].sum(axis=1)
    x.loc[x[["rup", "pol", "red", "ia"]].isna().all(axis=1), "steps"] = np.nan
    s = x.steps.replace(0, np.nan)
    for k in ("rup", "pol", "ia"): x[k + "f"] = x[k] / s
    x["ratio"] = x.ctime / x.vtime.replace(0, np.nan)
    x["delta"] = x.ctime - x.vtime
    x["exp"]   = x.elab / x.pbp.replace(0, np.nan)     # elaboration blow-up
    return x

def logslope(df, xc, yc):
    m = df[xc].notna() & df[yc].notna() & (df[xc] > 0) & (df[yc] > 0)
    X = np.column_stack([np.ones(m.sum()), np.log(df.loc[m, xc].values)])
    y = np.log(df.loc[m, yc].values)
    b, *_ = np.linalg.lstsq(X, y, rcond=None)
    return b[1], 1 - ((y - X @ b) ** 2).sum() / ((y - y.mean()) ** 2).sum(), m.sum()

# ---------------------------------------------------------------- 1. headline
print("== 1. cake_pb vs veripb, full proofs, per configuration =========================")
print(f"{'config':24s} {'verif':>6s} {'cakeOK':>6s} {'MEMOUT':>6s} {'T/O':>5s} "
      f"{'veripb h':>9s} {'cake h':>9s} {'agg x':>6s} {'med x':>6s}")
for cfg in GSS + LAD:
    x = prep(load(cfg), "full"); v = x[x.vstat == "VERIFIED"]
    b = v[v.cstat == "VERIFIED"]; q = b[b.vtime >= 10]
    c = v.cstat.value_counts()
    print(f"{cfg:24s} {len(v):6d} {len(b):6d} {c.get('MEMOUT',0):6d} {c.get('TIMEOUT',0):5d} "
          f"{b.vtime.sum()/3600:9.1f} {b.ctime.sum()/3600:9.1f} "
          f"{b.ctime.sum()/max(b.vtime.sum(),1):6.2f} {q.ratio.median():6.2f}")

# ------------------------------------------- 2. what each checker charges for
print("\n== 2. per-MB rates, measured where one term dominates ==========================")
print("   formula-bound = elab < 20 MB and OPB > 50 MB ; proof-bound = OPB < 20 MB and elab > 200 MB")
print(f"{'config':24s} {'n_fb':>5s} {'v s/MB_opb':>10s} {'c s/MB_opb':>10s} {'x':>5s} | "
      f"{'n_pb':>5s} {'v s/MB_pf':>9s} {'c s/MB_pf':>9s} {'x':>6s}")
for cfg in GSS + LAD:
    x = prep(load(cfg), "full")
    b = x[(x.vstat == "VERIFIED") & (x.cstat == "VERIFIED") & x.opb.notna() & x.elab.notna()]
    fb, pb = b[(b.elab < 2e7) & (b.opb > 5e7)], b[(b.elab > 2e8) & (b.opb < 2e7)]
    r = lambda df, t, sz: (df[t] / (df[sz] / 1e6)).median() if len(df) > 20 else float("nan")
    vo, co, vp, cp = r(fb,"vtime","opb"), r(fb,"ctime","opb"), r(pb,"vtime","elab"), r(pb,"ctime","elab")
    print(f"{cfg:24s} {len(fb):5d} {vo:10.3f} {co:10.3f} {co/vo:5.1f} | "
          f"{len(pb):5d} {vp:9.3f} {cp:9.3f} {cp/vp:6.2f}")

# --------------------------------------------------- 3. the two outlier walls
print("\n== 3. the walls (sep01-gss-lazy) ===============================================")
x = prep(load("sep01-gss-lazy"), "full"); v = x[x.vstat == "VERIFIED"]
ok, mo, to = (v[v.cstat == s] for s in ("VERIFIED", "MEMOUT", "TIMEOUT"))
print(f"  cake VERIFIED: max OPB {ok.opb.max()/1e6:.1f} MB      n={len(ok)}")
print(f"  cake MEMOUT  : min OPB {mo.opb.min()/1e6:.1f} MB      n={len(mo)}"
      f"   ({(mo.opb>4.5e8).sum()} of them OPB>450MB, {(mo.opb<=4.5e8).sum()} are multi-GB elaborations)")
print(f"  cake TIMEOUT : median elab {to.elab.median()/1e9:.2f} GB, median OPB {to.opb.median()/1e6:.0f} MB  n={len(to)}")
fb = v[(v.elab < 2e7) & (v.opb > 1e7)]
bins = pd.cut(fb.opb, [1e7,3e7,1e8,2e8,3e8,4e8,1e10],
              labels=["10-30MB","30-100MB","100-200MB","200-300MB","300-400MB",">400MB"])
print("\n  small proof (<20 MB elab), by OPB size:")
print(fb.groupby(bins, observed=True).apply(lambda g: pd.Series({
    "n": len(g), "cake_memout_%": 100*(g.cstat=="MEMOUT").mean(),
    "med_veripb_s": g.vtime.median(), "med_cake_s": g.ctime.median(),
    "cake_s_per_MB_opb": (g.ctime/(g.opb/1e6)).median(),
    "med_ratio": g[g.cstat=="VERIFIED"].ratio.median()}), include_groups=False).round(2).to_string())

# --------------------------------------------------- 4. rup-heavy vs pol-heavy
print("\n== 4. rule mix ==================================================================")
for cfg in ["sep01-gss-lazy", "gss-lazy-cliques", "gss-lazy-nosupp", "lad-fc-pl", "lad-alldiff-pl"]:
    x = prep(load(cfg), "full"); b = x[(x.vstat == "VERIFIED") & (x.steps > 0)]
    t = b[["rup","pol","red","ia"]].sum(); t = t / t.sum()
    o = b[(b.cstat == "VERIFIED") & (b.vtime >= 10)]
    print(f"  {cfg:20s} n={len(b):6d}  mix rup {t.rup:.3f} pol {t.pol:.3f} ia {t.ia:.3f} | "
          f"elab/pbp {b.exp.median():5.2f} | rho(ratio,rupf) {sp(o.ratio,o.rupf):+.3f} "
          f"rho(ratio,polf) {sp(o.ratio,o.polf):+.3f} rho(ratio,opb) {sp(o.ratio,o.opb):+.3f} "
          f"rho(ratio,elab) {sp(o.ratio,o.elab):+.3f}")
print("\n  sep01-gss-lazy, size-controlled (both VERIFIED, veripb>=10s, step data present):")
x = prep(load("sep01-gss-lazy"), "full")
b = x[(x.vstat=="VERIFIED") & (x.cstat=="VERIFIED") & (x.vtime>=10) & (x.steps>0)].copy()
b["szb"]  = pd.cut(b.elab, [0,1e7,1e8,1e9,1e12], labels=["<10MB","10-100MB","0.1-1GB",">1GB"])
b["rupb"] = pd.cut(b.rupf, [-1e-9,1e-3,1e-2,1e-1,1.01], labels=["~0","0.1-1%","1-10%",">10%"])
print("   median cake/veripb ratio, elaboration size x rup fraction")
print(b.pivot_table(index="szb", columns="rupb", values="ratio", aggfunc="median", observed=True).round(2).to_string())
print("   counts")
print(b.pivot_table(index="szb", columns="rupb", values="ratio", aggfunc="size", observed=True).to_string())
print("   median elaboration blow-up elab/pbp")
print(b.pivot_table(index="szb", columns="rupb", values="exp", aggfunc="median", observed=True).round(2).to_string())

# -------------------------------------------------- 5. scaling in proof bytes
print("\n== 5. scaling exponent in elaboration size (proof-bound rows, time>=5 s) =======")
for cfg in ["sep01-gss-lazy", "gss-lazy-nosupp", "lad-fc-pl", "lad-alldiff-pl"]:
    x = prep(load(cfg), "full")
    b = x[(x.vstat=="VERIFIED") & (x.cstat=="VERIFIED") & (x.opb<2e7) & (x.elab>1e7)]
    for who, tc in (("veripb", "vtime"), ("cake  ", "ctime")):
        s, r2, n = logslope(b[b[tc] >= 5], "elab", tc)
        print(f"  {cfg:18s} {who}  exponent {s:5.2f}  R2 {r2:.2f}  n={n}")

# ------------------------------------------------------- 6. trimming's effect
print("\n== 6. what trimming does to each checker (all four checks VERIFIED) ============")
for cfg in ["sep01-gss-lazy", "lad-fc-pl", "lad-alldiff-pl"]:
    d = load(cfg)
    F = prep(d, "full").set_index("instance"); S = prep(d, "smol").set_index("instance")
    j = F[["vstat","cstat","vtime","ctime","elab","opb"]].join(
        S[["vstat","cstat","vtime","ctime","elab","opb"]], lsuffix="_f", rsuffix="_s", how="inner")
    q = j[(j.vstat_f=="VERIFIED")&(j.cstat_f=="VERIFIED")&(j.vstat_s=="VERIFIED")&(j.cstat_s=="VERIFIED")]
    print(f"  {cfg:16s} n={len(q):6d}  veripb {q.vtime_f.sum()/3600:7.1f} h -> {q.vtime_s.sum()/3600:6.2f} h "
          f"(/{q.vtime_f.sum()/max(q.vtime_s.sum(),1):5.0f})   cake {q.ctime_f.sum()/3600:7.1f} h -> "
          f"{q.ctime_s.sum()/3600:6.2f} h (/{q.ctime_f.sum()/max(q.ctime_s.sum(),1):5.0f})   "
          f"cake/veripb {q.ctime_f.sum()/max(q.vtime_f.sum(),1):6.2f}x -> {q.ctime_s.sum()/max(q.vtime_s.sum(),1):.2f}x")

# ------------------------------------------------------------ 7. outlier dump
print("\n== 7. outliers (sep01-gss-lazy, full proofs) ===================================")
v = prep(load("sep01-gss-lazy"), "full")
v = v[v.vstat == "VERIFIED"].copy()
thr = v[(v.cstat=="VERIFIED") & (v.vtime>=10)].ratio.quantile(.95)
v["class"] = np.where(v.cstat.isin(["MEMOUT","TIMEOUT"]), "A_cake_gave_up",
             np.where((v.cstat=="VERIFIED") & (v.vtime>=10) & (v.ratio>=thr), "B_ratio_p95",
             np.where((v.cstat=="VERIFIED") & (v.delta>=1000), "C_1000s_lost", "")))
cols = ["instance","family","class","cstat","vtime","ctime","ratio","delta","opb","elab",
        "pbp","steps","rup","pol","ia","rupf","polf","exp"]
out = v[v["class"]!=""][cols].sort_values(["class","ratio"], ascending=[True,False])
out.to_csv("cake_outliers_gss-lazy.csv", index=False)
print(f"  p95 ratio threshold = {thr:.2f}; wrote cake_outliers_gss-lazy.csv ({len(out)} rows)")
print("  ", out["class"].value_counts().to_dict())
print("\n  worst 12 by ratio:")
print(out[out["class"]=="B_ratio_p95"].nlargest(12,"ratio")[
      ["instance","family","vtime","ctime","ratio","opb","elab","steps","rupf","exp"]].to_string(index=False))
