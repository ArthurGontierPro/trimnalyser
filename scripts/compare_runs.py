#!/usr/bin/env python3
"""Compare two TrimAnalyser full runs instance by instance.

    python3 scripts/compare_runs.py 6-29-fullrun 8-3-fullrun
    python3 scripts/compare_runs.py 6-29-fullrun 8-3-fullrun -o comparaison-6-29-vs-8-3.html --csv

Each argument is either a run directory containing `cluster_results.csv` or the CSV
itself. The label of a run is taken from the directory name (`8-3-fullrun` -> `8-3`).

Produces a self-contained HTML report:
  * coverage: which instances each run attempted at all,
  * an outcome transition matrix on the instances common to both runs
    (how many timeouts / OOMs are now trimmed, and how many regressed),
  * paired size / time / cone deltas on instances trimmed by both runs,
  * per-family breakdown, cone composition, and the biggest individual movers.

Only pandas + numpy are required; the charts are hand-rolled inline SVG so the
HTML has no external dependency.
"""

import argparse
import html
import math
import os
import re
import sys
from datetime import datetime

import numpy as np
import pandas as pd

# ── outcome taxonomy ──────────────────────────────────────────────────────────
# Order matters: the first matching rule wins, successes before failures.
OUTCOMES = [
    ("sat",            "SAT (no proof to trim)"),
    ("verified",       "trimmed + verified"),
    ("trimmed",        "trimmed, not verified"),
    ("truncated",      "truncated proof (solver OOM)"),
    ("oom",            "OOM"),
    ("trim_timeout",   "trim timeout"),
    ("no_proof",       "UNSAT, no proof"),
    ("not_solved",     "not solved (solver-timeout sentinel)"),
    ("other_error",    "other error"),
]
OUTCOME_LABEL = dict(OUTCOMES)
OUTCOME_ORDER = [k for k, _ in OUTCOMES]
# Outcomes counted as "a trimmed proof was produced".
GOOD = {"verified", "trimmed"}
# Rank used to decide whether a transition is progress or a regression.
RANK = {"verified": 4, "trimmed": 3, "sat": 2, "truncated": 1, "oom": 1,
        "trim_timeout": 1, "no_proof": 1, "not_solved": 0, "other_error": 1}

CORE_RE = re.compile(r"\.core\d+$")


# ── loading ───────────────────────────────────────────────────────────────────
def col(df, name):
    """A column, or an all-NaN column of the right length when an older run lacks it."""
    if name in df.columns:
        return df[name]
    return pd.Series(np.nan, index=df.index, name=name)


def truthy(s):
    """Coerce a Julia-written boolean column (bool / 'true' / NaN) to a bool Series."""
    if s.dtype == bool:
        return s
    return s.map(lambda v: v is True or str(v).strip().lower() == "true").astype(bool)


def classify(df):
    is_sat = truthy(col(df, "is_sat")) | col(df, "skip_reason").eq("SAT")
    verified = col(df, "veri_smol_verified").eq(1)
    trimmed = col(df, "grim_total_cone").notna() | col(df, "grim_total_time").notna()
    truncated = truthy(col(df, "proof_truncated")) | col(df, "skip_reason").fillna("").astype(str).str.startswith("truncated")
    oom = col(df, "error_type").eq("OOM")
    ttimeout = col(df, "error_type").eq("Timeout")
    noproof = col(df, "skip_reason").eq("no_proof_generated")
    haserr = truthy(col(df, "has_error"))
    notrun = col(df, "status").isna() & ~haserr & ~trimmed & ~is_sat

    # lowest priority first, so higher-priority rules overwrite
    out = pd.Series("other_error", index=df.index, dtype=object)
    for name, mask in [("other_error", haserr), ("not_solved", notrun), ("no_proof", noproof),
                       ("trim_timeout", ttimeout), ("oom", oom), ("truncated", truncated),
                       ("trimmed", trimmed), ("verified", verified), ("sat", is_sat)]:
        out[mask.fillna(False)] = name
    return out


def read_meta(run_dir):
    """Pull `| key | value |` rows and the exact command out of a run's README.md.

    Purely opportunistic: a run without a README simply reports nothing, and the
    report says so rather than inventing provenance.
    """
    meta, cmd = {}, None
    path = os.path.join(run_dir, "README.md") if os.path.isdir(run_dir) else ""
    if not path or not os.path.isfile(path):
        return meta, cmd
    txt = open(path).read()
    m = re.search(r"```(?:bash|sh)?\n(.*?)\n```", txt, re.S)
    if m:
        cmd = m.group(1).strip()
    for k, v in re.findall(r"^\|\s*([^|\n]+?)\s*\|\s*([^|\n]*?)\s*\|\s*$", txt, re.M):
        k = k.replace("`", "").replace("**", "").strip()
        v = v.replace("`", "").replace("**", "").strip()
        if not k or not v or set(k) <= set("-: "):
            continue
        if k.lower() in ("count", "share", "file", "instance") or re.search(r"\.\w{2,4}$", k):
            continue                       # a file-listing row, not a run parameter
        meta.setdefault(k, v)
    return meta, cmd


def load_run(path):
    """Return (label, base_dataframe, core_dataframe, metadata, command)."""
    if os.path.isdir(path):
        csv = os.path.join(path, "cluster_results.csv")
        label = os.path.basename(os.path.normpath(path))
        run_dir = path
    else:
        csv = path
        run_dir = os.path.dirname(os.path.abspath(path))
        label = os.path.basename(run_dir)
    if not os.path.isfile(csv):
        sys.exit(f"no cluster_results.csv at {csv}")
    label = re.sub(r"[-_]?fullrun$", "", label) or label
    df = pd.read_csv(csv, low_memory=False)
    df["instance"] = df["instance"].astype(str)
    is_core = df["instance"].str.contains(CORE_RE)
    base = df[~is_core].copy()
    base["outcome"] = classify(base)
    base = base.drop_duplicates(subset="instance", keep="first").set_index("instance")
    meta, cmd = read_meta(run_dir)
    return label, base, df[is_core].copy(), meta, cmd


# ── formatting ────────────────────────────────────────────────────────────────
def fnum(x, dec=0):
    if x is None or (isinstance(x, float) and not np.isfinite(x)):
        return "—"
    return f"{x:,.{dec}f}".replace(",", " ")


def fbytes(x):
    if x is None or not np.isfinite(x):
        return "—"
    for unit, div in (("TB", 1024 ** 4), ("GB", 1024 ** 3), ("MB", 1024 ** 2), ("KB", 1024)):
        if abs(x) >= div:
            return f"{x / div:,.2f} {unit}".replace(",", " ")
    return f"{x:.0f} B"


def ftime(x):
    if x is None or not np.isfinite(x):
        return "—"
    if x >= 3600:
        return f"{x / 3600:.2f} h"
    if x >= 60:
        return f"{x / 60:.1f} min"
    return f"{x:.2f} s"


def pct(x, dec=1):
    return "—" if x is None or not np.isfinite(x) else f"{x * 100:.{dec}f} %"


def sgn(x):
    """Signed integer with thin-space grouping ('+1 308')."""
    return f"{x:+,}".replace(",", "\u202f")


def delta_cell(new, old, better="lower", fmt=fnum, rel=True):
    """A '+12.3 %' cell coloured (and signed) by whether the change is an improvement."""
    if old is None or new is None or not np.isfinite(old) or not np.isfinite(new) or old == 0:
        return '<td class="num">—</td>'
    d = (new - old) / abs(old)
    good = (d < 0) if better == "lower" else (d > 0)
    if abs(d) < 0.005:
        cls, arrow = "flat", "="
    else:
        cls, arrow = ("up" if good else "down"), ("▼" if d < 0 else "▲")
    txt = f"{arrow} {d * 100:+.1f} %" if rel else f"{arrow} {fmt(new - old)}"
    return f'<td class="num {cls}">{txt}</td>'


# ── tiny SVG chart helpers ────────────────────────────────────────────────────
def svg_grouped_bars(rows, la, lb, width=760, rowh=34, pad_left=210, fmt=fnum, vmax=None):
    """rows = [(category, value_a, value_b)] -> horizontal grouped bar chart."""
    vmax = vmax if vmax is not None else max([max(a, b) for _, a, b in rows] + [1])
    h = len(rows) * rowh + 46
    inner = width - pad_left - 96
    bar = 11
    out = [f'<svg class="chart" viewBox="0 0 {width} {h}" role="img" '
           f'aria-label="{html.escape(la)} vs {html.escape(lb)}">']
    for i in range(5):
        x = pad_left + inner * i / 4
        out.append(f'<line class="grid" x1="{x:.1f}" y1="26" x2="{x:.1f}" y2="{h - 20}"/>')
        out.append(f'<text class="tick" x="{x:.1f}" y="{h - 6}" text-anchor="middle">'
                   f'{fmt(vmax * i / 4)}</text>')
    out.append(f'<g class="legend"><rect x="{pad_left}" y="6" width="10" height="10" rx="2" fill="var(--series-1)"/>'
               f'<text x="{pad_left + 16}" y="15">{html.escape(la)}</text>'
               f'<rect x="{pad_left + 90}" y="6" width="10" height="10" rx="2" fill="var(--series-2)"/>'
               f'<text x="{pad_left + 106}" y="15">{html.escape(lb)}</text></g>')
    for i, (cat, a, b) in enumerate(rows):
        y = 30 + i * rowh
        out.append(f'<text class="cat" x="{pad_left - 10}" y="{y + 15}" text-anchor="end">{html.escape(cat)}</text>')
        for j, (v, fill) in enumerate(((a, "var(--series-1)"), (b, "var(--series-2)"))):
            w = inner * v / vmax
            yy = y + j * (bar + 2)
            out.append(f'<rect x="{pad_left}" y="{yy}" width="{max(w, 0.6):.1f}" height="{bar}" rx="3" fill="{fill}">'
                       f'<title>{html.escape(cat)} — {html.escape(la if j == 0 else lb)}: {fmt(v)}</title></rect>')
            out.append(f'<text class="val" x="{pad_left + w + 6:.1f}" y="{yy + bar - 1.5}">{fmt(v)}</text>')
    out.append("</svg>")
    return "\n".join(out)


