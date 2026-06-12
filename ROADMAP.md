# TrimAnalyser — Research Roadmap

TrimAnalyser currently supports the LV and BIO benchmark families, extracts UNSAT cores via the resolv loop, and outputs a 45-column CSV per run. The roadmap below turns that foundation into a systematic study of proof structure and subgraph isomorphism heuristics, ending with upstream solver patches.

Milestones are strictly ordered: M1–M2 produce the data that M3–M6 consume.

**Status as of 2026-06-12:** M1, M2, and M2.5 complete. M3 is current (first-pass manual analysis done for LV, bio, images-CVIU11, meshes-CVIU11; phase/scalefree/si pending targeted re-run).

---

## M1 — Full newSIP benchmark coverage ✅

**Goal:** Run TrimAnalyser on all 9 families in the newSIP benchmark, not just LV and BIO.

All families use the same LAD graph format (`first line = node count; subsequent lines = degree n1 n2 ...`), so no parser changes are required. The only work is instance enumeration and path resolution in `src/orchestrator.jl`.

| Family | Layout | Pairing rule |
|--------|--------|-------------|
| images-CVIU11 | `images-CVIU11/patterns/patternN` + `…/targets/targetN` | match by N |
| images-PR15 | `images-PR15/patternN` (targets TBD) | match by N |
| meshes-CVIU11 | `meshes-CVIU11/patterns/patternN` + `…/targets/targetN` | match by N |
| phase | `phase/*-pattern` + `phase/*-target` siblings | pair by base name |
| scalefree | `scalefree/A.NN/pattern` + `scalefree/A.NN/target` | one pair per directory |
| si | `si/<group>/<instance>/pattern` + `…/target` (deeply nested) | one pair per instance dir |

**Deliverable:** `./trimnalyser --threads 192,1 solve resolv verif allgraphs` runs across all families; results land in the CSV with a new `family` column for stratified analysis.

---

## M2 — Proof-to-feature extraction ✅

**Goal:** Enrich the CSV with proof-structural and graph-structural features to power downstream analysis (M3 clustering).

### Proof features (extend `src/output.jl`)

**Step composition**
- `rup_frac`, `pol_frac`, `ia_frac`, `red_frac` — fraction of each step type in the trimmed proof

**Cone depth distribution** (beyond max/mean — encodes proof *shape*)
- `cone_depth_max`, `cone_depth_mean` — range and centre
- `cone_depth_p50`, `cone_depth_p90` — where is most of the work?
- `cone_depth_entropy` — Shannon entropy of the per-depth step counts; low = concentrated (ladder/chain), high = spread (wide pyramid)
- `cone_bottom_frac` — fraction of PBP steps at depth ≤ 2; high means almost all reasoning is direct propagation from axioms, low means deep multi-step inference chains
- `cone_bottleneck_depth` — shallowest depth band where step count drops below a threshold (≤ 5); measures the "waist" of the proof DAG, i.e. the minimum cut depth

**Cone width distribution** (shape orthogonal to depth)
- `cone_width_max` — peak number of steps at any single depth
- `cone_width_cv` — coefficient of variation of per-depth counts; near-zero = uniform ("ladder" as in LVg15g20), high = spiky ("multi-wave" as in bio083147)

**RUP / POL depth profiles** (proof strategy fingerprint)

The interplay between RUP and POL across depth levels encodes the solver's proof strategy:
- *pure RUP*: all propagation, no algebraic derivation needed
- *POL bottom-heavy*: algebraic warm-up near axioms, then propagation cascades up
- *POL top-heavy*: propagation first, algebraic reasoning closes the final gap
- *interleaved*: alternating derivation and propagation bursts throughout

Features:
- `rup_depth_cv` — coefficient of variation of RUP step counts across depth bands; near-zero = RUP concentrated at one level (a burst), high = spread uniformly
- `pol_depth_mean`, `pol_depth_cv` — centroid and spread of POL in depth space
- `pol_depth_frac_bot` — fraction of POL steps in the bottom depth quartile (warm-up pattern indicator)
- `pol_depth_frac_top` — fraction of POL steps in the top depth quartile (closing pattern indicator)
- `pol_ante_mean`, `pol_ante_max` — average and max antecedent count per POL step; measures how heavy each algebraic derivation is (accessible directly from `systemlink` for k>0 steps)
- `pol_opb_frac` — fraction of POL antecedents that are OPB axioms vs derived steps; low value means POL is building on a chain of prior derivations, not directly on axioms
- `pol_before_rup_burst` — boolean: does any depth band contain a POL step immediately followed at depth+1 by a RUP count > 5× the per-depth mean? Captures the "POL unlocks propagation" pattern

