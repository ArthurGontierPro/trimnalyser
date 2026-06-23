# CLAUDE.md

## Testing Constraints

**Local disk can't hold the full benchmark set.**

- **Never** run without specifying an instance name or without reading memory first.
- **Standard local test** after any code change:
  ```bash
  ./trimnalyser LVg10g12 overwrite resolv
  ```
  Proof files at `/home/arthur_gla/veriPB/subgraphsolver/proofs/`. This instance is 858 KB OPB + 24 MB PBP and exercises the full resolv loop.
- **Syntax-only check** (no execution, zero disk writes):
  ```bash
  julia --startup-file=no -e 'for f in readdir("src"; join=true); endswith(f,".jl") && Meta.parseall(read(f,String)); end; println("OK")'
  ```

## Common Commands

```bash
./trimnalyser LVg10g12 overwrite resolv                                          # single instance
./trimnalyser --threads 92,1 solve resolv verif allgraphs minnodes=50 maxnodes=200 st=18 tt=600 rand  # cluster run
julia scripts/aggregate_results.jl /scratch/arthur/proofs/ cluster_results.csv   # aggregate → CSV
julia scripts/graph_features.jl /scratch/arthur/proofs/ graph_features.csv       # static graph features
julia scripts/quick_stats.jl cluster_results.csv                                 # terminal stats (stdlib only)
julia --project=scripts scripts/proof_survey.jl cluster_results.csv graph_features.csv proof_survey.html  # HTML report
julia --project=scripts scripts/classify_supplementals.jl cluster_results.csv graph_features.csv classify_supplementals  # supplemental classifier
julia --project=scripts -e 'using Pkg; Pkg.instantiate()'                        # install script deps
julia --project=. build_sysimage.jl                                              # build sysimage (~5s → ~0.1s)
```

Key flags: `solve` (run SIP solver), `resolv` (iterative re-solve on UNSAT cores), `verif` (run VeriPB), `overwrite`, `profile`, `allgraphs`, `bfs`/`clit` (alternative trim modes).
Timeout args: `st=N` (solver), `tt=N` (trim), `vt=N` (verif), `maxnodes=N`, `minnodes=N`.

### Cluster commands

```bash
# on cluster: aggregate + generate reports
bash scripts/harvest.sh
# on local: pull everything
bash scripts/harvest_pull.sh

# single instance test on cluster
./trimnalyser LVg10g12 overwrite solve resolv nosys

# verify labels are in .out
grep 'CONE LABEL' /scratch/arthur/proofs/LVg10g12.out

# rebuild sysimage on cluster
julia --project=. build_sysimage.jl
```

## Architecture

**Orchestrator mode** (no instance in ARGS, or `allgraphs`): spawns one subprocess per instance via `julia bin/trimnalyser.jl <instance>`. OOM monitor on `:interactive` thread polls `/proc` every 10s, kills trimmer subprocesses and Glasgow solver processes exceeding `maxmem=` GB. Solve/verif/resolv run in orchestrator threads with independent timeouts.

**Subprocess mode** (instance name in ARGS): trim-only. Writes `.smol.opb` + `.smol.pbp`, then exits. SIGTERM caught cleanly (exit 124). Output routed via `.subout` temp file to avoid interleaving.

### Source layout

| File | Contents |
|------|----------|
| `src/TrimAnalyser.jl` | Module root, static constants, include chain |
| `src/config.jl` | `Config` struct, `parse_config!`, `argflags` |
| `src/utilities.jl` | `available_memory`, file helpers |
| `src/types.jl` | Core structs: `FlatEqStore`, `SystemLink`, `PBSystem`, `Trail`, `Ante`, `PolScratch` |
| `src/parser.jl` | `readopb`, `readproof`, `tokenize!` |
| `src/pol.jl` | `PolScratch`, `solvepol_flat!` |
| `src/trimmer.jl` | `getcone!`, `propagate_level0!`, `conflicttrail`, `ruptrail` |
| `src/writer.jl` | `writeconedel`, `writeeq`, `writered`, `writepol` |
| `src/solver.jl` | `runsipsolver`, `resolvecore`, `writecoreladfile` |
| `src/output.jl` | `writeout_*`, `verify`, `printconestat`, statistics |
| `src/pipeline.jl` | `trimnalyseandcie`, `trimnalyse`, `smol_complete` |
| `src/orchestrator.jl` | `main()`, OOM monitor, instance enumeration |

### Key data structures

**`FlatEqStore`** — CSR-like flat storage for all parsed equations. Fields: `vars/coefs/signs/rhs` (flat arrays) + `row_ptr` (offsets). Eliminates millions of heap allocations vs `Vector{Eq}`.

**`SystemLink`** — CSR for proof step link data. `idx[i]`: `k>0` → slice in flat `data[ptr[k]:ptr[k+1]-1]`; `k<0` → shared singleton (rule type); `k=0` → mutable `Vector{Int}` in `extra` dict (RUP cone / RED refs). Zero allocation per step during parsing.