def svg_hist(values, title, la="A", lb="B", width=380, height=210, bins=25, clip=4.0):
    """Histogram of a log2 ratio; blue = run B smaller, red = run B bigger."""
    v = np.clip(np.asarray(values, dtype=float), -clip, clip)
    if v.size == 0:
        return '<p class="muted">no paired data</p>'
    counts, edges = np.histogram(v, bins=bins, range=(-clip, clip))
    cmax = max(counts.max(), 1)
    pl, pr, pt, pb = 34, 8, 22, 30
    iw, ih = width - pl - pr, height - pt - pb
    out = [f'<svg class="chart" viewBox="0 0 {width} {height}" role="img" aria-label="{html.escape(title)}">']
    out.append(f'<text class="cat" x="{pl}" y="12">{html.escape(title)}</text>')
    for i, c in enumerate(counts):
        x = pl + iw * i / bins
        w = iw / bins
        hh = ih * c / cmax
        mid = (edges[i] + edges[i + 1]) / 2
        fill = "var(--pos)" if mid < 0 else ("var(--neg)" if mid > 0 else "var(--mid)")
        out.append(f'<rect x="{x + 0.8:.1f}" y="{pt + ih - hh:.1f}" width="{w - 1.6:.1f}" '
                   f'height="{hh:.1f}" rx="2" fill="{fill}">'
                   f'<title>2^[{edges[i]:.2f}, {edges[i+1]:.2f}] × : {c} instances</title></rect>')
    x0 = pl + iw / 2
    out.append(f'<line class="zero" x1="{x0}" y1="{pt}" x2="{x0}" y2="{pt + ih}"/>')
    med = float(np.median(v))
    xm = pl + iw * (med + clip) / (2 * clip)
    out.append(f'<line class="med" x1="{xm:.1f}" y1="{pt}" x2="{xm:.1f}" y2="{pt + ih}"/>')
    out.append(f'<text class="tick" x="{width - pr}" y="{pt - 5}" text-anchor="end">'
               f'médiane ×{2 ** med:.2f}</text>')
    for frac, lab in ((0, f"÷{2 ** clip:.0f}"), (0.5, "1×"), (1, f"×{2 ** clip:.0f}")):
        out.append(f'<text class="tick" x="{pl + iw * frac:.1f}" y="{height - 14}" '
                   f'text-anchor="middle">{lab}</text>')
    out.append(f'<text class="tick" x="{pl + iw / 2}" y="{height - 2}" text-anchor="middle">'
               f'← plus petit en {html.escape(lb)} · plus grand en {html.escape(lb)} →</text>')
    out.append(f'<text class="tick" x="{pl - 6}" y="{pt + 8}" text-anchor="end">{fnum(cmax)}</text>')
    out.append("</svg>")
    return "\n".join(out)


