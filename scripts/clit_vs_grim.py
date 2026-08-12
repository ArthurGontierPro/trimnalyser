#!/usr/bin/env python3
"""Paired Grim-vs-Clit comparison for the clit A/B (scripts/ab_clit.sh).

Both modes trim the same parsed proof in the same process, so grim_* and gclt_*
columns of one cluster_results.csv are paired per instance — no cross-run join,
no machine-load confound. Stdlib only.

    python3 scripts/clit_vs_grim.py ab-clit/cluster_results.csv \
        --baseline ab-ruptrail/cluster_results.csv
"""
import argparse
import csv
import sys

# (label, grim column, clit column, "lower is better"?)
PAIRS = [
    ("total cone (steps)", "grim_total_cone",     "gclt_total_cone",     True),
    ("opb cone",           "grim_opb_cone",       "gclt_opb_cone",       True),
    ("pbp cone",           "grim_pbp_cone",       "gclt_pbp_cone",       True),
    ("cone literals",      "grim_cone_literals",  "gclt_cone_literals",  True),
    ("smol literals",      "grim_smol_literals",  "gclt_smol_literals",  True),
    ("cone variables",     "grim_cone_variables", "gclt_cone_variables", True),
    ("trim time (s)",      "grim_trim_time",      "gclt_trim_time",      True),
]


def num(row, col):
    v = (row.get(col) or "").strip()
    if v in ("", "-1", "NA"):
        return None
    try:
        f = float(v)
    except ValueError:
        return None
    return f if f > 0 else None


def median(xs):
    if not xs:
        return float("nan")
    xs = sorted(xs)
    n = len(xs)
    return xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv")
    ap.add_argument("--baseline", help="CSV whose veri_smol_verified describes Grim")
    ap.add_argument("--clit-from", metavar="CSV",
                    help="take gclt_*/veri_* from an ARM=clit-only run (which gave Clit a "
                         "full tt to itself) and pair them against this CSV's grim_* columns")
    args = ap.parse_args()

    with open(args.csv, newline="") as f:
        rows = list(csv.DictReader(f))
    if not rows:
        sys.exit("empty CSV")
    print(f"rows: {len(rows)}  ({args.csv})\n")

    # In ARM=both the two passes share one tt and Grim goes first, so Clit is the only one
    # that ever gets truncated. An ARM=clit-only run gives Clit its own full budget; overlay
    # its gclt_* here so both sides of the comparison had the same time. veri_* comes with
    # it, since in that run the verified .smol.* is Clit's.
    if args.clit_from:
        with open(args.clit_from, newline="") as f:
            other = {r["instance"]: r for r in csv.DictReader(f)}
        overlaid = 0
        for r in rows:
            o = other.get(r["instance"])
            if not o:
                continue
            if num(o, "gclt_total_cone") is None:
                continue
            for k, v in o.items():
                if k.startswith("gclt_") or k.startswith("veri_"):
                    r[k] = v
            overlaid += 1
        print(f"overlaid gclt_* from {args.clit_from} on {overlaid} instances "
              f"(Clit given its own full tt)\n")

    if all(num(r, "gclt_total_cone") is None for r in rows):
        sys.exit("no gclt_* data — was the run launched with the `clit` flag?")

    # tt bounds the whole subprocess (both passes). Where the Grim pass spent the budget,
    # `timeout` killed the process before Clit finished and gclt_* is empty. Those rows are
    # NOT evidence that the two modes agree — they are missing data, and they are
    # concentrated on the slowest instances. Report them instead of silently dropping them.
    trunc = [r for r in rows
             if num(r, "grim_total_cone") is not None and num(r, "gclt_total_cone") is None]
    if trunc:
        slowest = sorted(trunc, key=lambda r: -(num(r, "grim_total_time") or 0))[:5]
        print(f"clit pass did not complete on {len(trunc)}/{len(rows)} rows "
              f"({100*len(trunc)/len(rows):.1f}%) — excluded from every table below")
        print("  slowest: " + ", ".join(
            f"{r['instance']}({num(r,'grim_total_time') or 0:.0f}s grim)" for r in slowest) + "\n")

    w = max(len(p[0]) for p in PAIRS)
    print(f"{'metric':<{w}}  {'n':>5}  {'clit<grim':>9}  {'equal':>6}  "
          f"{'clit>grim':>9}  {'median c/g':>10}  {'sum ratio':>9}")
    print("-" * (w + 58))
    for label, gcol, ccol, _lower_better in PAIRS:
        ratios, better, equal, worse = [], 0, 0, 0
        sg = sc = 0.0
        for r in rows:
            g, c = num(r, gcol), num(r, ccol)
            if g is None or c is None:
                continue
            ratios.append(c / g)
            sg += g
            sc += c
            if c < g:
                better += 1
            elif c > g:
                worse += 1
            else:
                equal += 1
        n = len(ratios)
        if not n:
            print(f"{label:<{w}}  {'-':>5}  (no paired rows)")
            continue
        print(f"{label:<{w}}  {n:>5}  {better:>9}  {equal:>6}  {worse:>9}  "
              f"{median(ratios):>10.4f}  {sc/sg if sg else float('nan'):>9.4f}")

    # Any instance where the cone actually changed is the whole story: if this is 0,
    # Clit is a no-op and the mode is not worth its place in the heuristic chain.
    changed = [r["instance"] for r in rows
               if num(r, "grim_total_cone") is not None
               and num(r, "gclt_total_cone") is not None
               and num(r, "grim_total_cone") != num(r, "gclt_total_cone")]
    print(f"\ninstances where the cone differs at all: {len(changed)}")
    for i in changed[:20]:
        print(f"  {i}")
    if len(changed) > 20:
        print(f"  ... and {len(changed)-20} more")

    # Verif: in batch mode Clit writes .smol.* last, so veri_smol_verified in THIS csv
    # describes Clit's proof. Grim's baseline comes from the earlier run.
    def verified(r):
        return (r.get("veri_smol_verified") or "").strip().lower() in ("1", "true", "yes", "verified")

    # Only rows where Clit actually ran describe Clit's proof. On a truncated row the
    # .smol.* verify() saw was Grim's own output from earlier in the same subprocess, so
    # counting it here would credit Clit with a verification it never earned.
    ran = [r for r in rows if num(r, "gclt_total_cone") is not None]
    ok = sum(1 for r in ran if verified(r))
    print(f"\nveripb on Clit's trimmed proof: {ok} verified / {len(ran)} rows where Clit ran")
    if args.baseline:
        with open(args.baseline, newline="") as f:
            base = {r["instance"]: r for r in csv.DictReader(f)}
        regressions = [r["instance"] for r in ran
                       if r["instance"] in base
                       and verified(base[r["instance"]]) and not verified(r)]
        common = sum(1 for r in ran if r["instance"] in base)
        print(f"baseline join: {common} common instances ({args.baseline})")
        print(f"verified under Grim but NOT under Clit: {len(regressions)}")
        for i in regressions[:20]:
            print(f"  {i}")
        if len(regressions) > 20:
            print(f"  ... and {len(regressions)-20} more")
        if regressions:
            print("\n  ^ these are the only rows worth debugging: Grim verified, Clit did not.")


if __name__ == "__main__":
    main()
