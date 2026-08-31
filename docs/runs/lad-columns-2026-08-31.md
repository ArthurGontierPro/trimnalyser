# LAD columns (tab:configs-lad), route 2 — launched 2026-08-31

> **Superseded within the day.** The first launch (below) capped the two proof-logging
> columns to 4247 instances and the other three to 6967, on disk-budget grounds. That
> makes the columns incomparable with Glasgow's 25590, which is the whole point of the
> table. **Relaunched 17:47 UTC on the full 25590, all five columns** — see
> "Full-set relaunch" at the end. The capped instance files are kept in
> `/cluster/arthur/instfiles/` for matched-subset re-aggregation, not for running.

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


---

# Full-set relaunch — 2026-08-31 17:47 UTC

All five columns, **25590 instances each**, `allgraphs`, no instance file. Timeouts and
memory cap identical to the Glasgow grid: `stnopl=60 st=600 tt=6000 vt=6000 ct=6000
maxmem=32`, `--threads 92,1`.

| node | config | | node | config |
|---|---|---|---|---|
| fataepyc-08 | `lad-fc-pl` | | fataepyc-05 | `lad-clique` |
| fataepyc-03 | `lad-alldiff-pl` | | fataepyc-07 | `lad-noclique` |
| fataepyc-04 | `lad` | | | |

`lad-fc-pl` went to fataepyc-08 deliberately: 12 TB free against 8 TB elsewhere, and it is
the heaviest column.

## bio is included and stamped

9303 of the 25590. Previously hard-excluded for every `lad-*` config. bio graphs are
directed; LAD reads them as undirected without warning, and CakePB rejects the encoding, so
the rows are unverifiable and answer a different question than Glasgow's. They now run so
that "all 25590" is true and the table shows a measured cell rather than a gap — but:

- the enumerator announces the count before starting, and
- `runheader` stamps `lad VALIDITY DIRECTED_UNSOUND` inside each bio run block.

**Filter on `lad VALIDITY` when aggregating.** Absence of the marker means "not this
particular unsoundness", never "comparable".

## Disk prerequisites (commit `38742c1`)

Deletion discipline was already correct and complete — solver crash, SAT, timeout,
truncation, last use, and the elaborated proof all delete. Two things were missing:

1. **No bound on peak concurrent disk.** Deletion is per-instance and sequential within an
   instance; nothing looked at what the other 91 threads were holding at that moment.
   `mindisk=` (300 GB on cluster) is the exact analogue of `minmem=` and blocks at the same
   four admission points. Evidence it was needed: the capped run left **494 GB / 482 GB**
   resident on two nodes after 40 minutes.
2. **The `>50 GB` skip branch leaked.** It sits in `prepare_instance`, and
   `run_instance_batch` opens with `prepare_instance(ins) === :ok || return`, so it never
   reached the later `tryrm`s. Every other `:skip` branch deletes first. Fixed at both
   sites.

## Isolated checkout

Runs from `~/trimnalyser-lad`, a second clone at `04182d6` with its own sysimage.
`build_sysimage.jl` hardcodes `trimnalyser.so` in the repo root and offers no override,
and the four live Glasgow NDS columns on nodes 01/02/06/09 have that exact file mmap'd —
so rebuilding in place risked days of their compute, and would also have swapped the code
under a running experiment. Launched with:

```
REMOTE_REPO='$HOME/trimnalyser-lad' SKIP_SYSIMAGE=1 EXTRA=overwrite \
  CONFIGS="lad-fc-pl lad-alldiff-pl lad lad-clique lad-noclique" \
  NODES="fataepyc-08 fataepyc-03 fataepyc-04 fataepyc-05 fataepyc-07" \
  bash scripts/run_grid.sh launch
```

Delete the clone once the Glasgow arm finishes, or it becomes a divergence hazard.

## Smoke tests before launch

- `LVg10g12` / `lad-fc-pl` — unchanged, green through `cakeiso VERIFIED` and resolv fixpoint.
- `bio001002` / `lad-fc-pl` — runs (no longer skipped) and the log carries
  `lad VALIDITY DIRECTED_UNSOUND` directly under the RUN header.
