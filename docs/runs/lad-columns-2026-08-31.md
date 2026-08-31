# LAD columns (tab:configs-lad), route 2 — launched 2026-08-31

First real measurement of the five `lad-*` columns. Everything previously in
`/cluster/arthur/logs/*.lad.*.out` was debugging output from 2026-08-24 15:00–16:37,
written *before* the `<=` parser fix landed at 16:47 — exactly one run block in the whole
tree postdates it. Those numbers were never a benchmark and are superseded here.

## What runs where

| node | config | proves | instance set |
|---|---|---|---|
| fataepyc-03 | `lad-fc-pl`      | yes | `lad_pl.txt`    (4247) |
| fataepyc-04 | `lad-alldiff-pl` | yes | `lad_pl.txt`    (4247) |
| fataepyc-05 | `lad`            | no  | `lad_nolog.txt` (6967) |
| fataepyc-07 | `lad-clique`     | no  | `lad_nolog.txt` (6967) |
| fataepyc-08 | `lad-noclique`   | no  | `lad_nolog.txt` (6967) |

Nodes 01, 02, 06, 09 were left alone — the Glasgow NDS arm is still running on them.

## Why two instance sets

`/cluster/arthur/instfiles/lad_nolog.txt` — LV + phase + scalefree, 6967 instances
(6667 + 200 + 100), i.e. the enumerated 25590 minus the families that are excluded:

- **`bio` (9303)** — directed graphs. LAD reads them as undirected without warning and
  CakePB rejects them outright; `orchestrator.jl` drops them for any `lad-*` config anyway.
  Marked † in the table.
- **`cviu11` (6278), `mesh11` (3018), `pr15` (24)** — images and meshes. LAD proofs carry
  no deletions and grow with search length. Marked ‡; ROADMAP is explicit: do not schedule.

`/cluster/arthur/instfiles/lad_pl.txt` — the 4247 LV pairs, which is the set the paper's
proof-logging column is restricted to under a 250 MB encoder cap. Uncapped LV alone
projects to 10.4 TB of proof, so the two `proves=true` columns must not run the full 6967.
The list is the distinct `lad-pl` instances of
`~/ladveri/proof/bench/results/2026-08-17-pl-LV.csv`, so route 2 measures exactly the
instances route 1 already has data for and the two are directly comparable.
All 4247 names were checked to resolve against the enumerated set.

## Preconditions verified before launch

- `lad`, `veripb`, `cake_pb`, `cake_pb_iso` present on all five nodes, byte-identical to
  `/cluster/arthur/dist/MANIFEST` (`lad` = `9a4afad90a07`).
- `lad` accepts `-O` — the cluster's `~/ladveri` is on `fix/initdomains-stack-overflow`
  at `2a9884b`, **not** master. A master build has no `-O` and every `*-pl` config then
  dies with `invalid option -- 'O'`, reported as a solver timeout.
- All five configs smoke-tested on `LVg10g12` at scale 60. Both proof-logging configs run
  green end to end including `cakeiso VERIFIED` (the trusted end-to-end claim) and resolv
  to fixpoint at 41 → 14 pattern nodes. The three no-logging configs stop at the tier-1
  solve by design and report `UNSAT 0.1s (no-logging config)`; their cell is that solve.
- `SKIP_SYSIMAGE=1` was used deliberately: `$HOME` is shared NFS, the four live Glasgow
  columns have `trimnalyser.so` mapped, and only shell scripts changed. The smoke tests
  are the verification that the existing image is good.

## Results

_(to be filled after the run)_