**Compression and weakening**
- `literal_weakening_rate` — `(cone_literals − smol_literals) / cone_literals`

**Resolv loop**
- Shrinkage curve: per-iteration `(core_pattern_nodes, core_target_nodes)` — expose fully
- `resolv_pat_shrinkage`, `resolv_tar_shrinkage` — total fractional reduction
- `fixpoint_reason` — `stabilized` vs `iter_cap`

### Graph features (new `scripts/graph_features.jl`)

Split into **per-graph** properties (computed once per LAD file, joined by instance) and **per-instance relational** properties (pattern vs target ratios, computed at pair level). The relational features are the primary predictors of SIP hardness.

**Per-graph (prefix `pat_` / `tar_`)**
- `nodes`, `edges`, `density`
- Degree sequence: `deg_min`, `deg_max`, `deg_mean`, `deg_var`
- `diameter`, `radius` (BFS)
- `clustering`, `triangles`
- `girth` — length of shortest cycle; governs how tight cycle-based domain filtering is
- Flags: `regular`, `bipartite`, `planar`

**Per-instance relational** (pattern ÷ target)
- `node_ratio` = `pat_nodes / tar_nodes` — how tight is the embedding problem
- `density_ratio` = `pat_density / tar_density` — sparse-in-dense vs equal-density
- `max_degree_ratio` = `pat_deg_max / tar_deg_max` — degree headroom
- `diameter_ratio` = `pat_diameter / tar_diameter`
- `degree_compat_frac` — fraction of pattern nodes whose degree ≤ `tar_deg_max`; the simplest necessary condition for a valid mapping; values near 1 = structurally compatible, values < 1 = trivially UNSAT from degree alone

**Deliverable:** CSV grows by ~35 columns; `analyze_results.py` and `quick_stats.py` updated to display them.

### Proof-cone visualisation (bonus, already partially done)

DOT files (`cone.hist`, `cone.bfs`, `cone.topk`) are written per instance. The hist variant is the most analytically useful — it shows the per-depth step-count profile with step-type breakdown. The DAG variants (bfs, topk) are hard to read at scale; their main use is manual inspection of specific outlier instances.

---

## M2.5 — Pipeline timeout correctness

**Goal:** Give each phase (`st`/`tt`/`vt`) a semantically correct, independent time budget. Required before the next large cluster run: `st=180 tt=6000` with resolv currently puts all iterations and verif under a shared `tt`, making the individual budgets meaningless.

### Current problem

One subprocess handles solve + trim + verif + the entire resolv loop under a single outer `timeout tt julia`. `vt` does not exist — VeriPB borrows `tt`. Each resolv iteration consumes the same shared budget.

### Target architecture

Two external binaries (solver, verifier) plus one Julia subprocess strictly for trimming:

```
orchestrator — per instance (and per resolv iteration):
  1. clear ins.out / ins.err
  2. run solver      [timeout st sipsolver ...]      external binary, orchestrator thread
  3. spawn subprocess [timeout tt julia]             Julia GC isolation, trim-only
  4. run verif       [timeout vt veripb ...]          external binary, orchestrator thread
  if graph reduced and resolv → loop from step 2 with core_ins
```

| Phase | Timeout | Runs as |
|-------|---------|---------|
| Solve | `st` | external binary, orchestrator thread |
| Trim  | `tt` | Julia subprocess (one independent GC heap per instance) |
| Verif | `vt` (default = `tt`) | external binary, orchestrator thread |

Only the trimmer needs a subprocess — it is Julia code and must have an isolated GC heap to avoid stop-the-world pauses across concurrent instances. Solver and verifier are external binaries with no Julia GC involvement.

### `.out` file interaction

Each instance has two append-only logs: `<ins>.out` for the base instance, `<ins>.coreN.out` for each resolv core. Writes within one file are strictly sequential:

