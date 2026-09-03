# Grid restart, 2026-09-03

All six in-flight columns were stopped, their scratch cleared, and relaunched at `f70d02c`.
The 2026-09-01 launch had to be abandoned: raw proofs leaked on every failure path, which
filled two 13 TB volumes and stalled one column outright.

## Why

Deletion of the raw `.pbp`/`.opb` was written per-branch, so each early return had to
remember it. Measured on fataepyc-09 before the fix: **2427 of 2438 raw `.pbp` older than
12 h were held open by no process at all** — their instances had finished and the proof
stayed. Three paths leaked, all now covered by a `finally` (see the commit message of
`f70d02c` for the full account).

Consequence on fataepyc-03 (`lad-alldiff-pl`): 6.49 TB of orphans plus a finished column's
3.17 TB left the disk at 78 %, so `mindisk=3000` could never be satisfied. Every instance
waited its 1800 s and was skipped and the column produced **zero `.out` files in ~24 h**.

This also answers the question `tab:configs-lad`'s caption still leaves open — *"why it
exhausted a 13 TB volume at ninety-two-way concurrency is not yet established"*. It was not
concurrency. Failed instances never released their proofs. **The caption needs rewriting.**

Separately, `lad-fc-pl` on fataepyc-08 died at 2026-09-01 15:47 with `signal 7 (2): Bus
error`. `$HOME` is one NFS mount shared by all nine nodes, so `trimnalyser.so` is a single
file mmap'd by every running orchestrator; rebuilding it under a live process destroys the
mapping. Rebuild once, with everything stopped, before launching — which is what
`run_grid.sh` already does.

## What was cleared

Kept in each active config's directory: `*.done`, `*.sat`, `*.timeout<N>`, `*.memout<N>`.
Everything else went, plus `vis/`, plus every other config's tree outright — the logs are on
shared `/cluster/arthur/logs`, so a proof tree holds no measurement.

| node | column | before | after | sentinels kept |
|---|---|---|---|---|
| fataepyc-03 | `lad-alldiff-pl`      | 9.0T (78%) | 317M (1%) | 9 136 |
| fataepyc-04 | `gss-lazy-nosupp`     | 4.1T (35%) | 320M (1%) | 14 136 |
| fataepyc-05 | `gss-lazy-nostaged`   | 8.5T (74%) | 320M (1%) | 17 431 |
| fataepyc-07 | `gss-lazy-norestarts` | 6.5T (56%) | 422G (4%) | 20 014 |
| fataepyc-08 | `lad-fc-pl`           | 1.4T (12%) | 316M (1%) | 386 |
| fataepyc-09 | `gss-lazy-cliques`    | 3.2T (28%) | 318M (1%) | 6 009 |

Two traps worth remembering. `find`'s `-regextype` must precede any `-regex` and must not
sit under `!` — a negated one silently matches nothing, and the first dry run reported
"DROP 0 files" while 91 484 were droppable. And fataepyc-07 alone still held a
**pre-namespacing tree directly in `/scratch/arthur/proofs/`** (3.52 TB of pairs, last
written 2026-08-21) that a `<solver>/<config>/` walk never reaches; its 40 417 `.out` files
predate the move of logs to `/cluster` and were kept.

## The relaunch

Launched **without `overwrite`**, which is the whole difference between a resume and a
from-scratch run: `overwrite` bypasses every sentinel. Glasgow columns via `run_grid.sh`
with the default `EXTRA`; LAD columns with `REMOTE_REPO='$HOME/trimnalyser-lad'` and
`EXTRA="mindisk=3000"`. Both LAD columns run `allgraphs rand`, so the full 25 590 including
images and meshes.

Resume took, as reported by the new sentinel index:

| column | timed-out skipped | OOM skipped |
|---|---|---|
| `gss-lazy-nosupp`     | 938  | 129  |
| `gss-lazy-norestarts` | 1299 | 3225 |
| `gss-lazy-cliques`    | 461  | 587  |
| `lad-alldiff-pl`      | 7766 | 386  |

(`.done`/`.sat` skips are silent, per-instance; on fataepyc-04 they are roughly 13 000 more.)

First hour after launch, raw proofs track concurrency rather than accumulating — 67–126
`.pbp` against 47–115 in-flight solvers, disks at 1–4 %. That is the signature the fix was
meant to produce.

## Open issues

1. **`tab:configs-lad` caption is now wrong.** It reports the 13 TB exhaustion as
   unexplained. It was the proof leak. Rewrite when the columns land.
2. **~2 % of instances carry no sentinel** — concluded but failed to certify (fataepyc-07:
   20 372 attempted, 19 959 settled). They are redone on every restart. A
   `.trimfail`/`.nocert` sentinel was deliberately *not* added: a slightly-wrong skip
   sentinel permanently drops instances from a table cell, which is the trap the
   `.memoutNNN` note warns about, and 2 % rework is cheaper than that risk.
3. **`gss-lazy-cliques` still hits `rup failed`.** One occurrence in the first hour,
   cascading into ~2000 `del index is 0` lines from that single instance — the documented
   chain (half-built cone leaves `index == 0`, `writepol` emits `pol 0 0 + ...`). Not
   column-wide: 50 smol VERIFIED, 0 FAILED over the same window. This is the known
   `@binback` path, reachable only with clique detection on, and still unfixed on every
   Glasgow branch.
4. **`~/trimnalyser-lad` is a second checkout of the same branch.** It exists so a Glasgow
   sysimage rebuild cannot SIGBUS a LAD column, which is a real reason to keep it — but it
   was three commits behind on 2026-09-03 and had to be fast-forwarded by hand. It is shared
   between fataepyc-03 and -08, so those two must be stopped together for any rebuild.
5. **fataepyc-01/02/06 carry the same leak's residue** from the NDS-rerun columns:
   `gss-nosupp-nds` (825 G), `gss-proof-nds` (7.6 T, node at 67 %), `gss-cliques-nds`
   (1.6 T). Those columns are finished and their logs are on `/cluster`, so the trees are
   droppable whenever a node is needed.
