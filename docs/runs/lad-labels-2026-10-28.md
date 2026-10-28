# LAD construct labels — instrumenting LAD proofs the way §6 reads Glasgow's (2026-10-28)

**Question.** §6 of the paper (`sections/6-instrument.tex`) counts the label of every proof
step over the full certificate and over the cone, and the gap between the two told us which
Glasgow constructs were written far more than the refutation used (the supplemental layers),
which led to staged preprocessing and lazy supplemental graphs. Can the same reading be made
of LAD? The September columns (`runs-0903/lad-*-pl`) cannot answer it: LAD's model side is
labelled (`@al1/@am1/@inj/@adj`, read as al1/am1/inj/g0adj) but 93 % of its derived steps
carried no label and 100 % of its cone's derived steps were `UNLABELED`. bio is included on
purpose: its LAD runs are `DIRECTED_UNSOUND` as certificates, but the goal here is to observe
the solver, not to certify the instance.

## What changed

- **ladveri `0e8ef31` + `8a98328`** (branch `fix/initdomains-stack-overflow`): every `pol`,
  `rup` and `a` the proof logger emits is prefixed `@lad<construct><n>` (macro `LBL`,
  `proof.c`), `n` from its own counter. The three pre-existing referenceable labels
  `@p2<n>`, `@nds<n>`, `@de<n>` are untouched — the first attempt shared their counter and
  broke the `[base, ctr)` ranges the following pol references (`KeyError: "p21137"` in the
  trimmer, `veri full FAILED`); fixed in the second commit. `proofCtx` is set around the
  two `filterValue` calls in `matchVertices` so a forward-checking elimination says whether
  injectivity or adjacency removed the value.
- **trimnalyser `108db6e`**: `classify_label` routes `lad*` and `p2/nds/de` to 22 LAD
  categories, counted in a `Dict` carried as a new named-tuple field `lad`; `writeout_labels`
  prints `grim LABEL LAD<X> cone/full` only when non-zero; `aggregate_results.jl` appends 44
  columns (`grim_cone_lad*`, `grim_full_lad*`) **at the end** of `CSV_COLUMNS`.
- **`lad-alldiff-lbl`** config key (same flags as `lad-alldiff-pl`), so the big run's blocks
  never become the last block of the published `lad-alldiff-pl` logs.

| label | construct (proof.c) | what it is |
|---|---|---|
| `ladfcinj` / `ladfcadj` | `proofElim` via `matchVertices` | forward-checking removal, by injectivity / by adjacency |
| `ladassert` | any `a` line | unjustified assertion (should be 0) |
| `ladgac` | `proofAllDiffHall` | Régin GAC Hall reason, eager (no conclusion written) |
| `ladmatch` | `proofAllDiffFail` | matching failed: Hall violator |
| `ladp2pol` / `ladp2` | `proofPath2Pol` / `@p2` | paths-of-length-2 reason / its materialised pairwise lemma |
| `ladp2dompol` / `ladp2dom` | `proofPath2Domination` | init paths-2 domination: outer Hall / conclusion |
| `laddegpol` / `laddeg` | `proofDegreeElimLabeled` | degree Hall (saturated) / its materialised unit rup |
| `ladndspol` / `ladndsdeg` / `ladnds` | `proofNDSElim` | NDS threshold Hall / inner degree elims (`@nds`) / conclusion |
| `ladloop` | `proofInitElim` | self-loop mismatch |
| `ladnbrpol` / `ladnbr` | `proofLADFail(Simple)` | the LAD neighbourhood-matching filter: reason / conclusion |
| `ladleaf` / `ladnode` / `ladroot` | `proofRefuteLeaf` / `proofRefute` / `proofRootFail` | refutations |
| `ladbail` / `ladde` | `proofBailout` | pre-search bailouts / edge-count degree elims (`@de`) |

## Checks

- `LVg10g12 / lad-alldiff-pl`: full, smol, cake full, cake smol, cakeiso all VERIFIED, resolv
  to the same 14/41 fixpoint; no `UNLABELED` line at all.
- **Glasgow unchanged**: `LVg10g12 / gss-lazy` under the new code gives label lines, cone and
  proof counts identical to the published `gss-lazy-resolv` block of 2026-10-13 (24 lines,
  `diff` empty).
- **Proofs identical modulo labels**: `sed 's/^@lad[a-z]*[0-9]* //'` on the new proof is
  byte-identical to the old binary's (`bio160109`, `bio116041`); over the 77 sample
  instances certified in both runs, `inp_pbp_nbeq`, `grim_pbp_cone` and `grim_opb_cone`
  equal the September values on 76 (the 77th is a test-directory artefact).

## Preliminary reading — 80 instances, fataepyc-07, 2026-10-28

Sample: 25 LV, 25 meshes, 20 bio, 10 images, drawn from the September rows with
`veri smol VERIFIED`, total size < 300 MB, solve < 120 s (`/scratch/arthur/ladlabels/`:
`sample80.txt`, `run_one.sh`, `results.csv`, `lad_composition.py`). Single-instance mode,
one process per instance, `xargs -P 80`. **Caveat: single-instance mode defaults to
`st=5 vt=45 ct=45 tt=45`**, so 16 instances timed out on verify/cake and 6 resolv loops
stopped on a solver timeout; and 49 of the 77 refutations are *root* refutations (no
search), so the search-time constructs are barely represented. Steps, not bytes.