**`<ins>.out`** (base instance):
1. **Orchestrator** clears it before starting
2. **Solver** (orchestrator): appends solver stats (`pattern_vertices`, `runtime`, `status`, ...)
3. **Trim subprocess**: appends parse/trim/write times, cone stats, step types, depth distribution
4. **Verifier** (orchestrator): appends `veri smol VERIFIED` or `veri smol NOT VERIFIED` and time
5. **Resolv loop** (orchestrator): appends `resolv ITER 0 PAT X TAR Y` before iterating, then `resolv ITER N ...` and `resolv STOP reason` between core iterations

**`<ins>.coreN.out`** (one per resolv iteration):
- Same structure as above (steps 1–4) but scoped to the core instance

No locking needed — the orchestrator and subprocess never write to the same file concurrently.

### Implementation plan

**`src/config.jl`**
- Add `veriftimeout::Int` (`vt=`, default = `trimtimeout`)

**`src/pipeline.jl`**
- `trimnalyseandcie` becomes trim-only: remove solve call, remove verif call, remove resolv call, remove smol cleanup, remove `.out`/`.err` clearing (moves to orchestrator)
- Subprocess exits after: parse + trim + write + raw `.opb`/`.pbp` cleanup + core LAD file writing (triggered by `_cfg[].resolv`, still forwarded as subarg)

**`src/solver.jl`**
- `runsipsolver`: unchanged, called from orchestrator
- `resolvecore`: removed — loop moves to orchestrator

**`src/orchestrator.jl`**
- Per-instance logic gains: `.out`/`.err` clearing; solve call; SAT/timeout/OOM detection after solve; smol cleanup and `.done` after verif
- Resolve loop added: write `resolv ITER 0` baseline; loop spawning trim subprocesses and running verif per core; write `resolv STOP` at fixpoint
- Solve resume check moves here: skip solver if `.opb`/`.pbp` already exist with valid conclusion
- Single-instance interactive path: run solve → `trimnalyse` inline (no subprocess, no `tt` wall) → verif → resolv loop

### Constraints
- Single-instance interactive mode has no hard trim timeout — user is at terminal, acceptable
- **OOM monitor will no longer watch the solver**: Glasgow now runs in an orchestrator thread, not a subprocess; the monitor only finds processes with `trimnalyser.jl` in their cmdline. A memory-runaway solver will not be caught. Glasgow is typically memory-light so this is acceptable, but worth noting.
- Trim subprocess still writes core LAD files via `writeunsatcore` — orchestrator reads them after subprocess exits to decide whether to iterate

**Deliverable:** `./trimnalyser --threads 92,1 solve resolv verif allgraphs st=120 tt=3600 vt=600` gives each instance 120 s to solve, 3600 s to trim, and 600 s to verify, independently per resolv iteration.

---

## M3 — Graph taxonomy and heuristic fingerprinting 🔜 CURRENT

**Goal:** Characterise which graph families and structural properties predict proof difficulty and solver behaviour.

### First pass — manual analysis (complete for LV, bio, images-CVIU11, meshes-CVIU11)

Full write-up lives in `paper/notes.tex`. Quick section map:
- Benchmark family descriptions: `notes.tex §3` (§3.1 LV, §3.2 Bio, §3.3 Images-CVIU11, §3.4 Meshes-CVIU11)
- Proof fingerprints per family: `notes.tex §4` (§4.1–§4.4)
- Structural drivers (graph → proof shape): `notes.tex §5` (`\label{sec:drivers}`)
- Solver heuristic implications: `notes.tex §6` (`\label{sec:solver-heuristics}`)
- Open questions: `notes.tex §7` (`\label{sec:open}`)

**Key finding: images-CVIU11 vs meshes-CVIU11** (`notes.tex §3.3–§3.4, §4.3–§4.4`)

Both families come from Damiand & Solnon, *Computer Vision and Image Understanding* 2011 (submap isomorphism paper). The graphs model different things:
- **images-CVIU11**: region adjacency graphs from segmented 2D images — irregular, variable degree
- **meshes-CVIU11**: adjacency graphs from 3D mesh combinatorial maps — regular, bounded degree (~4–6)

| Feature | images-CVIU11 | meshes-CVIU11 |
|---|---|---|
| avg `grim_pbp_cone` | **146 898** | 12 947 |
| avg `grim_opb_cone` | 82 249 | **101 049** |
| `ia_frac` | **~50%** | ~0% |
| `pol_frac` | ~50% | **~100%** |
| avg `cone_depth_max` | **93.6** | 2.0 |
| `cone_depth_entropy` | **2.18** | 0.01 |
| `cone_bottom_frac` | 0.655 | **1.000** |
| `pol_ante_mean` | 5.45 | **15.97** |
| `pol_opb_frac` | 0.83 | **1.00** |
| `pol_before_rup_burst` | **72%** | ~0% |
| `resolv_pat_shrinkage` | 0.13 | **0.38** |

