"""Rewrite self-referencing labelled steps to use numeric formula ids.

Diagnostic for the `veripb trim` label-shadowing bug (docs/veripb-trimmer-label-shadowing-bug.md).
Glasgow emits `@a pol ... @a + s`, where the operand @a is the formula constraint and the
step then rebinds @a. Replacing that operand with its numeric id removes the shadowing and
nothing else, which is what isolates the bug from every other difference between trimmers.

    python3 scripts/deshadow_pbp.py <in.opb> <in.pbp> <out.pbp>

The rewritten proof must still verify — that is the control. `preserved:` and objective
lines are declarations, not constraints, and must not advance the constraint counter.
"""
import sys, re
opb, pbp, out = sys.argv[1:4]
# formula label -> constraint id (1-based over real constraints, skipping comments/objective)
lab2id, cid = {}, 0
for line in open(opb, encoding='utf-8', errors='replace'):
    s = line.strip()
    if not s or s.startswith('*'): continue
    if re.match(r'(min|max|preserved|soft|strengthening|f)\s*:', s): continue
    cid += 1
    if s.startswith('@'):
        lab2id[s.split(None, 1)[0]] = cid
print(f"  formula constraints={cid}  labelled={len(lab2id)}")

n_lines = n_repl = n_miss = 0
with open(out, 'w') as w:
    for line in open(pbp, encoding='utf-8', errors='replace'):
        if line.startswith('@'):
            lab = line.split(None, 1)[0]
            rest = line[len(lab):]
            if re.search(r'(?<![\w@])' + re.escape(lab) + r'(?![\w])', rest):
                if lab in lab2id:
                    rest, k = re.subn(r'(?<![\w@])' + re.escape(lab) + r'(?![\w])',
                                      str(lab2id[lab]), rest)
                    n_repl += k; n_lines += 1
                    line = lab + rest
                else:
                    n_miss += 1
        w.write(line)
print(f"  self-ref lines rewritten={n_lines}  operands replaced={n_repl}  label-not-in-formula={n_miss}")
