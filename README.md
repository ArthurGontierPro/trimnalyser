# TrimAnalyser

PB proof trimmer for the Glasgow Subgraph Isomorphism Solver. Reads `.opb` + `.pbp` proof pairs, extracts the minimal proof cone, optionally re-solves on the UNSAT core to shrink the problem further, and writes `.smol.opb` + `.smol.pbp` output files.

---

## Prerequisites

- Julia 1.10+
- [`DataStructures.jl`](https://github.com/JuliaCollections/DataStructures.jl) (installed automatically via `Pkg`)
- Glasgow Subgraph Solver binary (only needed for `solve`/`resolv` modes)
- VeriPB (only needed for `verif` mode)

---

## Setup

Instantiate the package once to download dependencies:

```bash
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

---

## Configuration

Four environment variables control the external tool and data paths. The built-in defaults cover Arthur's laptop and the Glasgow cluster; anyone else sets the relevant variables in their shell config:

```bash
# path to the glasgow_subgraph_solver binary (needed for solve/resolv)
export GLASGOW_SUBGRAPH_SOLVER=/path/to/glasgow_subgraph_solver

# path to the VeriPB binary (needed for verif)
export VERIPB=/path/to/veripb

# base directory — proofs/ subdirectory and output.log are written here
export TRIMNALYSER_BASE=/path/to/working/dir/

# benchmark graph directory — only needed for allgraphs mode
export TRIMNALYSER_GRAPHS=/path/to/benchmarks/
```

Unset variables fall back to the compiled-in defaults. You only need to set the ones that differ from the defaults.

---

## Invocation

```bash
./trimnalyser [julia-flags...] [trimnalyser-flags...] [instance | proofs_dir]
```

The shell wrapper auto-detects a sysimage and handles project activation — no `--project` needed. Pass Julia flags like `--threads` before trimnalyser flags:

```bash
./trimnalyser --threads 8,1 LVg10g12 resolv
```

---

## Workflows

### 1 — Trim a single instance

Proof files must exist at `<proofs_dir>/<instance>.opb` and `<proofs_dir>/<instance>.pbp`.

```bash
./trimnalyser LVg10g12
```

By default the proofs directory is `<abspath>/proofs/`. Pass an explicit directory as any argument that `isdir()` returns true for:

```bash
./trimnalyser /path/to/proofs/ LVg10g12
```

Output: `LVg10g12.smol.opb` + `LVg10g12.smol.pbp` in the proofs directory.

Re-trim even if `.smol` files already exist:

```bash
./trimnalyser LVg10g12 overwrite
```

### 2 — Trim + UNSAT-core re-solve loop (`resolv`)

```bash
./trimnalyser LVg10g12 resolv
./trimnalyser LVg10g12 overwrite resolv   # re-run from scratch
```

Implies `core`. Requires the Glasgow solver binary at the configured path.

#### How the loop works

After trimming the original proof, the trimmer extracts which pattern and target nodes actually appear in the cone (the UNSAT core). It then writes a reduced LAD graph containing only those nodes and re-runs the solver on it. Because the input is smaller, the new proof is often shorter and itself more trimmable. The loop repeats until the extracted core stops shrinking.

Concretely, for `LVg10g12`:

```
trim LVg10g12
  → vis/LVg10g12.pat.dot/.svg      full original graph, core nodes in green
  → vis/LVg10g12.tar.dot/.svg
  → vis/LVg10g12.core.pat.lad      induced subgraph on core nodes (input to next solver run)
  → vis/LVg10g12.core.tar.lad

run solver on core.lad → LVg10g12.core1.opb + .pbp
trim LVg10g12.core1
  → vis/LVg10g12.core1.pat.dot/.svg    core1 graph, with its own trimmed core in green
  → vis/LVg10g12.core1.tar.dot/.svg
  → vis/LVg10g12.core1.core.pat.lad   input to next solver run
  → vis/LVg10g12.core1.core.tar.lad

run solver on core1.core.lad → LVg10g12.core2.opb + .pbp
trim LVg10g12.core2
  → vis/LVg10g12.core2.*
  ...
```

**`coreN`** is the proof generated at iteration N; its input graph was the core extracted from iteration N−1's proof. The `.pat.dot` at each step shows that iteration's input graph with the nodes needed by the *next* trim highlighted in green — so the green region shrinks monotonically as the loop converges.

**Fixpoint:** the loop stops when the newly extracted core has the same node count as the core it was given. The terminal `.core.pat.lad` is deleted at that point. "fixpoint after 0 iterations" means the original proof's core covers the full graph — the solver was never re-run.

### 3 — Run the solver first, then trim (`solve`)

When proof files do not exist yet (fresh instance): run the solver to generate the proof, then trim it.

```bash
./trimnalyser LVg10g12 solve
./trimnalyser LVg10g12 solve resolv   # solve + resolv loop
```

### 4 — Trim all instances in a directory (batch mode)

Omit the instance name to run on every `.opb`/`.pbp` pair in the proofs directory:

```bash
./trimnalyser --threads 8,1 /path/to/proofs/
```

Each instance is spawned as a separate subprocess (`julia -t1,1 ...`) so GC heaps are fully isolated. The outer `--threads N` controls how many subprocesses run in parallel.

Useful batch flags:

| Flag | Effect |
|------|--------|
| `rand` | Shuffle instance order |
| `sort` | Sort by proof file size (ascending) |
| `overwrite` | Re-trim instances that already have `.smol` files |
| `verif` | Run VeriPB to verify each trimmed output |
| `keepraw` | Keep original proof files after trimming (default: delete after verified) |
| `minnodes=N` | Skip instances where either graph has fewer than N nodes |
| `maxnodes=N` | Skip instances where either graph has more than N nodes |
| `maxmem=N` | OOM-kill subprocesses exceeding N GB (default: 8 on laptop, 50 on cluster) |
| `minmem=N` | Pause spawning new jobs when free RAM drops below N GB |
| `st=N` | Solver timeout in seconds (default: 5) |
| `tt=N` | Trim subprocess timeout in seconds (default: 45) |
| `vt=N` | VeriPB timeout in seconds (default: same as `tt`) |

### 5 — Full cluster run (enumerate all benchmark pairs)

Generates all `(pattern, target)` pairs from the benchmark graph directories, solves and trims each:

```bash
./trimnalyser --threads 192,1 solve resolv verif allgraphs maxnodes=3000 st=180 tt=6000 rand maxmem=50
```

`allgraphs` reads graph files from the directory set by `TRIMNALYSER_GRAPHS`.

---

## All flags

| Flag | Description |
|------|-------------|
| `solve` | Run Glasgow solver before trimming (proof files don't need to exist yet) |
| `resolv` | Iterative UNSAT-core re-solve loop after trimming (implies `core`) |
| `core` | Write UNSAT core LAD files and reduced problem graphs |
| `verif` | Run VeriPB on each trimmed output |
| `overwrite` | Re-trim even if `.smol` files already exist |
| `allgraphs` | Enumerate all benchmark `(pattern, target)` pairs instead of reading a proofs dir |
| `rand` | Shuffle instance order |
| `sort` | Sort instances by file size (ascending) |
| `clit` | Cone-first conflict analysis mode |
| `no` | Skip the normal (Grim) trim pass (use with `clit` to run only the clit variant) |
| `keepraw` | Keep original `.opb`/`.pbp` proof files after trimming (default: delete after verified) |
| `atable` | Print TikZ scatter plot from existing `.out` files and exit |
| `clean` | Delete all `.out`/`.err`/`.lad`/`.dot` files in the proofs dir |
| `pack` | `tar.gz` all `.dot` files in `vis/` → `vis.tar.gz` (for cluster transfer) |
| `render` | Extract `vis.tar.gz` and render all `.dot` → `.svg` with `neato` |
| `no-supplementals` | Run solver without supplemental graphs |
| `profile` | Enable `StatProfilerHTML` profiling (requires StatProfilerHTML installed) |
| `minnodes=N` | Filter graph pairs: skip if either graph has < N nodes |
| `maxnodes=N` | Filter graph pairs: skip if either graph has > N nodes |
| `st=N` | Solver timeout in seconds (default: 5) |
| `tt=N` | Trim subprocess timeout in seconds (default: 45) |
| `vt=N` | VeriPB timeout in seconds (default: same as `tt`) |
| `maxmem=N` | OOM-kill limit per subprocess in GB (default: 8 laptop / 50 cluster) |
| `minmem=N` | Minimum free RAM in GB before spawning new jobs (default: 4 laptop / 100 cluster) |

---

## Aggregating results

After a batch run, aggregate all `.out` files into a CSV:

```bash
julia scripts/aggregate_results.jl <proofs_directory> [output.csv]
```

Default output: `results.csv`.

## Analysing results

Install script dependencies once per machine (generates `scripts/Manifest.toml`):

```bash
julia --project=scripts -e 'using Pkg; Pkg.instantiate()'
```

Quick terminal statistics (step types, depth distribution, resolv shrinkage).
Stdlib-only — no `--project` needed:

```bash
julia scripts/quick_stats.jl cluster_results.csv [output.txt]
```

Default output: `stats_summary.txt`.

Static graph structural features (per-graph and relational). Joins to `cluster_results.csv` by instance name:

```bash
julia scripts/graph_features.jl <proofs_dir> [graphs_dir] [output.csv]
```

`graphs_dir` defaults to `$TRIMNALYSER_GRAPHS`. Default output: `graph_features.csv`.

Proof survey — family-stratified HTML report with exhaustive label tracking, step-type breakdowns, and graph-feature correlations. Pass both CSVs to include correlations:

```bash
julia --project=scripts scripts/proof_survey.jl cluster_results.csv [graph_features.csv] [output.html]
```

Arguments after the first CSV are positional and auto-detected by extension (`.csv` → graph features, `.html` → output path). Default output: `proof_survey.html`.

Supplemental graph classifier — per-family g1adj/g2adj/g3adj usage rates and
structural feature correlations. Requires both CSVs. The third argument is the output
base name (`.html` and `.txt` are appended):

```bash
julia --project=scripts scripts/classify_supplementals.jl cluster_results.csv graph_features.csv [output_base]
```

Default base: `classify_supplementals`. Outputs `<base>.html` (full interactive report) and
`<base>.txt` (plain-text summary). Sections:
- §1 — per-family g1adj/g2adj/g3adj usage rates, split ALL / no-search / with-search
- §2 — discriminant features cross-stratum table
- §3–§5 — AUC + correlation tables per target (g1adj/g2adj/g3adj) × subset

---

## Faster startup with a sysimage (optional)

On machines with fast disk I/O (cluster NVMe, RAM-backed tmpfs), a sysimage eliminates per-process JIT cost and is most valuable in batch mode where hundreds of subprocesses start in parallel. `build_sysimage.jl` detects staleness automatically (checks mtimes of all `src/` files):

```bash
julia --project=. build_sysimage.jl
```

The wrapper `./trimnalyser` picks up `trimnalyser.so` automatically if it exists — no flags needed. Pass `nosys` to skip sysimage build and use and run with vanilla Julia (useful for fast dev loops).

The sysimage build uses `precompile_workload.jl` to trace a real trim run during the snapshot phase, so all hot code paths are baked into the `.so` as native code. There is no separate precompilation step — the workload runs directly inside PackageCompiler's snapshot process.

> **Note:** `PackageCompiler` must be installed globally (`julia -e 'using Pkg; Pkg.add("PackageCompiler")'`). If not installed, the build is skipped gracefully and Julia falls back to JIT compilation.

---

## Running tests

```bash
julia --project=. test/runtests.jl
```

Runs two integration tests against the instances bundled in `test/instances/`: a fast trim-only run on `LVg400g500` and a full resolv+verif run on `LVg10g12`. The verif assertion is skipped silently if VeriPB is not installed.

---

## Project structure

```
trimnalyser          shell wrapper (auto-detects sysimage, handles --project)
bin/trimnalyser.jl   thin CLI entry point
src/
  TrimAnalyser.jl    module root, static constants, include chain
  config.jl          Config struct, parse_config!(), argflags
  utilities.jl       available_memory, file helpers
  types.jl           FlatEqStore, SystemLink, PBSystem, Trail, Ante, PolScratch
  parser.jl          readopb, readproof, tokenize!
  pol.jl             PolScratch, solvepol_flat!
  trimmer.jl         getcone!, propagate_level0!, ruptrail
  writer.jl          writeconedel, writeeq, writered, writepol
  solver.jl          runsipsolver, resolvecore, writecoreladfile
  pipeline.jl        trimnalyseandcie, trimnalyse, smol_complete
  output.jl          writeout_*, verify, printconestat, statistics
  orchestrator.jl    main(), OOM monitor, instance enumeration
scripts/
  aggregate_results.jl        post-run CSV aggregation
  graph_features.jl           static graph structural features (separate CSV)
  quick_stats.jl              quick terminal statistics
  proof_survey.jl             M3 family-stratified HTML analysis report
  classify_supplementals.jl   M3.5 supplemental graph usage classifier + HTML report
  Project.toml                script dependencies (CSV.jl, DataFrames.jl)
build_sysimage.jl        staleness-aware sysimage builder
precompile_workload.jl   trim workload executed by PackageCompiler during sysimage build
test/
  runtests.jl        integration tests
  instances/         test OPB/VeriPB proof pairs
```

---

## Output files

| File | Description |
|------|-------------|
| `<inst>.smol.opb` | Trimmed constraint file |
| `<inst>.smol.pbp` | Trimmed proof file |
| `<inst>.out` | Per-instance stdout log (parsed by `scripts/aggregate_results.jl`) |
| `<inst>.err` | Per-instance errors / OOM / timeout messages |
| `vis/<inst>.pat.dot` | Full original pattern graph; core nodes green, rest red (written when `core`/`resolv`) |
| `vis/<inst>.tar.dot` | Same for target graph |
| `vis/<inst>.pat.svg` | Rendered version of the above |
| `vis/<inst>.tar.svg` | |
| `vis/<inst>.core.pat.lad` | Induced subgraph on core nodes; input to the iter-1 solver run |
| `vis/<inst>.core.tar.lad` | |
| `vis/<inst>.coreN.pat.dot` | Input graph for iteration N (= core of iter N−1), with iter N's own core in green |
| `vis/<inst>.coreN.tar.dot` | |
| `vis/<inst>.coreN.pat.svg` | Rendered version |
| `vis/<inst>.coreN.tar.svg` | |
| `vis/<inst>.coreN.core.pat.lad` | Induced subgraph from iteration N's trim; input to the iter-(N+1) solver run |
| `vis/<inst>.coreN.core.tar.lad` | |