**Mesh proof shape — "single-wave algebraic certificate":** Regular bounded-degree topology means UNSAT is certified by a direct POL combination of ~16 original OPB constraints. Depth ≈ 1, pure POL, OPB-heavy, no propagation chain needed.

**Image proof shape — "propagation cascade":** Irregular adjacency structure forces Glasgow to propagate domain reductions step by step. Each domain reduction is recorded as a `pol ; ia @prev_pol ax+by>=c ; del @prev_pol` triplet (IA = "implied and add"). These chain into a deep proof DAG (max depth 93). PBP-heavy, 50% IA, `pol_before_rup_burst` in 72% of instances.

**Core shrinkage difference:** Mesh conflicts are topologically local (a compact substructure), so resolv isolates them easily (shrinkage 0.38). Image conflicts are spread across the irregular adjacency, harder to localize (shrinkage 0.13).

Key structural drivers (`notes.tex §5`):
- **Width–depth tradeoff**: pol_ante_mean and cone_depth_max are inversely correlated across families; dense graphs produce wide shallow proofs, sparse graphs produce narrow deep proofs.
- **Clustering → proof flatness**: high clustering (meshes: 0.325) enables flat one-wave algebraic certificates; zero clustering (bio) forces deep IA chains.
- **Node ratio → resolv effectiveness**: images (ratio 0.026, shrinkage 0.129) vs LV (ratio 0.30, shrinkage 0.495).

### Targeted re-run — phase, scalefree, si (`notes.tex §7 item 1`)

The current cluster run used `st=18 tt=600`, which is too tight for these harder families: phase (150-node target), scalefree (200-node target), si (200-node target). They are under-represented in the CSV (phase: 106, scalefree: 60, si: 605 rows) and most likely timed out before producing cone data.

Planned re-run (cluster only, not local — these instances require a proof run):
```bash
./trimnalyser --threads 92,1 solve resolv verif allgraphs minnodes=0 maxnodes=250 st=120 tt=3600 rand
```
Then re-aggregate and re-run `proof_survey.jl` to extend family profiles to all 8 families.

### Open questions for M3 completion (`notes.tex §7`)

- **Two-axis proof-structure classifier** (§7 item 2): `cone_depth_entropy × pol_frac` as the primary axes. `ia_frac` separates families well today but is coupled to the IA proof step, which may be eliminated in a future Glasgow proof format revision. `pol_frac` is a more robust substitute — it captures the same algebraic-vs-propagation axis and will remain valid after IA removal.
- **Images-CVIU11 coverage** (§7 item 6): only ~17% of instances have cone data. Determine the exact SAT / timeout / memout split from the status column before attributing this to graph structure.
- **Intra-family scaling laws** (§7 item 3): does proof size scale as $O(|V(P)|)$, $O(|V(T)|)$, or $O(|V(P)| \cdot |V(T)|)$ within each family? Relevant for setting cluster timeout budgets.
- **Bio bipartite structure** (§7 item 4, see TODO in `notes.tex §3.2`): 56% of bio pattern graphs are bipartite; a dedicated experiment exploiting bipartiteness in solver and trimmer.
- **Intra-LV sub-fingerprinting** (§7 item 5): `pat_deg_var` and `pat_is_bipartite` as axes that stratify LV into distinct sub-fingerprints.
- **Formal width–depth tradeoff** (§7 item 7): characterise the inverse relationship between `pol_ante_mean` and `cone_depth_max` in Glasgow proof terms.

Tools: `scripts/proof_survey.jl` HTML report + `paper/notes.tex` for written analysis.

### Second pass — automated clustering

- Cluster instances by `(graph_features, proof_features)` using k-means or hierarchical clustering; primary axes are `cone_depth_entropy` and `pol_frac` (see open question on two-axis classifier above)
- Visualise clusters in the HTML report (PCA or t-SNE projection)
- Identify the most discriminating features per cluster

**Depends on:** targeted phase/scalefree/si re-run above (extend the feature space before clustering).

**Deliverable:** A taxonomy document — cluster descriptions, representative instances, identifying features. Also: scalability plots of proof size and core shrinkage vs node count within each family, to guide `maxnodes` cutoffs on the cluster.

