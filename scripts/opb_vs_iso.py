#!/usr/bin/env python3
"""Compare Glasgow's .opb against cake_pb_iso's own encoding of the same instance.

cake_pb_iso rebuilds the PB encoding from the two LAD graphs and never reads our .opb, so
the only thing that has to agree for it to accept a Glasgow proof is the *constraint
numbering* the proof references. This script answers two questions:

  1. Are the two formulas the same set of constraints?      (multiset equality)
  2. If so, is Glasgow's emission order already iso's?      (id equality)

On LVg10g12 the answer is yes / no: same 7810 constraints, different order. Glasgow emits
@al and @am interleaved per pattern vertex and @adj pattern-major; cake_pb_iso emits
[all @al][all @am][all @inj][@adj target-major]. The permutation is computable from the
labels alone, which is what --show-permutation checks.

Usage:
    scripts/opb_vs_iso.py <glasgow.opb> <pattern.lad> <target.lad> [--cake-pb-iso PATH]
    scripts/opb_vs_iso.py <glasgow.opb> --iso-opb <iso_encoding.opb>

Exit status 0 when the multisets are equal (whether or not the order matches), 1 otherwise.
"""

import argparse
import itertools
import re
import subprocess
import sys
import tempfile
from collections import Counter

# cake_pb_iso's emission order, by label class.
CLASS_RANK = {"al": 0, "am": 1, "inj": 2, "adj": 3}
ADJ_LABEL = re.compile(r"adj(\d+)_(\d+)_(\d+)$")


def parse_opb(path):
    """-> [(canonical_terms, rhs)], [label]. Constraints normalised to >= form with
    negated literals folded away and terms sorted, so two spellings of one constraint
    compare equal."""
    constraints, labels = [], []
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("*") or line.startswith("preserved:"):
                continue
            if ">=" not in line and "<=" not in line:
                continue
            label = ""
            if line.startswith("@"):
                label, _, line = line.partition(" ")
                label = label[1:]
            op = ">=" if ">=" in line else "<="
            lhs, _, rhs = line.partition(op)
            k = int(rhs.strip().rstrip(";").strip())
            toks = lhs.split()
            terms = [(int(toks[i]), toks[i + 1]) for i in range(0, len(toks), 2)]
            if op == "<=":
                terms = [(-c, v) for c, v in terms]
                k = -k
            folded = []
            for c, v in terms:
                if v.startswith("~"):          # c*~x == c - c*x
                    k -= c
                    folded.append((-c, v[1:]))
                else:
                    folded.append((c, v))
            folded.sort(key=lambda t: t[1])
            constraints.append((tuple(folded), k))
            labels.append(label)
    return constraints, labels


def iso_sort_key(label, position):
    """Where cake_pb_iso would place a constraint carrying this label."""
    m = ADJ_LABEL.match(label)
    if m:
        i, j, k = int(m.group(1)), int(m.group(2)), int(m.group(3))
        return (CLASS_RANK["adj"], j, i, k)       # target-major, unlike Glasgow's (i, j, k)
    cls = re.sub(r"\d+$", "", label)
    return (CLASS_RANK.get(cls, 9), 0, 0, position)


def run_encoder(binary, pattern, target):
    out = tempfile.NamedTemporaryFile(mode="w", suffix=".opb", delete=False)
    with out:
        rc = subprocess.run([binary, pattern, target], stdout=out,
                            stderr=subprocess.DEVNULL).returncode
    if rc != 0:
        sys.exit(f"{binary} exited {rc} on {pattern} {target}")
    return out.name


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("glasgow_opb")
    ap.add_argument("pattern", nargs="?")
    ap.add_argument("target", nargs="?")
    ap.add_argument("--iso-opb", help="a pre-generated cake_pb_iso encoding")
    ap.add_argument("--cake-pb-iso", default="cake_pb_iso")
    args = ap.parse_args()

    if args.iso_opb:
        iso_path = args.iso_opb
    elif args.pattern and args.target:
        iso_path = run_encoder(args.cake_pb_iso, args.pattern, args.target)
    else:
        ap.error("give either <pattern> <target>, or --iso-opb")

    gss, gss_labels = parse_opb(args.glasgow_opb)
    iso, iso_labels = parse_opb(iso_path)

    print(f"glasgow : {len(gss)} constraints  {args.glasgow_opb}")
    print(f"iso     : {len(iso)} constraints  {iso_path}")
    print("iso label blocks:",
          [(re.sub(r'\d.*$', '', k), sum(1 for _ in g))
           for k, g in itertools.groupby(iso_labels, key=lambda l: re.sub(r'\d.*$', '', l))])

    same_set = Counter(gss) == Counter(iso)
    print("same constraint multiset:", same_set)
    if not same_set:
        only_gss = Counter(gss) - Counter(iso)
        only_iso = Counter(iso) - Counter(gss)
        print(f"  only in glasgow: {sum(only_gss.values())}, only in iso: {sum(only_iso.values())}")
        for c in itertools.islice(only_gss, 2):
            print("   glasgow:", str(c)[:140])
        for c in itertools.islice(only_iso, 2):
            print("   iso    :", str(c)[:140])
        return 1

    if gss == iso:
        print("same order (ids already agree): True  -- cake_pb_iso can check this proof as is")
        return 0
    print("same order (ids already agree): False")

    order = sorted(range(len(gss)), key=lambda i: iso_sort_key(gss_labels[i], i))
    permuted = [gss[i] for i in order]
    ok = permuted == iso
    print("label-derived permutation reproduces iso's order:", ok)
    if not ok:
        d = next(i for i, (x, y) in enumerate(zip(permuted, iso)) if x != y)
        print(f"  first mismatch at index {d}: "
              f"glasgow label {gss_labels[order[d]]!r} vs iso label {iso_labels[d]!r}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