**`PBSystem`** — Dual-index CSR. Forward: `row_ptr/vars/coefs/signs/rhs`; inverse: `var_ptr/var_eqs/var_lit_idx` (equations per variable + flat literal index within each — eliminates O(k) inner scan in `update_slack_on_assign!`). Stores `initial_slack_fwd/rev` for O(n) Trail reset per RUP step. Built once from `FlatEqStore`.

**`PolScratch`** — Task-local scratch for POL evaluation. Stack-based evaluator on flat arrays; pushes result into `FlatEqStore` without allocating. Retrieved via `task_local_storage(:pol_scratch)`.

**`Trail`** — Propagation trail: `pos[]` (step index per var) + `assi[]` (0=unset, 1=true, 2=false), O(1) lookup.

**`Ante`** — Antecedent set: O(1) membership + O(k) iteration, used by `getcone!`.

### Parser

Files read via `Mmap.mmap` → byte array. `tokenize!` produces `ByteSpan` tokens (no copies). `varmap::Dict{Vector{UInt8},Int}` with `ByteSpan` keys (same hash as `Vector{UInt8}`) for zero-allocation lookups. New variables copy bytes once and are kept permanently.

### Trimming algorithm

`getcone!` does backward reachability from the UNSAT contradiction, accumulating the minimal cone of proof steps needed to justify it.

**Outer loop.** `frontier` is a `BinaryMaxHeap{Int}` — highest-index-first. Each step dispatches by rule type: POL/IA have explicit antecedents; RUP is verified by unit propagation.

**RUP — two-queue heuristic.** `ruptrail` routes each equation to `pq_prio` if `cone[eid]` is already true, `pq_nonprio` otherwise, and drains `pq_prio` completely before taking one step from `pq_nonprio`. This steers conflict toward already-needed constraints, minimising cone growth. `cone` is read by `activate!` but never written inside `ruptrail` — only the outer loop writes it via `push_frontier!`.

**Conflict analysis — `conflicttrail`.** PB-specific (not CDCL): slack value determines minimum coefficient-sum of falsified literals to explain. `Grim` sorts by proof index; `Clit` filters to essential/already-cone literals first.

**Full heuristic chain (do not break any link):**
outer traversal → `cone` accumulation → `activate!` routing → `pq_prio`/`pq_nonprio` ordering → first conflict found → `conflicttrail(mode)` → antecedents added to cone

**`propagate!` vs `ruptrail`.** Initial UNSAT contradiction found once by `propagate!` (simpler linear scan, hardcodes `Grim`). Correct because cone is nearly empty at that point. If ever called with non-empty cone, unify with `ruptrail`.

### Resolv loop

`resolvecore` iterates: extract UNSAT core → write reduced LAD → re-run Glasgow solver → trim new proof. Stops at fixpoint or solver failure. Core LADs written to `vis/`; outputs are `.smol.opb`/`.smol.pbp`.

## Output files

- `<instance>.smol.opb` / `.smol.pbp` — trimmed constraint + proof
- `<instance>.out` / `.err` — per-instance logs (parsed by `aggregate_results.jl`)
- `cluster_results.csv` — aggregated metrics (~100 columns) from all `.out` files

## Startup & Sysimage Call Chain

See [`docs/startup-callchain.md`](docs/startup-callchain.md) for the full call chain diagram, sysimage contract (the `--sysimage`/`--project`/`TRIMNALYSER_SYSIMAGE` triad), subprocess launcher details, and debugging guide.

## Known Design Flaws

**Sysimage flag triad is fragile.** Three flags (`--sysimage`, `--project`, `TRIMNALYSER_SYSIMAGE`) must be set consistently across bash wrapper + subprocess launcher. They are set independently in two places (`trimnalyser:34`, `orchestrator.jl:214–218`) with no shared definition. See `docs/startup-callchain.md` for the contract table.

**`run_instance_full` / `run_instance_batch` duplication.** Both implement solve→check→trim→verify→resolv with different subprocess handling for the trim step. Any fix must be mirrored in both. Should be unified with a strategy parameter.

**Global `_cfg[]`.** Every function reads global mutable config implicitly. Makes the call graph opaque and prevents unit-testing of individual stages.

**Internal stdout tee pipe.** `main()` redirects stdout into a Julia pipe with a tee task writing to `output.log`. Fragile: tee task crash (e.g. disk full) breaks the pipe, which propagates to worker threads. Shell-level `tee` would be simpler and more robust.

**Progress `printstyled` outside `@threads` try-catch** (`orchestrator.jl:609–616`). An IO error there escapes the thread loop and crashes the orchestrator while subprocesses are still running.

**OOM monitor matching logic.** Now branches on two process types (trimmer vs solver) with different instance-name extraction. Needs a registered table of `(binary_name, extractor)` pairs if more process types are added.