def svg_cactus(series, la, lb, xlabel, ylabel, width=760, height=330):
    """Cumulative 'solved within t' curves on a log-x axis. series = [(label, sorted_times)]."""
    allv = np.concatenate([s for _, s in series if len(s)]) if series else np.array([])
    allv = allv[np.isfinite(allv) & (allv > 0)]
    if allv.size == 0:
        return '<p class="muted">pas de données</p>'
    lo, hi = max(allv.min(), 1e-3), allv.max()
    lo10, hi10 = math.floor(math.log10(lo)), math.ceil(math.log10(hi))
    ymax = max(len(s) for _, s in series)
    pl, pr, pt, pb = 62, 14, 26, 44
    iw, ih = width - pl - pr, height - pt - pb

    def X(v):
        return pl + iw * (math.log10(max(v, lo)) - lo10) / max(hi10 - lo10, 1e-9)

    def Y(n):
        return pt + ih - ih * n / ymax

    out = [f'<svg class="chart" viewBox="0 0 {width} {height}" role="img" '
           f'aria-label="{html.escape(ylabel)}">']
    for d in range(int(lo10), int(hi10) + 1):
        x = X(10 ** d)
        lab = f"{10 ** d:g}" if d >= 0 else f"{10 ** d:g}"
        out.append(f'<line class="grid" x1="{x:.1f}" y1="{pt}" x2="{x:.1f}" y2="{pt + ih}"/>')
        out.append(f'<text class="tick" x="{x:.1f}" y="{pt + ih + 15}" text-anchor="middle">{lab}</text>')
    for i in range(5):
        n = ymax * i / 4
        y = Y(n)
        out.append(f'<line class="grid" x1="{pl}" y1="{y:.1f}" x2="{pl + iw}" y2="{y:.1f}"/>')
        out.append(f'<text class="tick" x="{pl - 8}" y="{y + 3.5:.1f}" text-anchor="end">{fnum(n)}</text>')
    for k, (lab, vals) in enumerate(series):
        v = np.sort(np.asarray(vals, dtype=float))
        v = v[np.isfinite(v)]
        v = np.clip(v, lo, None)
        if v.size == 0:
            continue
        step = max(1, v.size // 900)          # cap the path length; the curve is monotone
        pts = [f"{X(v[i]):.1f},{Y(i + 1):.1f}" for i in range(0, v.size, step)]
        pts.append(f"{X(v[-1]):.1f},{Y(v.size):.1f}")
        colr = "var(--series-1)" if k == 0 else "var(--series-2)"
        out.append(f'<polyline class="line" points="{" ".join(pts)}" stroke="{colr}"/>')
        out.append(f'<text class="val" x="{X(v[-1]) - 4:.1f}" y="{Y(v.size) - 6:.1f}" '
                   f'text-anchor="end">{fnum(v.size)}</text>')
    out.append(f'<g class="legend"><rect x="{pl}" y="4" width="10" height="10" rx="2" fill="var(--series-1)"/>'
               f'<text x="{pl + 16}" y="13">{html.escape(la)}</text>'
               f'<rect x="{pl + 90}" y="4" width="10" height="10" rx="2" fill="var(--series-2)"/>'
               f'<text x="{pl + 106}" y="13">{html.escape(lb)}</text></g>')
    out.append(f'<text class="tick" x="{pl + iw / 2}" y="{height - 6}" text-anchor="middle">'
               f'{html.escape(xlabel)}</text>')
    out.append(f'<text class="tick" x="{pl - 52}" y="{pt + ih / 2}" transform="rotate(-90 {pl - 52} '
               f'{pt + ih / 2})" text-anchor="middle">{html.escape(ylabel)}</text>')
    out.append("</svg>")
    return "\n".join(out)


def heat_table(mat, rows, cols, la, lb):
    """Transition matrix as a shaded HTML table (sequential blue on log scale)."""
    m = mat.values.astype(float)
    mx = m.max() if m.size else 1
    out = ['<table class="heat"><thead><tr><th class="corner">'
           f'{html.escape(la)} ╲ {html.escape(lb)}</th>']
    for c in cols:
        out.append(f'<th>{html.escape(OUTCOME_LABEL.get(c, c))}</th>')
    out.append('<th class="tot">total</th></tr></thead><tbody>')
    for r in rows:
        out.append(f'<th class="rowhead">{html.escape(OUTCOME_LABEL.get(r, r))}</th>'
                   if False else f'<tr><th class="rowhead">{html.escape(OUTCOME_LABEL.get(r, r))}</th>')
        for c in cols:
            v = int(mat.at[r, c])
            t = 0 if v == 0 else np.log1p(v) / np.log1p(mx)
            cls = "diag" if r == c else ""
            if v and r != c:
                cls = "prog" if RANK[c] > RANK[r] else ("reg" if RANK[c] < RANK[r] else "")
            if t > 0.6:
                cls += " ink"
            style = f' style="--t:{t:.3f}"' if v else ""
            out.append(f'<td class="hc {cls}"{style} title="{html.escape(OUTCOME_LABEL[r])} → '
                       f'{html.escape(OUTCOME_LABEL[c])}: {v}">{v or ""}</td>')
        out.append(f'<td class="tot">{int(mat.loc[r].sum())}</td></tr>')
    out.append('<tr><th class="rowhead">total</th>')
    for c in cols:
        out.append(f'<td class="tot">{int(mat[c].sum())}</td>')
    out.append(f'<td class="tot">{int(mat.values.sum())}</td></tr></tbody></table>')
    return "\n".join(out)


# ── statistics ────────────────────────────────────────────────────────────────
def _phi(z):
    """Standard normal CDF via math.erf — avoids a scipy dependency."""
    return 0.5 * (1.0 + math.erf(z / math.sqrt(2.0)))


def sign_test(a, b):
    """Two-sided paired sign test on b vs a. Returns (n_differing, k_b_smaller, p).

    Ties are dropped, as the sign test requires. n is in the thousands here, so the
    normal approximation to the binomial is more than adequate.
    """
    a = np.asarray(a, dtype=float)
    b = np.asarray(b, dtype=float)
    m = np.isfinite(a) & np.isfinite(b) & (a != b)
    n = int(m.sum())
    if n == 0:
        return 0, 0, np.nan
    k = int((b[m] < a[m]).sum())
    z = abs(k - n / 2) / (np.sqrt(n) / 2)
    return n, k, float(2 * (1 - _phi(z)))


def boot_ci_median(x, iters=1500, seed=0):
    """Percentile bootstrap 95 % CI for the median of x."""
    x = np.asarray(x, dtype=float)
    x = x[np.isfinite(x)]
    if x.size < 5:
        return (np.nan, np.nan)
    rng = np.random.default_rng(seed)
    idx = rng.integers(0, x.size, size=(iters, x.size))
    meds = np.median(x[idx], axis=1)
    return float(np.quantile(meds, 0.025)), float(np.quantile(meds, 0.975))


def fp(p):
    """Format a p-value for a table cell."""
    if p is None or not np.isfinite(p):
        return "—"
    if p < 1e-4:
        return "&lt; 10⁻⁴"
    if p < 0.05:
        return f"{p:.4f}"
    return f"{p:.3f}"


def paired_metric(A, B, name, label, better="lower", fmt=fnum, total=True):
    """Median / mean / total of column `name` over instances present in both frames."""
    a = pd.to_numeric(col(A, name), errors="coerce")
    b = pd.to_numeric(col(B, name), errors="coerce")
    m = a.notna() & b.notna()
    a, b = a[m], b[m]
    if len(a) == 0:
        return None
    ratio = np.where(a > 0, b / a.where(a > 0, np.nan), np.nan)
    ratio = ratio[np.isfinite(ratio)]
    wins = int((b < a).sum())
    losses = int((b > a).sum())
    same = int((b == a).sum())
    diff = ratio[ratio != 1.0]
    ndiff, kbetter, p = sign_test(a, b)
    lo, hi = boot_ci_median(diff)
    return dict(label=label, n=int(len(a)), med_a=float(a.median()), med_b=float(b.median()),
                mean_a=float(a.mean()), mean_b=float(b.mean()),
                sum_a=float(a.sum()) if total else None, sum_b=float(b.sum()) if total else None,
                med_ratio=float(np.median(ratio)) if ratio.size else np.nan,
                med_ratio_diff=float(np.median(diff)) if diff.size else np.nan,
                ci_lo=lo, ci_hi=hi, p=p, n_diff=ndiff, k_better=kbetter,
                same=same, same_frac=same / len(a),
                wins=wins, losses=losses, ties=int(len(a) - wins - losses),
                better=better, fmt=fmt)


def metric_rows(stats, compact=False):
    """Render metric dicts as <tr>s. compact=True drops the three total columns."""
    out = []
    for s in stats:
        if s is None:
            continue
        f = s["fmt"]
        if compact:
            tot = ""
        elif s["sum_a"] is not None:
            tot = (f'<td class="num">{f(s["sum_a"])}</td><td class="num">{f(s["sum_b"])}</td>'
                   + delta_cell(s["sum_b"], s["sum_a"], s["better"]))
        else:
            tot = '<td class="num">—</td><td class="num">—</td><td class="num">—</td>'
        better_txt = f'{s["wins"]:,} / {s["losses"]:,}'.replace(",", " ")
        out.append(
            f'<tr><td>{html.escape(s["label"])}</td><td class="num">{fnum(s["n"])}</td>'
            f'<td class="num">{f(s["med_a"])}</td><td class="num">{f(s["med_b"])}</td>'
            + delta_cell(s["med_b"], s["med_a"], s["better"]) +
            f'<td class="num">{f(s["mean_a"])}</td><td class="num">{f(s["mean_b"])}</td>'
            + tot +
            f'<td class="num">{pct(s["same_frac"])}</td>'
            f'<td class="num" title="IC 95 % bootstrap : '
            f'{"—" if not np.isfinite(s["ci_lo"]) else "%.3f – %.3f" % (s["ci_lo"], s["ci_hi"])}">'
            f'{"—" if not np.isfinite(s["med_ratio_diff"]) else "×%.3f" % s["med_ratio_diff"]}</td>'
            f'<td class="num">{better_txt}</td>'
            f'<td class="num" title="test des signes sur {fnum(s["n_diff"])} instances discordantes">'
            f'{fp(s["p"])}</td></tr>')
    return "\n".join(out)


def q(s, p):
    s = pd.to_numeric(s, errors="coerce").dropna()
    return float(np.quantile(s, p)) if len(s) else np.nan


# ── report ────────────────────────────────────────────────────────────────────
CSS = """
:root{color-scheme:light dark}
html,body{margin:0;background:#ffffff}
@media (prefers-color-scheme:dark){
 html:where(:not([data-theme=light])),html:where(:not([data-theme=light])) body{background:#111110}}
html[data-theme=dark],html[data-theme=dark] body{background:#111110}
.viz-root{
 --surface-0:#ffffff;--surface-1:#fcfcfb;--surface-2:#f4f3f0;--border:#dedcd6;
 --text-primary:#0b0b0b;--text-secondary:#52514e;--text-muted:#7a7873;
 --series-1:#2a78d6;--series-2:#eb6834;--pos:#2a78d6;--neg:#e34948;--mid:#c9c7c0;
 --good:#008300;--bad:#e34948;--heat:34,120,214;
}
@media (prefers-color-scheme:dark){:root:where(:not([data-theme=light])) .viz-root{
 --surface-0:#111110;--surface-1:#1a1a19;--surface-2:#232322;--border:#3a3a37;
 --text-primary:#ffffff;--text-secondary:#c3c2b7;--text-muted:#96958c;
 --series-1:#3987e5;--series-2:#d95926;--pos:#3987e5;--neg:#e66767;--mid:#4a4a46;
 --good:#4fae4f;--bad:#e66767;--heat:57,135,229;}}
:root[data-theme=dark] .viz-root{
 --surface-0:#111110;--surface-1:#1a1a19;--surface-2:#232322;--border:#3a3a37;
 --text-primary:#ffffff;--text-secondary:#c3c2b7;--text-muted:#96958c;
 --series-1:#3987e5;--series-2:#d95926;--pos:#3987e5;--neg:#e66767;--mid:#4a4a46;
 --good:#4fae4f;--bad:#e66767;--heat:57,135,229;}
.viz-root{background:var(--surface-0);color:var(--text-primary);
 font:15px/1.55 ui-sans-serif,-apple-system,"Segoe UI",Roboto,sans-serif;
 margin:0 auto;padding:32px 22px 90px;max-width:1180px}
h1{font-size:1.7rem;margin:0 0 4px;letter-spacing:-.02em}
h2{font-size:1.18rem;margin:44px 0 6px;padding-top:14px;border-top:1px solid var(--border);letter-spacing:-.01em}
h3{font-size:.98rem;margin:24px 0 6px;color:var(--text-secondary)}
p,li{color:var(--text-secondary);max-width:82ch}
.sub{color:var(--text-muted);font-size:.9rem;margin:0 0 6px}
.muted{color:var(--text-muted);font-size:.87rem}
code{background:var(--surface-2);padding:1px 5px;border-radius:4px;font-size:.86em}
pre.cmd{background:var(--surface-2);border:1px solid var(--border);border-radius:8px;
 padding:9px 12px;overflow-x:auto;font-size:.82rem;margin:2px 0 12px}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(178px,1fr));gap:12px;margin:22px 0 6px}
.tile{background:var(--surface-1);border:1px solid var(--border);border-radius:10px;padding:13px 15px}
.tile .k{font-size:.74rem;text-transform:uppercase;letter-spacing:.06em;color:var(--text-muted)}
.tile .v{font-size:1.62rem;font-weight:650;letter-spacing:-.02em;margin-top:3px}
.tile .n{font-size:.8rem;color:var(--text-secondary)}
.tile .v.good{color:var(--good)}.tile .v.bad{color:var(--bad)}
.tw{overflow-x:auto;margin:14px 0;border:1px solid var(--border);border-radius:10px;background:var(--surface-1)}
table{border-collapse:collapse;width:100%;font-size:.87rem}
th,td{padding:6px 10px;text-align:left;border-bottom:1px solid var(--border);white-space:nowrap}
thead th{position:sticky;top:0;background:var(--surface-2);font-weight:600;font-size:.78rem;
 text-transform:uppercase;letter-spacing:.04em;color:var(--text-secondary)}
tbody tr:last-child td{border-bottom:none}
td.num,th.num{text-align:right;font-variant-numeric:tabular-nums}
td.up{color:var(--good)}td.down{color:var(--bad)}td.flat{color:var(--text-muted)}
.chart{width:100%;height:auto;display:block;margin:8px 0 2px}
.chart .grid{stroke:var(--border);stroke-width:1}
.chart .zero{stroke:var(--text-muted);stroke-width:1.5}
.chart .line{fill:none;stroke-width:2;stroke-linejoin:round}
.chart .med{stroke:var(--text-primary);stroke-width:1.5;stroke-dasharray:3 3}
.chart text{fill:var(--text-secondary);font:11px ui-sans-serif,sans-serif}
.chart .cat{fill:var(--text-primary);font-size:12px}
.chart .val{fill:var(--text-secondary);font-size:10.5px}
.chart .tick{fill:var(--text-muted);font-size:10px}
.chart .legend text{fill:var(--text-secondary);font-size:11.5px}
.heat td.hc{text-align:right;font-variant-numeric:tabular-nums;
 background:rgba(var(--heat),calc(var(--t,0)*.82));color:var(--text-primary)}
.heat td.hc.ink{color:#fff}
.heat th.rowhead{background:var(--surface-2);font-weight:500;font-size:.8rem}
.heat td.diag{outline:1px solid var(--border);outline-offset:-1px}
.heat td.prog::after{content:" ↑";color:var(--good);font-size:.8em}
.heat td.reg::after{content:" ↓";color:var(--bad);font-size:.8em}
.heat td.tot,.heat th.tot{background:var(--surface-2);font-weight:600;text-align:right}
.grid2{display:grid;grid-template-columns:repeat(auto-fit,minmax(340px,1fr));gap:16px}
.card{background:var(--surface-1);border:1px solid var(--border);border-radius:10px;padding:10px 12px}
.facts{background:var(--surface-1);border:1px solid var(--border);border-radius:10px;
 padding:12px 18px 14px;margin:20px 0 4px}
.facts h3{margin:0 0 6px;color:var(--text-primary);font-size:.95rem}
.facts ul{margin:0;padding-left:20px}
.facts li{margin:4px 0}
.toc{display:flex;flex-wrap:wrap;gap:6px 10px;margin:20px 0 4px;padding:12px 14px;
 background:var(--surface-1);border:1px solid var(--border);border-radius:10px}
.toc a{color:var(--text-secondary);text-decoration:none;font-size:.83rem;
 border-bottom:1px solid transparent}
.toc a:hover{color:var(--text-primary);border-bottom-color:var(--series-1)}
.note{border-left:3px solid var(--series-2);background:var(--surface-1);padding:10px 14px;
 border-radius:0 8px 8px 0;margin:14px 0}
.note p{margin:4px 0}
"""


def build_html(la, lb, A, B, coreA, coreB, srcA, srcB, metaA=None, metaB=None, cmdA=None, cmdB=None):
    common = A.index.intersection(B.index)
    onlyA = A.index.difference(B.index)
    onlyB = B.index.difference(A.index)
    Ac, Bc = A.loc[common], B.loc[common]

    oa, ob = Ac["outcome"], Bc["outcome"]
    used = [o for o in OUTCOME_ORDER if (oa == o).any() or (ob == o).any()]
    mat = pd.crosstab(oa, ob).reindex(index=used, columns=used, fill_value=0)

    rank_a = oa.map(RANK)
    rank_b = ob.map(RANK)
    progressed = int((rank_b > rank_a).sum())
    regressed = int((rank_b < rank_a).sum())
    failed_before = ~oa.isin(GOOD | {"sat"})
    newly_trimmed = int((failed_before & ob.isin(GOOD)).sum())
    lost = int((oa.isin(GOOD) & ~ob.isin(GOOD)).sum())
    to_trim = {k: int((oa.eq(k) & ob.isin(GOOD)).sum()) for k in
               ("trim_timeout", "oom", "no_proof", "truncated", "not_solved", "other_error")}

    # cohort trimmed in both runs
    both = common[oa.isin(GOOD).values & ob.isin(GOOD).values]
    P, Q_ = A.loc[both], B.loc[both]

    def red_eq(d):
        i = pd.to_numeric(d["inp_total_nbeq"], errors="coerce")
        o = pd.to_numeric(d["grim_total_cone"], errors="coerce")
        return ((i - o) / i).where(i > 0)

    def red_sz(d):
        i = pd.to_numeric(d["inp_total_size"], errors="coerce")
        o = pd.to_numeric(d["grim_total_size"], errors="coerce")
        return ((i - o) / i).where(i > 0)

    def red_lit(d):
        i = pd.to_numeric(d["grim_cone_literals"], errors="coerce")
        o = pd.to_numeric(d["grim_smol_literals"], errors="coerce")
        return ((i - o) / i).where(i > 0)

    for d in (P, Q_):
        d["_red_eq"] = red_eq(d)
        d["_red_sz"] = red_sz(d)
        d["_red_lit"] = red_lit(d)

    H = []
    add = H.append
    add(f'<div class="viz-root">')
    add(f"<h1>Comparaison des runs {html.escape(la)} → {html.escape(lb)}</h1>")
    add(f'<p class="sub">généré le {datetime.now():%Y-%m-%d %H:%M} · '
        f'{html.escape(srcA)} vs {html.escape(srcB)}</p>')

    # ── hero tiles ────────────────────────────────────────────────────────────
    va, vb = int((A["outcome"] == "verified").sum()), int((B["outcome"] == "verified").sum())
    ga, gb = int(A["outcome"].isin(GOOD).sum()), int(B["outcome"].isin(GOOD).sum())
    sza = pd.to_numeric(A["grim_total_size"], errors="coerce").sum()
    szb = pd.to_numeric(B["grim_total_size"], errors="coerce").sum()

    def tile(k, v, n, cls=""):
        return (f'<div class="tile"><div class="k">{html.escape(k)}</div>'
                f'<div class="v {cls}">{v}</div><div class="n">{n}</div></div>')

    add('<div class="tiles">')
    add(tile("instances traitées", f"{fnum(len(B))}", f"{la}: {fnum(len(A))} · +{fnum(len(onlyB))} nouvelles"))
    add(tile("preuves trimmées", f"{fnum(gb)}", f"{la}: {fnum(ga)} · {sgn(gb - ga)}",
             "good" if gb >= ga else "bad"))
    add(tile("vérifiées VeriPB", f"{fnum(vb)}", f"{la}: {fnum(va)} · {sgn(vb - va)}",
             "good" if vb >= va else "bad"))
    add(tile("nouvelles réussites*", f"{fnum(newly_trimmed)}",
             f"instances communes qui échouaient en {la}", "good" if newly_trimmed else ""))
    add(tile("régressions*", f"{fnum(lost)}", f"trimmées en {la}, plus en {lb}",
             "bad" if lost else "good"))
    add(tile("taille trimmée totale", fbytes(szb), f"{la}: {fbytes(sza)}"))
    add("</div>")
    add('<p class="muted">* sur les 'f'{fnum(len(common))} instances présentes dans les deux runs.</p>')
    add("<!--FACTS-->")
    add("<!--TOC-->")
    facts = []

    # ── 0. provenance & confounds ─────────────────────────────────────────────
    metaA, metaB = metaA or {}, metaB or {}
    keys = [k for k in dict.fromkeys(list(metaA) + list(metaB))
            if k.lower() not in ("", "run", "instance")][:14]
    add("<h2>0 · Ce que cette comparaison peut établir</h2>")
    if keys:
        add('<div class="tw"><table><thead><tr><th>paramètre</th>'
            f'<th>{html.escape(la)}</th><th>{html.escape(lb)}</th></tr></thead><tbody>')
        for k in keys:
            va_, vb_ = metaA.get(k, "—"), metaB.get(k, "—")
            diff = ' class="down"' if (va_ != vb_ and "—" not in (va_, vb_)) else ""
            add(f'<tr><td>{html.escape(k)}</td><td>{html.escape(va_)}</td>'
                f'<td{diff}>{html.escape(vb_)}</td></tr>')
        add("</tbody></table></div>")
        missing = [t for t, m in ((la, metaA), (lb, metaB)) if not m]
        add('<p class="muted">Extrait des <code>README.md</code> des répertoires de run ; '
            "les valeurs qui diffèrent sont surlignées." +
            (f" Aucun README pour <code>{html.escape(', '.join(missing))}</code> : "
             "sa provenance n'est pas enregistrée et n'est donc pas devinée ici." if missing else "")
            + "</p>")
    for tag, cmd in ((la, cmdA), (lb, cmdB)):
        if cmd:
            add(f'<p class="muted">commande {html.escape(tag)} :</p>'
                f'<pre class="cmd">{html.escape(cmd)}</pre>')
    add('<div class="note"><p><strong>Deux runs séparés ne sont pas une expérience contrôlée.</strong> '
        "Entre les deux, l'ensemble d'instances, la branche du solveur, les timeouts et "
        "l'environnement de la machine ont pu changer en même temps. Ce document mesure "
        "<em>l'écart de bout en bout</em> entre deux campagnes, pas l'effet d'une cause isolée. "
        "Les blocs appariés (mêmes instances, mêmes issues) éliminent l'effet de couverture ; "
        "ils n'attribuent pas pour autant le reste à un facteur unique. Pour un A/B propre sur "
        "une seule variable, il faut deux runs du même jour ne différant que par elle.</p></div>")

    # ── 1. coverage ───────────────────────────────────────────────────────────
    facts.append(f"{fnum(len(onlyB))} instances de plus sont traitées en {html.escape(lb)}, "
                 f"soit {sgn(gb - ga)} preuves trimmées au total — mais seulement "
                 f"<strong>{fnum(newly_trimmed)}</strong> gains et {fnum(lost)} pertes sur les "
                 f"{fnum(len(common))} instances communes aux deux runs.")
    add("<h2>1 · Couverture</h2>")
    add(f"<p>Les deux runs ne portent pas sur le même ensemble d'instances : "
        f"<strong>{fnum(len(onlyB))}</strong> instances n'apparaissent que dans <code>{html.escape(lb)}</code> "
        f"et <strong>{fnum(len(onlyA))}</strong> que dans <code>{html.escape(la)}</code>. "
        f"Toute comparaison appariée ci-dessous est donc restreinte aux "
        f"<strong>{fnum(len(common))}</strong> instances communes ; les totaux globaux sont donnés "
        f"séparément et ne sont pas directement comparables.</p>")

    rows = []
    fam = sorted(set(A["family"].dropna()) | set(B["family"].dropna()))
    for f in fam:
        na, nb = int((A["family"] == f).sum()), int((B["family"] == f).sum())
        gaf = int(((A["family"] == f) & A["outcome"].isin(GOOD)).sum())
        gbf = int(((B["family"] == f) & B["outcome"].isin(GOOD)).sum())
        rows.append((f, na, nb, gaf, gbf))
    add('<div class="tw"><table><thead><tr><th>famille</th>'
        f'<th class="num">instances {html.escape(la)}</th><th class="num">instances {html.escape(lb)}</th>'
        f'<th class="num">Δ</th><th class="num">trimmées {html.escape(la)}</th>'
        f'<th class="num">trimmées {html.escape(lb)}</th><th class="num">Δ</th>'
        f'<th class="num">taux {html.escape(la)}</th><th class="num">taux {html.escape(lb)}</th>'
        "</tr></thead><tbody>")
    for f, na, nb, gaf, gbf in rows:
        add(f'<tr><td>{html.escape(f)}</td><td class="num">{fnum(na)}</td><td class="num">{fnum(nb)}</td>'
            f'<td class="num">{sgn(nb - na)}</td>'
            f'<td class="num">{fnum(gaf)}</td><td class="num">{fnum(gbf)}</td>'
            f'<td class="num {"up" if gbf >= gaf else "down"}">{sgn(gbf - gaf)}</td>'
            f'<td class="num">{pct(gaf / na if na else np.nan)}</td>'
            f'<td class="num">{pct(gbf / nb if nb else np.nan)}</td></tr>')
    add(f'<tr><td><strong>total</strong></td><td class="num">{fnum(len(A))}</td><td class="num">{fnum(len(B))}</td>'
        f'<td class="num">{sgn(len(B) - len(A))}</td>'
        f'<td class="num">{fnum(ga)}</td><td class="num">{fnum(gb)}</td>'
        f'<td class="num {"up" if gb >= ga else "down"}">{sgn(gb - ga)}</td>'
        f'<td class="num">{pct(ga / len(A))}</td><td class="num">{pct(gb / len(B))}</td></tr>')
    add("</tbody></table></div>")

    # ── 2. outcomes ───────────────────────────────────────────────────────────
    add("<h2>2 · Issues, run par run</h2>")
    add(f"<p>Répartition des issues sur les {fnum(len(common))} instances communes. "
        "Une instance est « trimmée » dès que TrimAnalyser a produit un cône ; "
        "« vérifiée » ajoute le passage VeriPB.</p>")
    add(svg_grouped_bars([(OUTCOME_LABEL[o], int((oa == o).sum()), int((ob == o).sum())) for o in used],
                         la, lb))
    add('<div class="tw"><table><thead><tr><th>issue</th>'
        f'<th class="num">{html.escape(la)} (commun)</th><th class="num">{html.escape(lb)} (commun)</th>'
        f'<th class="num">Δ</th><th class="num">{html.escape(la)} (tout)</th>'
        f'<th class="num">{html.escape(lb)} (tout)</th></tr></thead><tbody>')
    for o in used:
        ca, cb = int((oa == o).sum()), int((ob == o).sum())
        good = o in (GOOD | {"sat"})
        cls = ("up" if (cb >= ca) == good else "down") if ca != cb else "flat"
        add(f'<tr><td>{html.escape(OUTCOME_LABEL[o])}</td><td class="num">{fnum(ca)}</td>'
            f'<td class="num">{fnum(cb)}</td><td class="num {cls}">{sgn(cb - ca)}</td>'
            f'<td class="num">{fnum(int((A["outcome"] == o).sum()))}</td>'
            f'<td class="num">{fnum(int((B["outcome"] == o).sum()))}</td></tr>')
    add("</tbody></table></div>")

    # ── 3. transition matrix ──────────────────────────────────────────────────
    add("<h2>3 · Matrice de transition</h2>")
    add(f"<p>Chaque case compte les instances communes passées de l'issue en ligne "
        f"(<code>{html.escape(la)}</code>) à celle en colonne (<code>{html.escape(lb)}</code>). "
        f"↑ = progrès, ↓ = régression. <strong>{fnum(progressed)}</strong> instances progressent, "
        f"<strong>{fnum(regressed)}</strong> régressent, "
        f"{fnum(len(common) - progressed - regressed)} sont stables.</p>")
    add('<div class="tw">' + heat_table(mat, used, used, la, lb) + "</div>")
    add('<div class="note"><p><strong>Ce qui a débloqué :</strong> ' +
        " · ".join(f"{OUTCOME_LABEL[k]} → trimmé : <strong>{fnum(v)}</strong>"
                   for k, v in to_trim.items() if v) + "</p>")
    if lost:
        lost_idx = common[(oa.isin(GOOD) & ~ob.isin(GOOD)).values]
        brk = Bc.loc[lost_idx, "outcome"].value_counts()
        add("<p><strong>Ce qui a été perdu :</strong> " +
            " · ".join(f"{OUTCOME_LABEL.get(k, k)} : <strong>{fnum(int(v))}</strong>"
                       for k, v in brk.items()) + "</p>")
    add("</div>")

    # SAT/UNSAT flips: a real disagreement between the two runs, not progress
    flip_ab = common[(oa.eq("sat") & ob.isin(GOOD)).values]
    flip_ba = common[(oa.isin(GOOD) & ob.eq("sat")).values]
    cls = "note" if (len(flip_ab) or len(flip_ba)) else "note"
    add(f'<div class="{cls}"><p><strong>Cohérence SAT / UNSAT :</strong> ')
    if len(flip_ab) or len(flip_ba):
        add(f'{fnum(len(flip_ab))} instances SAT en {html.escape(la)} sont UNSAT prouvées en '
            f'{html.escape(lb)}, et {fnum(len(flip_ba))} dans l\'autre sens. '
            "Ce sont des désaccords de résultat, pas des progrès — à examiner un par un : "
            + ", ".join(f"<code>{html.escape(i)}</code>" for i in list(flip_ab) + list(flip_ba))[:1200])
    else:
        add("aucune instance ne bascule entre SAT et UNSAT-prouvée. Les deux runs sont d'accord "
            "sur toutes les instances communes qu'ils ont conclues.")
    add("</p></div>")

    # ── 3bis. reachable frontier ──────────────────────────────────────────────
    add("<h2>4 · Frontière atteignable</h2>")
    add("<p>Les échecs ne sont pas répartis au hasard : ce sont les grosses instances. "
        "<code>target_vertices</code> et <code>pattern_vertices</code> sont renseignés même quand "
        "le run échoue — on peut donc mesurer <em>jusqu'où</em> chaque run va, et non seulement "
        "combien d'instances il traite. Taux calculés sur les instances communes.</p>")

    def size_bins(colname, edges, labels):
        sa = pd.to_numeric(col(Ac, colname), errors="coerce")
        rows_, chart_ = [], []
        for i, lab in enumerate(labels):
            lo_, hi_ = edges[i], edges[i + 1]
            m = (sa >= lo_) & (sa < hi_)
            n = int(m.sum())
            if n == 0:
                continue
            ra = float(oa[m.values].isin(GOOD).mean())
            rb = float(ob[m.values].isin(GOOD).mean())
            rows_.append((lab, n, ra, rb, int(oa[m.values].isin(GOOD).sum()),
                          int(ob[m.values].isin(GOOD).sum())))
            chart_.append((lab, ra * 100, rb * 100))
        return rows_, chart_

    edges = [0, 100, 300, 1000, 3000, 6000, np.inf]
    labels_t = ["< 100", "100 – 300", "300 – 1 000", "1 000 – 3 000", "3 000 – 6 000", "≥ 6 000"]
    rows_t, chart_t = size_bins("target_vertices", edges, labels_t)
    add(svg_grouped_bars(chart_t, la, lb, fmt=lambda v: f"{v:.1f} %", vmax=100))
    add('<div class="tw"><table><thead><tr><th>sommets cible</th><th class="num">instances</th>'
        f'<th class="num">trimmées {html.escape(la)}</th><th class="num">trimmées {html.escape(lb)}</th>'
        f'<th class="num">taux {html.escape(la)}</th><th class="num">taux {html.escape(lb)}</th>'
        '<th class="num">Δ points</th></tr></thead><tbody>')
    for lab, n, ra, rb, ca_, cb_ in rows_t:
        d = (rb - ra) * 100
        cls = "up" if d > 0.05 else ("down" if d < -0.05 else "flat")
        add(f'<tr><td>{lab}</td><td class="num">{fnum(n)}</td><td class="num">{fnum(ca_)}</td>'
            f'<td class="num">{fnum(cb_)}</td><td class="num">{pct(ra)}</td>'
            f'<td class="num">{pct(rb)}</td><td class="num {cls}">{d:+.1f}</td></tr>')
    add("</tbody></table></div>")

    if rows_t:
        best = max(rows_t, key=lambda r: r[3] - r[2])
        worst = min(rows_t, key=lambda r: r[3] - r[2])
        facts.append(f"Le gain est concentré sur une tranche de taille : "
                     f"<strong>{best[0]} sommets cible</strong>, taux de trim "
                     f"{pct(best[2])} → {pct(best[3])} ({(best[3] - best[2]) * 100:+.1f} points, "
                     f"n = {fnum(best[1])})." +
                     (f" La tranche {worst[0]} recule de {abs(worst[3] - worst[2]) * 100:.1f} points "
                      f"(n = {fnum(worst[1])})." if worst[3] < worst[2] else ""))

    edges_p = [0, 20, 40, 60, 100, 200, np.inf]
    labels_p = ["< 20", "20 – 40", "40 – 60", "60 – 100", "100 – 200", "≥ 200"]
    rows_p, _ = size_bins("pattern_vertices", edges_p, labels_p)
    add("<h3>Par taille du motif</h3>")
    add('<div class="tw"><table><thead><tr><th>sommets motif</th><th class="num">instances</th>'
        f'<th class="num">taux {html.escape(la)}</th><th class="num">taux {html.escape(lb)}</th>'
        '<th class="num">Δ points</th></tr></thead><tbody>')
    for lab, n, ra, rb, _c1, _c2 in rows_p:
        d = (rb - ra) * 100
        cls = "up" if d > 0.05 else ("down" if d < -0.05 else "flat")
        add(f'<tr><td>{lab}</td><td class="num">{fnum(n)}</td><td class="num">{pct(ra)}</td>'
            f'<td class="num">{pct(rb)}</td><td class="num {cls}">{d:+.1f}</td></tr>')
    add("</tbody></table></div>")

    # where the wall sits: size distribution of successes vs failures
    add("<h3>Où est le mur</h3>")
    add('<div class="tw"><table><thead><tr><th>issue</th>'
        f'<th class="num">n {html.escape(la)}</th><th class="num">méd. sommets cible {html.escape(la)}</th>'
        f'<th class="num">p90 {html.escape(la)}</th>'
        f'<th class="num">n {html.escape(lb)}</th><th class="num">méd. sommets cible {html.escape(lb)}</th>'
        f'<th class="num">p90 {html.escape(lb)}</th></tr></thead><tbody>')
    for o in used:
        cells = []
        for d, oo in ((Ac, oa), (Bc, ob)):
            s = pd.to_numeric(col(d, "target_vertices"), errors="coerce")[(oo == o).values]
            cells += [fnum(int((oo == o).sum())), fnum(s.median()), fnum(q(s, .9))]
        add(f'<tr><td>{html.escape(OUTCOME_LABEL[o])}</td>' +
            "".join(f'<td class="num">{c}</td>' for c in cells) + "</tr>")
    add("</tbody></table></div>")

    # ── 4. paired metrics ─────────────────────────────────────────────────────
    add("<h2>5 · Métriques appariées</h2>")
    add(f"<p>Cohorte : les <strong>{fnum(len(both))}</strong> instances trimmées dans "
        f"<em>les deux</em> runs — la seule base sur laquelle tailles et temps sont comparables. "
        "« identiques » est la part d'instances où la valeur n'a pas bougé d'un iota, "
        f"« méd. ratio (≠) » la médiane du rapport <code>{html.escape(lb)} / {html.escape(la)}</code> "
        "sur les seules instances qui changent, et « mieux/pire » le nombre d'instances où "
        f"<code>{html.escape(lb)}</code> fait moins / plus.</p>")
    stats = [
        paired_metric(P, Q_, "inp_total_size", "preuve brute du solveur (octets)", "lower", fbytes),
        paired_metric(P, Q_, "inp_total_nbeq", "contraintes de la preuve brute", "lower", fnum),
        paired_metric(P, Q_, "inp_literals", "littéraux en entrée", "lower", fnum),
        paired_metric(P, Q_, "grim_total_size", "preuve trimmée (octets)", "lower", fbytes),
        paired_metric(P, Q_, "grim_total_cone", "contraintes du cône", "lower", fnum),
        paired_metric(P, Q_, "grim_opb_cone", "cône · partie OPB", "lower", fnum),
        paired_metric(P, Q_, "grim_pbp_cone", "cône · partie PBP", "lower", fnum),
        paired_metric(P, Q_, "grim_smol_literals", "littéraux après trim", "lower", fnum),
        paired_metric(P, Q_, "runtime_ms", "temps solveur (ms)", "lower", fnum),
        paired_metric(P, Q_, "grim_parse_time", "temps de parsing (s)", "lower", lambda x: ftime(x)),
        paired_metric(P, Q_, "grim_trim_time", "temps de trim (s)", "lower", lambda x: ftime(x)),
        paired_metric(P, Q_, "grim_total_time", "temps total trimnalyser (s)", "lower", lambda x: ftime(x)),
        paired_metric(P, Q_, "veri_smol_time", "temps VeriPB (s)", "lower", lambda x: ftime(x)),
        paired_metric(P, Q_, "solver_nodes", "nœuds explorés (solveur)", "lower", fnum),
        paired_metric(P, Q_, "solver_propagations", "propagations", "lower", fnum),
        paired_metric(P, Q_, "resolv_iterations", "itérations resolv", "lower", fnum),
    ]
    add('<div class="tw"><table><thead><tr><th>métrique</th><th class="num">n</th>'
        f'<th class="num">méd. {html.escape(la)}</th><th class="num">méd. {html.escape(lb)}</th>'
        '<th class="num">Δ méd.</th>'
        f'<th class="num">moy. {html.escape(la)}</th><th class="num">moy. {html.escape(lb)}</th>'
        f'<th class="num">total {html.escape(la)}</th><th class="num">total {html.escape(lb)}</th>'
        '<th class="num">Δ total</th><th class="num">identiques</th>'
        '<th class="num">méd. ratio (≠)</th><th class="num">mieux/pire</th>'
        '<th class="num">p</th>'
        "</tr></thead><tbody>")
    add(metric_rows(stats))
    add("</tbody></table></div>")

    same_sz = paired_metric(P, Q_, "inp_total_size", "", fmt=fbytes)
    facts.append(f"<strong>{pct(same_sz['same_frac'])}</strong> des preuves brutes appariées sont "
                 f"strictement identiques dans les deux runs ; sur les "
                 f"{fnum(same_sz['n'] - same_sz['same'])} qui changent, la taille est multipliée par "
                 f"<strong>{same_sz['med_ratio_diff']:.2f}</strong> en médiane. Total : "
                 f"{fbytes(same_sz['sum_a'])} → {fbytes(same_sz['sum_b'])}.")
    tt = paired_metric(P, Q_, "grim_trim_time", "", fmt=ftime)
    if tt:
        facts.append(f"Temps de trim : médiane {ftime(tt['med_a'])} → {ftime(tt['med_b'])}, "
                     f"rapport médian ×{tt['med_ratio_diff']:.2f} "
                     f"({fnum(tt['wins'])} instances plus rapides contre {fnum(tt['losses'])} plus lentes, "
                     f"p {fp(tt['p'])}).")
    add(f'<div class="note"><p><strong>Le résultat dominant est ailleurs :</strong> '
        f'{pct(same_sz["same_frac"])} des instances appariées ont une preuve brute '
        f'<em>strictement identique</em> dans les deux runs (mêmes octets). Le solveur ne change de '
        f'sortie que sur {fnum(same_sz["n"] - same_sz["same"])} instances — mais ce sont les grosses, '
        f'd\'où un total qui chute alors que la médiane du rapport vaut 1. La colonne '
        f'« méd. ratio (≠) » ne regarde que les instances effectivement modifiées.</p></div>')

    add("<h3>Distribution des rapports par instance (instances modifiées uniquement)</h3>")
    add('<div class="grid2">')
    for cname, title in (("inp_total_size", "preuve brute"),
                       ("grim_total_size", "preuve trimmée"),
                       ("grim_total_cone", "contraintes du cône"),
                       ("grim_trim_time", "temps de trim")):
        a = pd.to_numeric(P[cname], errors="coerce")
        b = pd.to_numeric(Q_[cname], errors="coerce")
        m = (a > 0) & (b > 0)
        lr = np.log2(b[m] / a[m])
        changed = lr[lr != 0]
        sub = f"{title} — {fnum(len(changed))}/{fnum(int(m.sum()))} modifiées"
        add('<div class="card">' + svg_hist(changed, sub, la, lb) + "</div>")
    add("</div>")

    # ── 5bis. cactus ──────────────────────────────────────────────────────────
    add("<h2>6 · Débit : combien d'instances sous quel budget</h2>")
    add("<p>Courbe cactus classique : pour chaque budget de temps en abscisse, le nombre "
        "d'instances communes dont le trim tient dans ce budget. Une courbe au-dessus de l'autre "
        "domine partout ; deux courbes qui se croisent signalent un compromis (plus rapide sur "
        "les petites, plus lent sur les grosses).</p>")
    tA = pd.to_numeric(col(Ac[oa.isin(GOOD).values], "grim_total_time"), errors="coerce").dropna()
    tB = pd.to_numeric(col(Bc[ob.isin(GOOD).values], "grim_total_time"), errors="coerce").dropna()
    add(svg_cactus([(la, tA.values), (lb, tB.values)], la, lb,
                   "budget de temps trimnalyser (s, échelle log)", "instances trimmées"))
    vA = pd.to_numeric(col(Ac, "veri_smol_time"), errors="coerce").dropna()
    vB = pd.to_numeric(col(Bc, "veri_smol_time"), errors="coerce").dropna()
    if len(vA) and len(vB):
        add("<h3>Vérification VeriPB de la preuve trimmée</h3>")
        add('<p class="muted">Pas de courbe ici : <code>veri_smol_time</code> est enregistré à la '
            "seconde entière, et la majorité des vérifications tombent dans le bucket 0 s — "
            "une échelle log donnerait une courbe trompeuse. Table de budgets à la place.</p>")
        add('<div class="tw"><table><thead><tr><th>budget de vérification</th>'
            f'<th class="num">{html.escape(la)}</th><th class="num">{html.escape(lb)}</th>'
            '<th class="num">Δ</th></tr></thead><tbody>')
        for budget, lab in ((0, "immédiat (0 s)"), (1, "≤ 1 s"), (5, "≤ 5 s"), (30, "≤ 30 s"),
                            (300, "≤ 5 min"), (np.inf, "toutes")):
            ca_, cb_ = int((vA <= budget).sum()), int((vB <= budget).sum())
            add(f'<tr><td>{lab}</td><td class="num">{fnum(ca_)}</td><td class="num">{fnum(cb_)}</td>'
                f'<td class="num {"up" if cb_ >= ca_ else "down"}">{sgn(cb_ - ca_)}</td></tr>')
        add("</tbody></table></div>")
    add('<div class="tw"><table><thead><tr><th>budget</th>'
        f'<th class="num">trimmées {html.escape(la)}</th><th class="num">trimmées {html.escape(lb)}</th>'
        '<th class="num">Δ</th>'
        f'<th class="num">part {html.escape(la)}</th><th class="num">part {html.escape(lb)}</th>'
        "</tr></thead><tbody>")
    for budget, lab in ((1, "1 s"), (10, "10 s"), (60, "1 min"), (600, "10 min"),
                        (1800, "30 min"), (np.inf, "sans limite")):
        ca_, cb_ = int((tA <= budget).sum()), int((tB <= budget).sum())
        add(f'<tr><td>≤ {lab}</td><td class="num">{fnum(ca_)}</td><td class="num">{fnum(cb_)}</td>'
            f'<td class="num {"up" if cb_ >= ca_ else "down"}">{sgn(cb_ - ca_)}</td>'
            f'<td class="num">{pct(ca_ / len(common))}</td>'
            f'<td class="num">{pct(cb_ / len(common))}</td></tr>')
    add("</tbody></table></div>")

    # ── 5. trim quality ───────────────────────────────────────────────────────
    add("<h2>7 · Qualité du trim</h2>")
    add("<p>Taux de réduction obtenus par TrimAnalyser lui-même, sur la même cohorte appariée. "
        "Un taux stable indique que le trimmer se comporte pareil malgré des preuves d'entrée "
        "différentes ; un taux qui bouge signale un changement de structure des preuves.</p>")
    add('<div class="tw"><table><thead><tr><th>réduction</th><th class="num">n</th>'
        f'<th class="num">méd. {html.escape(la)}</th><th class="num">méd. {html.escape(lb)}</th>'
        f'<th class="num">moy. {html.escape(la)}</th><th class="num">moy. {html.escape(lb)}</th>'
        f'<th class="num">p10 {html.escape(la)}</th><th class="num">p10 {html.escape(lb)}</th>'
        f'<th class="num">p90 {html.escape(la)}</th><th class="num">p90 {html.escape(lb)}</th>'
        "</tr></thead><tbody>")
    for cname, lab in (("_red_eq", "contraintes"), ("_red_sz", "octets"), ("_red_lit", "littéraux")):
        a, b = P[cname].dropna(), Q_[cname].dropna()
        add(f'<tr><td>{lab}</td><td class="num">{fnum(min(len(a), len(b)))}</td>'
            f'<td class="num">{pct(a.median())}</td><td class="num">{pct(b.median())}</td>'
            f'<td class="num">{pct(a.mean())}</td><td class="num">{pct(b.mean())}</td>'
            f'<td class="num">{pct(q(a, .1))}</td><td class="num">{pct(q(b, .1))}</td>'
            f'<td class="num">{pct(q(a, .9))}</td><td class="num">{pct(q(b, .9))}</td></tr>')
    ta_i = pd.to_numeric(P["inp_total_size"], errors="coerce").sum()
    ta_o = pd.to_numeric(P["grim_total_size"], errors="coerce").sum()
    tb_i = pd.to_numeric(Q_["inp_total_size"], errors="coerce").sum()
    tb_o = pd.to_numeric(Q_["grim_total_size"], errors="coerce").sum()
    add(f'<tr><td><strong>agrégée (Σ sortie / Σ entrée)</strong></td><td class="num">{fnum(len(both))}</td>'
        f'<td class="num">{pct(1 - ta_o / ta_i)}</td><td class="num">{pct(1 - tb_o / tb_i)}</td>'
        '<td class="num">—</td><td class="num">—</td><td class="num">—</td><td class="num">—</td>'
        '<td class="num">—</td><td class="num">—</td></tr>')
    add("</tbody></table></div>")

    # cone composition
    add("<h3>Composition du cône</h3>")
    comp = []
    for cname, lab in (("grim_rup_frac", "RUP"), ("grim_pol_frac", "POL"),
                     ("grim_ia_frac", "IA"), ("grim_red_frac", "RED")):
        if cname in P.columns:
            a = pd.to_numeric(P[cname], errors="coerce").dropna()
            b = pd.to_numeric(Q_[cname], errors="coerce").dropna()
            if len(a) and len(b):
                comp.append((lab, a.mean(), b.mean(), a.median(), b.median()))
    depth = []
    for cname, lab, f in (("grim_cone_depth_max", "profondeur max", fnum),
                        ("grim_cone_depth_mean", "profondeur moyenne", lambda x: fnum(x, 2)),
                        ("grim_cone_depth_entropy", "entropie de profondeur", lambda x: fnum(x, 3)),
                        ("grim_cone_width_max", "largeur max", fnum),
                        ("grim_cone_pol_ante_mean", "antécédents POL / étape", lambda x: fnum(x, 2))):
        s = paired_metric(P, Q_, cname, lab, "lower", f, total=False)
        if s:
            depth.append(s)
    add('<div class="tw"><table><thead><tr><th>part du cône</th>'
        f'<th class="num">moy. {html.escape(la)}</th><th class="num">moy. {html.escape(lb)}</th>'
        f'<th class="num">méd. {html.escape(la)}</th><th class="num">méd. {html.escape(lb)}</th>'
        "</tr></thead><tbody>")
    for lab, am, bm, amd, bmd in comp:
        add(f'<tr><td>{lab}</td><td class="num">{pct(am)}</td><td class="num">{pct(bm)}</td>'
            f'<td class="num">{pct(amd)}</td><td class="num">{pct(bmd)}</td></tr>')
    add("</tbody></table></div>")
    if depth:
        add('<div class="tw"><table><thead><tr><th>structure du DAG</th><th class="num">n</th>'
            f'<th class="num">méd. {html.escape(la)}</th><th class="num">méd. {html.escape(lb)}</th>'
            '<th class="num">Δ méd.</th>'
            f'<th class="num">moy. {html.escape(la)}</th><th class="num">moy. {html.escape(lb)}</th>'
            '<th class="num">identiques</th><th class="num">méd. ratio (≠)</th>'
            '<th class="num">mieux/pire</th><th class="num">p</th></tr></thead><tbody>')
        add(metric_rows(depth, compact=True))
        add("</tbody></table></div>")

    # ── 7bis. constraint labels ───────────────────────────────────────────────
    add("<h2>8 · Étiquettes de contraintes</h2>")
    add("<p>Le cœur de la caractérisation : de <em>quoi</em> le cône est-il fait. Pour chaque "
        "étiquette, « part » est sa fraction moyenne du cône, « présence » la proportion "
        "d'instances où elle apparaît au moins une fois, et « rétention » la part des contraintes "
        "de ce type produites par le solveur qui survivent au trim "
        "(<code>Σ cône / Σ full</code>). Une étiquette dont la rétention change beaucoup a changé "
        "de rôle dans la preuve, même si le cône garde la même taille.</p>")

    struct = ("rup", "pol", "red", "ia", "literals", "variables", "uniq_pat", "uniq_tar")
    skipsub = ("depth", "width", "frac", "ante", "burst", "bottom", "entropy",
               "bottleneck", "opb", "pbp", "cone", "full")
    labels = []
    for c in P.columns:
        if not c.startswith("grim_cone_"):
            continue
        suf = c[len("grim_cone_"):]
        if suf in struct or any(k in suf for k in skipsub) or f"grim_full_{suf}" not in P.columns:
            continue
        labels.append(suf)

    tot_a = pd.to_numeric(P["grim_total_cone"], errors="coerce")
    tot_b = pd.to_numeric(Q_["grim_total_cone"], errors="coerce")
    lab_rows = []
    for suf in labels:
        ca_ = pd.to_numeric(P[f"grim_cone_{suf}"], errors="coerce")
        cb_ = pd.to_numeric(Q_[f"grim_cone_{suf}"], errors="coerce")
        fa_ = pd.to_numeric(P[f"grim_full_{suf}"], errors="coerce")
        fb_ = pd.to_numeric(Q_[f"grim_full_{suf}"], errors="coerce")
        if ca_.fillna(0).sum() == 0 and cb_.fillna(0).sum() == 0:
            continue
        sa_ = (ca_ / tot_a).where(tot_a > 0)
        sb_ = (cb_ / tot_b).where(tot_b > 0)
        _, _, p = sign_test(ca_.values, cb_.values)
        lab_rows.append(dict(
            lab=suf,
            share_a=float(sa_.mean()), share_b=float(sb_.mean()),
            pres_a=float((ca_ > 0).mean()), pres_b=float((cb_ > 0).mean()),
            sum_a=float(ca_.fillna(0).sum()), sum_b=float(cb_.fillna(0).sum()),
            ret_a=float(ca_.fillna(0).sum() / fa_.fillna(0).sum()) if fa_.fillna(0).sum() else np.nan,
            ret_b=float(cb_.fillna(0).sum() / fb_.fillna(0).sum()) if fb_.fillna(0).sum() else np.nan,
            p=p))
    lab_rows.sort(key=lambda r: -max(r["share_a"], r["share_b"]))

    movers_share = sorted(lab_rows, key=lambda r: -abs(r["share_b"] - r["share_a"]))[:3]
    if movers_share:
        facts.append("Composition du cône : " + ", ".join(
            f"<code>{html.escape(r['lab'])}</code> {pct(r['share_a'], 2)} → {pct(r['share_b'], 2)}"
            for r in movers_share) + " (parts moyennes du cône).")
    ret_movers = [r for r in lab_rows
                  if np.isfinite(r["ret_a"]) and np.isfinite(r["ret_b"]) and r["ret_a"] > 0
                  and max(r["sum_a"], r["sum_b"]) > 1000]
    ret_movers.sort(key=lambda r: -abs(r["ret_b"] - r["ret_a"]))
    if ret_movers[:3]:
        facts.append("Rétention après trim (Σ cône / Σ full) : " + ", ".join(
            f"<code>{html.escape(r['lab'])}</code> {pct(r['ret_a'])} → {pct(r['ret_b'])}"
            for r in ret_movers[:3]) + ".")

    top = [(r["lab"], r["share_a"] * 100, r["share_b"] * 100) for r in lab_rows[:12]]
    if top:
        add(svg_grouped_bars(top, la, lb, fmt=lambda v: f"{v:.1f} %", pad_left=140))
    add('<div class="tw"><table><thead><tr><th>étiquette</th>'
        f'<th class="num">part {html.escape(la)}</th><th class="num">part {html.escape(lb)}</th>'
        '<th class="num">Δ part</th>'
        f'<th class="num">présence {html.escape(la)}</th><th class="num">présence {html.escape(lb)}</th>'
        f'<th class="num">total cône {html.escape(la)}</th><th class="num">total cône {html.escape(lb)}</th>'
        f'<th class="num">rétention {html.escape(la)}</th><th class="num">rétention {html.escape(lb)}</th>'
        '<th class="num">p</th></tr></thead><tbody>')
    for r in lab_rows:
        dshare = (r["share_b"] - r["share_a"]) * 100
        cls = "flat" if abs(dshare) < 0.05 else ("up" if dshare > 0 else "down")
        add(f'<tr><td>{html.escape(r["lab"])}</td>'
            f'<td class="num">{pct(r["share_a"], 2)}</td><td class="num">{pct(r["share_b"], 2)}</td>'
            f'<td class="num {cls}">{dshare:+.2f} pt</td>'
            f'<td class="num">{pct(r["pres_a"])}</td><td class="num">{pct(r["pres_b"])}</td>'
            f'<td class="num">{fnum(r["sum_a"])}</td><td class="num">{fnum(r["sum_b"])}</td>'
            f'<td class="num">{pct(r["ret_a"])}</td><td class="num">{pct(r["ret_b"])}</td>'
            f'<td class="num">{fp(r["p"])}</td></tr>')
    add("</tbody></table></div>")
    gone = [r["lab"] for r in lab_rows if r["pres_a"] > 0.02 and r["pres_b"] < 0.002]
    born = [r["lab"] for r in lab_rows if r["pres_b"] > 0.02 and r["pres_a"] < 0.002]
    if gone or born:
        add('<div class="note"><p><strong>Étiquettes qui apparaissent ou disparaissent :</strong> ' +
            (f'présentes en {html.escape(la)} et absentes en {html.escape(lb)} : '
             + ", ".join(f"<code>{html.escape(g)}</code>" for g in gone) + ". " if gone else "") +
            (f'nouvelles en {html.escape(lb)} : '
             + ", ".join(f"<code>{html.escape(g)}</code>" for g in born) + "." if born else "") +
            "</p></div>")

    # ── 7ter. UNSAT core & variable order ─────────────────────────────────────
    add("<h2>9 · Cœur UNSAT et ordre des variables</h2>")
    add("<p>Propriétés sémantiques de la preuve, indépendantes de sa taille en octets : "
        "quelle partie du graphe le cône touche réellement.</p>")
    core_stats = [
        paired_metric(P, Q_, "core_pattern_nodes", "sommets motif dans le cœur", "lower", fnum, total=False),
        paired_metric(P, Q_, "core_target_nodes", "sommets cible dans le cœur", "lower", fnum, total=False),
        paired_metric(P, Q_, "grim_cone_uniq_pat", "sommets motif distincts dans le cône", "lower", fnum, total=False),
        paired_metric(P, Q_, "grim_cone_uniq_tar", "sommets cible distincts dans le cône", "lower", fnum, total=False),
        paired_metric(P, Q_, "grim_full_uniq_pat", "sommets motif distincts, preuve entière", "lower", fnum, total=False),
        paired_metric(P, Q_, "grim_full_uniq_tar", "sommets cible distincts, preuve entière", "lower", fnum, total=False),
    ]
    if any(core_stats):
        add('<div class="tw"><table><thead><tr><th>métrique</th><th class="num">n</th>'
            f'<th class="num">méd. {html.escape(la)}</th><th class="num">méd. {html.escape(lb)}</th>'
            '<th class="num">Δ méd.</th>'
            f'<th class="num">moy. {html.escape(la)}</th><th class="num">moy. {html.escape(lb)}</th>'
            '<th class="num">identiques</th><th class="num">méd. ratio (≠)</th>'
            '<th class="num">mieux/pire</th><th class="num">p</th></tr></thead><tbody>')
        add(metric_rows(core_stats, compact=True))
        add("</tbody></table></div>")

    # ── 6. resolv ─────────────────────────────────────────────────────────────
    add("<h2>10 · Boucle resolv</h2>")
    rr = []
    for tag, d, cd in ((la, A, coreA), (lb, B, coreB)):
        inv = pd.to_numeric(d["resolv_iterations"], errors="coerce")
        ps = pd.to_numeric(d["resolv_pat_shrinkage"], errors="coerce")
        ts = pd.to_numeric(d["resolv_tar_shrinkage"], errors="coerce")
        rr.append((tag, int(ps.notna().sum()), int((inv > 0).sum()), int(len(cd)),
                   float(inv[inv > 0].median()) if (inv > 0).any() else np.nan,
                   float(ps[ps > 0].median()), float(ts[ts > 0].median())))
    add('<div class="tw"><table><thead><tr><th>run</th><th class="num">resolv invoqué</th>'
        '<th class="num">≥1 itération</th><th class="num">lignes .coreN</th>'
        '<th class="num">méd. itérations</th><th class="num">méd. shrinkage motif</th>'
        '<th class="num">méd. shrinkage cible</th></tr></thead><tbody>')
    for tag, ninv, n, nc, mi, ps, ts in rr:
        add(f'<tr><td>{html.escape(tag)}</td><td class="num">{fnum(ninv)}</td>'
            f'<td class="num">{fnum(n)}</td><td class="num">{fnum(nc)}</td>'
            f'<td class="num">{fnum(mi)}</td>'
            f'<td class="num">{pct(ps)}</td><td class="num">{pct(ts)}</td></tr>')
    add("</tbody></table></div>")
    add('<p class="muted">Shrinkage : médianes sur les instances où il est strictement positif, '
        "comme dans <code>quick_stats.jl</code>.</p>")
    sa = A["resolv_stop_reason"].value_counts()
    sb = B["resolv_stop_reason"].value_counts()
    keys = sorted(set(sa.index) | set(sb.index))
    add('<div class="tw"><table><thead><tr><th>raison d\'arrêt resolv</th>'
        f'<th class="num">{html.escape(la)}</th><th class="num">{html.escape(lb)}</th>'
        "</tr></thead><tbody>")
    for k in keys:
        add(f'<tr><td>{html.escape(str(k))}</td><td class="num">{fnum(int(sa.get(k, 0)))}</td>'
            f'<td class="num">{fnum(int(sb.get(k, 0)))}</td></tr>')
    add("</tbody></table></div>")

    # ── 7. per-family paired ──────────────────────────────────────────────────
    add("<h2>11 · Détail par famille (cohorte appariée)</h2>")
    add('<div class="tw"><table><thead><tr><th>famille</th><th class="num">n appariées</th>'
        '<th class="num">méd. preuve brute Δ</th><th class="num">méd. cône Δ</th>'
        '<th class="num">méd. temps trim Δ</th>'
        f'<th class="num">réduction méd. {html.escape(la)}</th>'
        f'<th class="num">réduction méd. {html.escape(lb)}</th>'
        '<th class="num">nouvelles réussites</th><th class="num">régressions</th>'
        "</tr></thead><tbody>")
    for f in fam:
        idx = both[(P["family"] == f).values]
        cidx = common[(Ac["family"] == f).values]
        nt = int((~Ac.loc[cidx, "outcome"].isin(GOOD | {"sat"}) & Bc.loc[cidx, "outcome"].isin(GOOD)).sum())
        lo = int((Ac.loc[cidx, "outcome"].isin(GOOD) & ~Bc.loc[cidx, "outcome"].isin(GOOD)).sum())
        if len(idx) == 0:
            add(f'<tr><td>{html.escape(f)}</td><td class="num">0</td>' + '<td class="num">—</td>' * 5 +
                f'<td class="num">{fnum(nt)}</td><td class="num">{fnum(lo)}</td></tr>')
            continue
        p, qq = P.loc[idx], Q_.loc[idx]
        cells = []
        for cname in ("inp_total_size", "grim_total_cone", "grim_trim_time"):
            a = pd.to_numeric(p[cname], errors="coerce")
            b = pd.to_numeric(qq[cname], errors="coerce")
            m = a.notna() & b.notna()
            cells.append(delta_cell(b[m].median(), a[m].median(), "lower") if m.any()
                         else '<td class="num">—</td>')
        add(f'<tr><td>{html.escape(f)}</td><td class="num">{fnum(len(idx))}</td>' + "".join(cells) +
            f'<td class="num">{pct(p["_red_eq"].median())}</td>'
            f'<td class="num">{pct(qq["_red_eq"].median())}</td>'
            f'<td class="num {"up" if nt else "flat"}">{fnum(nt)}</td>'
            f'<td class="num {"down" if lo else "flat"}">{fnum(lo)}</td></tr>')
    add("</tbody></table></div>")

    # ── 8. movers ─────────────────────────────────────────────────────────────
    add("<h2>12 · Instances qui bougent le plus</h2>")

    def movers(cname, asc, n=12, fmt=fnum):
        a = pd.to_numeric(P[cname], errors="coerce")
        b = pd.to_numeric(Q_[cname], errors="coerce")
        m = (a > 0) & (b > 0)
        r = (b[m] / a[m]).sort_values(ascending=asc).head(n)
        rows = []
        for ins, ratio in r.items():
            rows.append(f'<tr><td>{html.escape(ins)}</td><td>{html.escape(str(P.at[ins, "family"]))}</td>'
                        f'<td class="num">{fmt(a[ins])}</td><td class="num">{fmt(b[ins])}</td>'
                        f'<td class="num {"up" if ratio < 1 else "down"}">×{ratio:.3f}</td></tr>')
        return "\n".join(rows)

    add('<div class="grid2">')
    for title, asc in (("Cône le plus réduit", True), ("Cône le plus gonflé", False)):
        add('<div class="card"><h3>' + title + "</h3><div class=\"tw\"><table><thead><tr><th>instance</th>"
            f'<th>famille</th><th class="num">{html.escape(la)}</th><th class="num">{html.escape(lb)}</th>'
            '<th class="num">ratio</th></tr></thead><tbody>' + movers("grim_total_cone", asc) +
            "</tbody></table></div></div>")
    add("</div>")

    # newly solved, biggest first
    new_idx = common[(failed_before & ob.isin(GOOD)).values]
    if len(new_idx):
        nn = Bc.loc[new_idx].copy()
        nn["_sz"] = pd.to_numeric(nn["inp_total_size"], errors="coerce")
        nn = nn.sort_values("_sz", ascending=False).head(15)
        add("<h3>Plus grosses instances nouvellement trimmées</h3>")
        add('<div class="tw"><table><thead><tr><th>instance</th><th>famille</th>'
            f'<th>issue {html.escape(la)}</th><th class="num">preuve brute</th>'
            '<th class="num">cône</th><th class="num">temps trim</th>'
            f'<th>issue {html.escape(lb)}</th></tr></thead><tbody>')
        for ins, r in nn.iterrows():
            add(f'<tr><td>{html.escape(ins)}</td><td>{html.escape(str(r["family"]))}</td>'
                f'<td>{html.escape(OUTCOME_LABEL[Ac.at[ins, "outcome"]])}</td>'
                f'<td class="num">{fbytes(r["_sz"])}</td>'
                f'<td class="num">{fnum(pd.to_numeric(r["grim_total_cone"], errors="coerce"))}</td>'
                f'<td class="num">{ftime(pd.to_numeric(r["grim_trim_time"], errors="coerce"))}</td>'
                f'<td>{html.escape(OUTCOME_LABEL[r["outcome"]])}</td></tr>')
        add("</tbody></table></div>")

    lost_idx = common[(oa.isin(GOOD) & ~ob.isin(GOOD)).values]
    if len(lost_idx):
        add("<h3>Régressions (trimmées avant, plus maintenant)</h3>")
        ll = Ac.loc[lost_idx].copy()
        ll["_sz"] = pd.to_numeric(ll["inp_total_size"], errors="coerce")
        ll = ll.sort_values("_sz", ascending=False).head(25)
        add('<div class="tw"><table><thead><tr><th>instance</th><th>famille</th>'
            f'<th class="num">preuve brute {html.escape(la)}</th><th class="num">cône {html.escape(la)}</th>'
            f'<th class="num">temps trim {html.escape(la)}</th><th>issue {html.escape(lb)}</th>'
            f'<th>détail {html.escape(lb)}</th></tr></thead><tbody>')
        for ins, r in ll.iterrows():
            add(f'<tr><td>{html.escape(ins)}</td><td>{html.escape(str(r["family"]))}</td>'
                f'<td class="num">{fbytes(r["_sz"])}</td>'
                f'<td class="num">{fnum(pd.to_numeric(r["grim_total_cone"], errors="coerce"))}</td>'
                f'<td class="num">{ftime(pd.to_numeric(r["grim_trim_time"], errors="coerce"))}</td>'
                f'<td>{html.escape(OUTCOME_LABEL[Bc.at[ins, "outcome"]])}</td>'
                f'<td>{html.escape(str(Bc.at[ins, "error_details"] if pd.notna(Bc.at[ins, "error_details"]) else ""))}</td></tr>')
        add("</tbody></table></div>")

    # ── 9. reading notes ──────────────────────────────────────────────────────
    add("<h2>13 · Précautions de lecture</h2>")
    asym = []
    for o in OUTCOME_ORDER:
        na, nb = int((A["outcome"] == o).sum()), int((B["outcome"] == o).sum())
        if (na == 0) != (nb == 0) and max(na, nb) > 20:
            miss, has = (la, lb) if na == 0 else (lb, la)
            asym.append(f"<li>La catégorie « {html.escape(OUTCOME_LABEL[o])} » est totalement absente de "
                        f"<code>{html.escape(miss)}</code> ({fnum(max(na, nb))} cas dans "
                        f"<code>{html.escape(has)}</code>). Ces instances existent probablement dans les "
                        "deux runs mais y sont classées ailleurs — le diagnostic dépend de ce que "
                        "l'orchestrateur a écrit dans le <code>.err</code>, pas seulement du résultat. "
                        "Les transitions vers/depuis cette catégorie sont à lire avec prudence.</li>")
    add("<ul>" + "".join(asym) +
        f"<li>Les colonnes « tout » comptent des ensembles d'instances différents "
        f"({fnum(len(A))} vs {fnum(len(B))}) : seul le bloc apparié est une comparaison.</li>"
        "<li>Les lignes <code>.coreN</code> (itérations resolv) sont exclues du décompte "
        "d'instances et traitées séparément en §6.</li>"
        "<li>Les temps sont fortement dissymétriques (médiane ≪ moyenne) : les médianes et les "
        "rapports par instance sont les seuls chiffres robustes ici.</li>"
        "<li>Une instance absente d'un run n'est pas un échec : elle n'a pas produit de "
        "<code>.out</code> du tout.</li>"
        "<li>Les preuves tronquées sont des OOM du solveur ; elles sont comptées à part mais "
        "appartiennent à la même cause.</li>"
        "</ul>")
    add("</div>")
    doc = "\n".join(H)

    # anchor every section and build the table of contents from the emitted headings
    heads = re.findall(r"<h2>(.*?)</h2>", doc)
    for i, t in enumerate(heads):
        doc = doc.replace(f"<h2>{t}</h2>", f'<h2 id="s{i}">{t}</h2>', 1)
    nav = ('<nav class="toc">' +
           "".join(f'<a href="#s{i}">{t}</a>' for i, t in enumerate(heads)) + "</nav>")
    doc = doc.replace("<!--TOC-->", nav)
    fact_html = ""
    if facts:
        fact_html = ('<div class="facts"><h3>Faits saillants</h3><ul>' +
                     "".join(f"<li>{f}</li>" for f in facts) + "</ul></div>")
    return doc.replace("<!--FACTS-->", fact_html)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run_a", help="older run: directory or cluster_results.csv")
    ap.add_argument("run_b", help="newer run: directory or cluster_results.csv")
    ap.add_argument("-o", "--out", default=None, help="output HTML (default comparaison-A-vs-B.html)")
    ap.add_argument("--csv", action="store_true", help="also write the per-instance join as CSV")
    args = ap.parse_args()

    la, A, coreA, metaA, cmdA = load_run(args.run_a)
    lb, B, coreB, metaB, cmdB = load_run(args.run_b)
    out = args.out or f"comparaison-{la}-vs-{lb}.html"

    doc = build_html(la, lb, A, B, coreA, coreB, args.run_a, args.run_b,
                     metaA, metaB, cmdA, cmdB)
    page = ("<!doctype html><html lang=\"fr\"><head><meta charset=\"utf-8\">"
            "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
            f"<title>Comparaison {html.escape(la)} → {html.escape(lb)}</title>"
            f"<style>{CSS}</style></head><body>{doc}</body></html>")
    with open(out, "w") as fh:
        fh.write(page)
    print(f"wrote {out}  ({os.path.getsize(out) / 1024:.0f} KB)")

    if args.csv:
        cols = ["family", "outcome", "inp_total_size", "inp_total_nbeq", "grim_total_cone",
                "grim_total_size", "grim_trim_time", "grim_total_time", "runtime_ms",
                "resolv_iterations", "error_type", "error_details", "skip_reason"]
        j = A[cols].add_suffix(f"_{la}").join(B[cols].add_suffix(f"_{lb}"), how="outer")
        cpath = os.path.splitext(out)[0] + "-instances.csv"
        j.to_csv(cpath)
        print(f"wrote {cpath}  ({os.path.getsize(cpath) / 1024:.0f} KB)")


if __name__ == "__main__":
    main()
