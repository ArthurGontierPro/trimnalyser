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

### 5.1 `conflicttrail` duplicated between `Grim` and `Clit` — `trimmer.jl:160–273`

The two dispatch methods are ~100 lines each and share every line except:
- the `prio_sum`/`filter!` guard (Clit only, lines 249–258)
- the sort comparator (line 257 vs 192)

Extracting the shared loop body into a helper with the sort/filter logic passed as a
closure reduces ~100 lines of duplication to ~10.

### 5.2 Instance prefix list duplicated four times

The nine family prefixes (`"LV"`, `"bio"`, `"cviu11"`, `"pr15"`, `"mesh11"`, `"ph_"`,
`"sf_"`, `"si__"`) appear verbatim in `config.jl:44–48`, `orchestrator.jl` (OOM
monitor and `_run_main`), and `solver.jl`. Promote to a module-level constant
(a `Tuple` or `Set`) and reference it everywhere.

### 5.3 `filesize` shadows `Base.filesize` — `utilities.jl:27`

```julia
filesize(file) = stat(file).size
```
`Base.filesize(path::AbstractString)` already does exactly this. Remove the shadow
and use `Base.filesize` directly throughout.

### 5.4 `processred` inserts two entries with identical data — `parser.jl:309–310`

```julia
redwitness[redid] = Red(w, 0:0, [])
redwitness[length(store)] = Red(w, 0:0, [])
```
Two dictionary entries are created at keys `redid` and `length(store)`. When
`redid == length(store)` (edge case), the second write silently overwrites the first.
The dual-key lookup intent is not documented anywhere.

### 5.5 `pol_weaken!` uses linear search — `pol.jl:142`

```julia
i = findfirst(==(Int32(var)), vars)
```
Since equations are sorted by variable index (`readlits` calls `sort!`), this linear
scan can be replaced with `searchsortedfirst` for O(log n) lookup.

### 5.6 Uncaught OOB risk in `solvepol_flat!` — `pol.jl:252`

```julia
if !tok_in(st[j+1], ["*", "d"])
```
`j+1` is accessed inside a loop where `j` reaches `length(st)`. If the last token of
a POL step is a constraint ID, `st[j+1]` is out of bounds. A guard `j < length(st)`
is missing.

---

## 6. Minor / Style Issues

| Location | Issue |
|---|---|
| `utilities.jl:1–32` | Entire file is uniformly indented 4 spaces with no enclosing block, unlike every other file in `src/`. |
| `parser.jl:241` | `throw("trimmed SAT is the solution")` — bare string throw; use `error()`. |
| `parser.jl:345,401` | `throw(" assignement not propagated to full")` — typo ("assignement"), bare string throw. |
| `writer.jl:244` | `lastindex -= 1` / `lastindex += 1` pair inside the `-10` branch is hard to follow — the net effect depends on a `systemlink` field check that is not the same as the surrounding rule-type dispatch. Needs a comment. |
| `output.jl:358–371` | `prefixtikz`/`postfixtikz` print raw LaTeX to stdout from inside what looks like a display function; there is no documentation of what calls these or when. |
| `config.jl:37–38` | The default proof directory is derived from `abspath_base`, which is itself resolved from `ENV` or cluster detection. If `TRIMNALYSER_BASE` is set explicitly, the default proof path still changes with it implicitly — this coupling is non-obvious. |

---

## 7. Summary

| Severity | Count | Status | Key Items |
|---|---|---|---|
| **Bug (wrong output)** | 3 | ✅ fixed | `~` never written in pol (`writer.jl:85`), Int32 overflow in multiply/saturate (`pol.jl:88`), rhs_adj overflow in add (`pol.jl:33,161`) |
| **Potential crash** | 2 | ✅ fixed | RED subproof guard added (`trimmer.jl`), heap internals replaced with `empty!` (`trimmer.jl`) |
| **Dead code** | 3 | ✅ fixed | `ruptrail_bfs`+`conflicttrail_bfs` removed, `Dumping` module removed, RED skeleton kept |
| **Performance** | 3 | 🔜 pending | Slack rebuild per RUP step (options in §4.2), O(k·d) assignment update (§4.1), O(n²) soli propagation (§4.3) |
| **Maintainability** | 6 | ✅ fixed | `conflicttrail` deduplicated, prefix list consolidated, `filesize` shadow removed, dual redwitness entry removed, linear weaken → `searchsortedfirst`, OOB guard added |
