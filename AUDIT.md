# TrimAnalyser Code Audit Report

**Codebase:** `src/` (12 files, ~2,700 lines of Julia)
**Scope:** Correctness, performance, robustness, maintainability

---

## 4. Performance Concerns

### 4.1 `update_slack_on_assign!` O(k) scan per equation — `types.jl:231–245`

For each variable assignment, for each equation containing that variable, the function
re-scans all literals of the equation to find the matching literal index. With `k`
literals per equation and `d` equations per variable, this is O(k·d). A supplementary
`var_lit_pos` map keyed by `(var, eq)` would make it O(d).

### 4.2 `init_slack_cache!` called on every RUP step — `trimmer.jl:361`

`ruptrail` calls `init_slack_cache!(t, sys)` at the start of every RUP step,
rebuilding the full slack cache from scratch. For large proofs with thousands of cone
steps this is significant.

**Option A (incremental):** Keep a permanent `base_trail` alongside the working trail.
After each RUP step, instead of calling `init_slack_cache!` from scratch, restore the
working trail from the base and replay only the level-0 propagations that are still
valid. Cost: O(base trail length) per step instead of O(n·k).

**Option B (lazy):** Mark the slack cache dirty per-constraint on assignment and
recompute only the constraints that were actually touched. Cost: O(|touched|) per step.
Implementation is more complex (dirty bitmap + invalidation on unassign).

**Option C (profile first):** Before implementing either, measure what fraction of
total runtime is spent in `init_slack_cache!` on large instances. The cache is
O(n·k) where n = number of equations and k = average literals per equation; for
LVg10g12 (28K equations) this may be negligible.

### 4.3 `findfullassi` naive O(n²) unit propagation — `parser.jl:372–389`

The `TODO` comment on line 375 acknowledges this. The loop re-scans all constraints
until fixpoint, quadratic in constraint count. This runs at parse time for every
`soli`/`solx` step.

**Option A (watch-list):** Maintain a per-variable watch list (inverse index of which
constraints contain each variable). On each new assignment propagate only the
constraints watching that variable. This is the standard CDCL unit propagation approach:
O(propagation length) amortized rather than O(n) per round.

**Option B (reuse PBSystem):** `findfullassi` is called after `PBSystem` is already
built. Pass the inverse index (`var_ptr`/`var_eqs`) in and use it directly, eliminating
the re-scan entirely.

**Note:** `soli`/`solx` steps are rare in practice (one per solution constraint in the
proof). Measure frequency before investing in this optimisation.

---

## 5. Code Quality

### 5.1 `conflicttrail` duplicated between `Grim` and `Clit` ✅ fixed

Extracted `_arrange_falsified_lits!` dispatch helpers; replaced two ~100-line methods
with one unified body in `trimmer.jl`.

### 5.2 Instance prefix list duplicated four times ✅ fixed

Consolidated into `is_instance_name()` in `TrimAnalyser.jl`; replaced four inline
copies in `config.jl` and `orchestrator.jl`.

### 5.3 `filesize` shadows `Base.filesize` ✅ fixed

Removed the shadow; all callers transparently use `Base.filesize`.

### 5.4 `processred` inserts two entries with identical data ✅ fixed

`redid == length(store)` after `push_eq!`, so the second write was always overwriting
the first with the same value. Removed the redundant `redwitness[redid]` assignment.

### 5.5 `pol_weaken!` uses linear search ✅ fixed

Replaced `findfirst(==(Int32(var)), vars)` with `searchsortedfirst` (vars are sorted
by variable index from `readlits`).

### 5.6 Uncaught OOB risk in `solvepol_flat!` ✅ fixed

Added `j >= length(st)` guard before the `st[j+1]` access.

---

## 6. Minor / Style Issues ✅ fixed

| Location | Fix applied |
|---|---|
| `utilities.jl` | Removed spurious 4-space indentation |
| `parser.jl` | Bare string `throw(...)` → `error(...)`; fixed "assignement" typo |
| `writer.jl:244` | Added clarifying comments on the `lastindex` decrement/increment pair |

---

## 7. Summary

| Severity | Count | Status | Key Items |
|---|---|---|---|
| **Bug (wrong output)** | 3 | ✅ fixed | `~` never written in pol (`writer.jl:85`), Int32 overflow in multiply/saturate (`pol.jl:88`), rhs_adj overflow in add (`pol.jl:33,161`) |
| **Potential crash** | 2 | ✅ fixed | RED subproof guard (`trimmer.jl`), heap internals replaced with `empty!` |
| **Dead code** | 3 | ✅ fixed | `ruptrail_bfs`+`conflicttrail_bfs` removed, `Dumping` module removed, RED skeleton kept |
| **Performance** | 3 | 🔜 pending | Slack rebuild per RUP step (options in §4.2), O(k·d) assignment update (§4.1), O(n²) soli propagation (§4.3) |
| **Maintainability** | 6 | ✅ fixed | `conflicttrail` deduplicated, prefix list consolidated, `filesize` shadow removed, dual redwitness entry removed, linear weaken → `searchsortedfirst`, OOB guard added |