---

## M4 — Multi-axis heuristic learning

**Goal:** Learn which Glasgow configuration performs best for each cluster.

Grim is established as the best **trimming** heuristic and is fixed. The open question is the **solver** configuration: which Glasgow flags best match each proof fingerprint class.

### Heuristic dimensions

From the M3 proof fingerprints, two axes are the primary levers:

**Variable ordering** — which pattern vertex to branch on next:
- Most-constrained domain (standard)
- Degree-based (branch on highest-degree pattern vertex first)
- Graph-topology order (BFS from a high-betweenness seed — predicted useful for bio-like long-diameter instances)

**Preprocessing / propagation ordering** — how aggressively to reduce domains before and during search:
- Degree-based domain filtering: eliminate pattern vertices whose degree exceeds target max-degree (fast-paths ~19% of LV instances trivially; less relevant for images/bio)
- Triangle-aware propagation: enforce triangle-neighbourhood constraints jointly (predicted highly effective for mesh-like families given clustering 0.325; irrelevant for bio which has zero clustering)
- Supplemental graphs (`--no-supplementals`): controls auxiliary constraint propagation

**Family-specific predictions from M3** (hypotheses to test in M4 A/B evaluation; see `notes.tex §6` for rationale):

| Family class | Predicted best axis | Predicted ineffective |
|---|---|---|
| Mesh-like | Preprocessing first; triangle propagation | Variable ordering, deep search |
| LV-like | Degree pre-check + global neighbourhood propagator | Fine-grained variable ordering |
| Image-like | Variable ordering (most-constrained first) | Triangle propagation (low clustering) |
| Bio-like | BFS variable ordering from bottleneck vertex; multi-iter resolv | Degree pre-check (trivially compatible) |

### A/B testing framework (`scripts/heuristic_eval.jl`)

1. Takes a list of Glasgow flag combinations
2. Runs each on a benchmark subset (short timeout, ~10 s)
3. Collects solve time, node count, propagation count
4. Outputs a per-instance × per-config performance matrix

### Learning

- **Manual rules first:** use cluster profiles to hand-write a config selector (e.g. "if density > 0.15 and family = phase, use X")
- **Decision-tree model second:** train on cluster × config → performance; interpretable and auditable
- Cross-validate across families to measure transfer

**Deliverable:** A config-selector script that maps graph features → recommended Glasgow flags, evaluated by solver nodes and time on held-out instances.

---

## M5 — Cross-solver comparison

**Goal:** Establish whether the learned heuristics improve Glasgow, and whether other solvers benefit from the same insights.

**Baseline:** Glasgow (default) vs Glasgow (heuristic-selected) across all families.

**Comparison solvers:** Glasgow, RI, and at least one of VF2 / McSplit — exact set determined by integration effort.

**Protocol:** Fixed 180 s timeout; measure solved-instance count and PAR-2 score; stratify by family and cluster to identify where each solver excels and whether heuristics flip any rankings.

**Deliverable:** Summary comparison table + new `analyze_results.py` dashboard panel for cross-solver results.

**Key scientific question (heuristic transfer audit):** Do heuristics learned on LV generalise to phase / scalefree / si? This deserves a dedicated evaluation since it is the main transferability claim.

---

## M6 — Integration into solvers

**Goal:** Incorporate validated heuristics upstream.

### Glasgow (patch)

- Identify hooks for variable ordering, supplemental selection, and preprocessing level in the Glasgow source
- Add a lightweight graph-feature probe (computed before search) that selects the heuristic config at startup
- Submit as a Glasgow PR or maintain as a local patch

### Other SIP solvers (RI, VF2)

- Map heuristic dimensions to the equivalent knobs in each solver
- Adapt the config-selector to emit the correct flags per solver
- Benchmark to confirm gains transfer

**Deliverable:** Patched solver binaries (or config wrappers) that outperform defaults on the full newSIP benchmark suite.

---

## Dependency graph

```
M1 (benchmark coverage)
  └─ M2 (feature extraction)
        ├─ proof-cone visualisation
        ├─ scalability analysis
        └─ M3 (taxonomy: manual → clustering)
              └─ M4 (heuristic learning + A/B eval)
                    └─ M5 (cross-solver comparison)
                          ├─ heuristic transfer audit
                          └─ M6 (solver integration)
```
