#!/usr/bin/env python3
"""Static PDF version of the cone_vs_full.jl mega barplot (Full | Cone stacked bars per family).

Usage:
    python3 scripts/render_cone_vs_full_barplot.py PBstuf/cone_vs_full_all.json PBstuf/cone_vs_full_all.pdf
"""
import json
import sys

import matplotlib
import matplotlib.pyplot as plt

matplotlib.rcParams["font.family"] = "monospace"


def main():
    in_path, out_path = sys.argv[1], sys.argv[2]
    with open(in_path) as f:
        d = json.load(f)

    families = d["families"]
    labels = d["labels"]
    full, cone = d["full"], d["cone"]

    fig, ax = plt.subplots(figsize=(11, 6))
    x = range(len(families))
    width = 0.38

    full_bottoms = [0.0] * len(families)
    cone_bottoms = [0.0] * len(families)
    for i, lab in enumerate(labels):
        key, name, color = lab["key"], lab["name"], lab["color"]
        full_vals = [full[fam][i] for fam in families]
        cone_vals = [cone[fam][i] for fam in families]

        ax.bar([xi - width / 2 - 0.02 for xi in x], full_vals, width,
               bottom=full_bottoms, color=color, edgecolor="black", linewidth=0.3,
               label=name)
        ax.bar([xi + width / 2 + 0.02 for xi in x], cone_vals, width,
               bottom=cone_bottoms, color=color, edgecolor="black", linewidth=0.3)

        full_bottoms = [b + v for b, v in zip(full_bottoms, full_vals)]
        cone_bottoms = [b + v for b, v in zip(cone_bottoms, cone_vals)]

    ax.set_xticks(list(x))
    ax.set_xticklabels(families)
    ax.set_ylim(0, 1.0)
    ax.set_ylabel("fraction of full proof total (mean)")
    ax.set_title("Full (left) vs Cone (right) per family")
    ax.legend(loc="center left", bbox_to_anchor=(1.0, 0.5), fontsize=8, frameon=False)

    fig.tight_layout()
    fig.savefig(out_path, bbox_inches="tight")
    print(f"Written: {out_path}")


if __name__ == "__main__":
    main()