Over the 77 certified (smol VERIFIED) base instances, summed:

| | full steps | cone steps | kept |
|---|---|---|---|
| model (`@adj` 93 %, rest `al1/am1/inj`) | 48.8 M | 2.09 M | 4.3 % |
| derived, all LAD constructs | 3.54 M | 0.134 M | 3.8 % |

Derived steps by construct (ALL families; full count, share of derived, kept in cone):

| construct | full | share | kept |
|---|---|---|---|
| `laddegpol` (degree Hall reason, saturated) | 1,528,344 | 43.2 % | 5.0 % |
| `ladndsdeg` (degree elims inside NDS) | 1,032,412 | 29.2 % | 2.9 % |
| `laddeg` (materialised unit rup after `laddegpol`) | 495,932 | 14.0 % | **0.0 %** (5) |
| `ladndspol` / `ladnds` | 170,171 / 170,171 | 4.8 % / 4.8 % | 2.0 % / **0.0 %** (11) |
| `ladbail` | 42,171 | 1.2 % | 35.5 % |
| `ladp2pol` / `ladp2` | 38,206 / 34,280 | 1.1 % / 1.0 % | **0 / 0** |
| `ladloop` | 12,744 | 0.4 % | 23 % |
| `ladde` | 5,900 | 0.2 % | 100 % |
| `ladfcadj` / `ladfcinj` | 4,684 / 933 | 0.1 % | **0 / 0** |
| `ladnbrpol` / `ladnbr` | 220 / 220 | | **0 / 0** |
| `ladroot` / `ladleaf` / `ladnode` / `ladmatch` | 49 / 24 / 1 / 6 | | 100 / 96 / 100 / 0 % |
| `ladgac`, `ladassert` | 0 | | |

Two readings already stand out, with the caveat above:

1. **The materialised conclusions are never used.** `laddeg` (496 k steps) and `ladnds`
   (170 k) are the `rup 1 ~x >= 1` written right after a `pol … s` that *already is* that
   unit clause (the saturation leaves exactly `~x_{u,v}`), and the cone takes the pol every
   time: 5 + 11 of 666 k kept. Same for `ladp2` (34 k, 0 kept) and `ladnbr` (220, 0). That
   is ~20 % of LAD's derived steps that are pure duplicates — the exact analogue of what the
   cone-vs-full gap showed for Glasgow, and the first thing to stop writing (or write lazily,
   as the eager/materialise distinction in `PROOF_TODO.md` already frames it).
2. **The derived proof is the initial filtering, not search.** 91 % of derived steps are
   degree/NDS eliminations at init, and the cone keeps 3–5 % of them. Forward checking and
   the LAD filter are nearly absent because this sample is root-refuted; the big run decides
   whether that holds on the instances that do search.

The model side repeats what the September CSVs already said: 93 % of every LAD certificate is
`@adj`, of which the cone keeps 4 %. That is the encoder's choice and cannot change without
losing the `cake_pb_iso` end-to-end claim.

## Pre-existing LAD proof failures, visible again here

11 of the 20 bio instances have `veri full FAILED` + `veri smol VERIFIED`; all 11 were
already FAILED/VERIFIED in `runs-0903` (bio: 3,988 full FAILED of 9,303; LV: 1,120 of 6,667;
images: 2,987). On bio the cause seen here is `pol ;` — an empty paths-2 reason (`@ladp2pol`)
when the directed graph's common-neighbour count disagrees with its edge ids — which VeriPB
rejects and which **crashes the trimmer** (`solvepol_flat!`, `pol.jl:201`, `st[2]` on a
one-token line) on the resolv core (`bio160109.core1`, `bio116041.core1`; exit 1, the
September `trim_failed` stop reason). Per `feedback-trimming-rescue-is-a-solver-bug`: a
masking rate, not a win. The LV/images full failures are not diagnosed here.

## Launching the big run

Everything needed is in place on fataepyc-07 (the booked node):

- labelling binary installed as `/scratch/arthur/lad` (sha256 `1c608339…`; the previous
  `9a4afad9…` kept as `/scratch/arthur/lad.9a4afad`);
- trimnalyser at `108db6e`+ on the cluster checkout, `lad-alldiff-lbl` in `SOLVER_CONFIGS`;
- `run_grid.sh` rebuilds the sysimage itself (nothing else runs on the node).

From the laptop:

```
CONFIGS="lad-alldiff-lbl" NODES="fataepyc-07" EXTRA="mindisk=3000" bash scripts/run_grid.sh launch
```

Same limits as every published column (`stnopl=60 st=600 tt=6000 vt=6000 ct=6000 maxmem=32`),
`allgraphs rand`, i.e. the full 25,590 including bio and images. Expect days on images and
a large peak disk (LAD has no deletions). Afterwards:

```
julia scripts/aggregate_results.jl /scratch/arthur/proofs/lad/lad-alldiff-lbl lad-alldiff-lbl.csv /cluster/arthur/logs
python3 /scratch/arthur/ladlabels/lad_composition.py lad-alldiff-lbl.csv
```
