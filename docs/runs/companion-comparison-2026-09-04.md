# Head-to-head against the VeriPB trimmers — 2026-09-04

The comparison `sec:compress` has been promising since it was written. This is the run
that produces it, and `tab:configs-companion`.

## What is being compared

Three trimmers read **one and the same stock proof** per instance, and every one of them
is judged on the artefact a verified checker would actually consume.

```
        <ins>.opb + <ins>.pbp     Glasgow gss-lazy (1ff87ba), kept with `keepraw`
              |
  base   -----+------------------ veripb -e            -> full.elab.pbp    DENOMINATOR
  ta     ---- trimnalyser -------> .smol.opb/.smol.pbp
              `------------------ veripb -e            -> ta.elab.pbp
  ft     ---- veripb_ft trim ----> ft.opb / ft.pbp     already elaborated
  tb     ---- veripb_tb trim ----> tb.opb / tb.pbp     already elaborated   [BLOCKED]
```

Four decisions, each of them a way this could have been measured wrongly:

* **Both sides are elaborated before they are measured.** The VeriPB trimmers emit only
  elaborated proofs; our `.smol.pbp` still carries `rup`. Comparing those directly would
  credit us for work the elaborator has yet to do.
* **One checker for every arm.** Verify time is a reported column, so all three arms are
  re-checked with the same `veripb` 3.0.2 at `/scratch/arthur/veripb`. Only the `trim`
  subcommand differs between arms.
* **Ratios are paired per instance**, over instances *both* tools got past that checker,
  and the refusals are reported rather than dropped. The companion's published $6.85$
  moves to 8.5–14.6 depending on the exclusion set, so this is not a detail.
* **The arms run back to back inside one job.** A machine-load swing then hits all of
  them or none — which four separate passes could not promise.

## Instance sets

| set | n | what |
|---|---|---|
| C | 12 | the companion's *own* gss evaluation set, recovered from `benches/solver_instances/gss/` on `origin/feature_trimmer`: `LVg19g36 LVg2g3 LVg34g51 LVg5g24 LVg7g25` + 7 `bio*`. Gives `\ph{XLV}`/`\ph{YLV}`, and a cross-check against their $6.85$. |
| S | 160 | 40 each from LV, bio, images-CVIU11, meshes-CVIU11, subsampled (seed 20260904) from `~/instances_stratified.txt`, the list the propagate!/ruptrail A/B already used. scalefree is dropped: 3 instances is not a family. |

Union is 171 (one instance is in both). We regenerate the proofs ourselves rather than
using their shipped `.pbp` — "the two tools on our machine", and their files came from a
different Glasgow revision anyway.

## Where it ran

fataepyc-01, idle, 192 cores / 2 TB, 11 T free on `/scratch`. The six grid columns on
03/04/05/07/08/09 were never touched and were re-checked alive afterwards.

Three isolations, because `$HOME` is **one shared NFS mount across all nine nodes**:

* its own proof dir, `/scratch/arthur/companion/proofs/`
* its own log dir, `/scratch/arthur/companion/logs/` — the grid's `/cluster/arthur/logs`
  is append-only and aggregated, and a comparison has no business in it
* **its own checkout**, `~/trimnalyser-companion`, so that nothing here can rebuild
  `~/trimnalyser/trimnalyser.so` under a live orchestrator. That is not hypothetical:
  it killed `lad-fc-pl` on fataepyc-08 with `signal 7 (2): Bus error` on 2026-09-01.

The companion checkout carries **byte-identical `src/`** to the grid's `f70d02c` — every
commit between them touches `scripts/` or `docs/` only — so the trimmer measured here is
the trimmer the paper's runs use.

## Binaries

| | built from | tip | note |
|---|---|---|---|
| `veripb` | `main` | `78db9573` | the shared checker, v3.0.2 — every arm is re-checked with this one |
| `veripb_ft` | `origin/feature_trimmer` | `e98c4a31` (2026-08-11) | the public official trimmer |
| `veripb_tb` | `origin/feature/trimmer-base` | `af219d36` (2026-09-03) | the unreleased rewrite |

**Getting them.** Both branches live on `gitlab.com/MIAOresearch/software/veripb-dev`,
which neither machine could reach at first. The key that works is
`~/.ssh/fatamiao` **on the cluster** (comment `arthur@fataepyc-10`); the laptop's own two
keys are both rejected. Fetch on the **head node** — the compute nodes have no route to
gitlab.com, and an unreachable remote there hangs rather than fails:

```bash
ssh fataepyc-head
cd ~/veripb-dev
git remote set-url origin git@gitlab.com:MIAOresearch/software/veripb-dev.git
GIT_SSH_COMMAND="ssh -i ~/.ssh/fatamiao -o IdentitiesOnly=yes" git fetch --all --prune
```

`$HOME` is shared NFS, so one fetch on the head serves every node.

Two things that fetch changed:

* `feature_trimmer` had moved **958f1d20 → e98c4a31**, so the first smoke ran against a
  three-month-old tip. Everything reported below is the current one.
* `feature/trimmer-base` is **not a descendant of `feature_trimmer`** — it branches off
  `main` and re-implements the trimmer in its own `veripb-trimmer` crate. Two practical
  consequences, both now handled by the scripts rather than by hand:
  it declares `rust-version = 1.92.0` where the cluster default is `1.86.0`
  (`rustup toolchain install 1.92.0` on the head; `~/.rustup` is shared too), and its
  `trim` subcommand has **no output-formula positional** — that moved to `check` — so the
  argv that suits `feature_trimmer` would leave a stray path there.

## Findings so far

**1. The VeriPB trimmer does not trim the model.** Its `output_formula` positional is
accepted and then never written on these proofs, so its certificate keeps the original
`.opb` whole. On `LVg11g52` that is 2.96 MB against our 374 KB. The table therefore
reports two compression columns — certificate (model + elaborated proof) and proof only —
because quoting either one alone misrepresents somebody.

**2. It refuses proofs VeriPB 3.0.2 verifies.** Seen on `LVg10g22` at `.pbp:5195`, against
`feature_trimmer` @ `958f1d20`; to be re-confirmed against `e98c4a31`, which carries
several hint- and id-handling fixes:

```
setlvl 0;
@g2adj6_3_1 ia 1 ~x6_3 1 x1_1 ... >= 1 : 13828 ;
wiplvl 1;
@g1adj6_3_1 ia 1 ~x6_3 1 x1_1 ... >= 1 : @g2adj6_3_1 ;
```
```
Error: Syntax error while parsing proof file!
Caused by: The label `@g2adj6_3_1` is not assigned to a constraint ID at line 5195 col 133.
```

The label is defined **two lines earlier**, at 5193, and the same file verifies end to end
under `veripb` 3.0.2. The only thing between definition and use is the `wiplvl 1`, which
points at label lifetime across a level change. This is the first candidate to send
upstream. The harness records the reason per instance (`ft_note`) so the refusals can be
classified rather than counted.

## The full-suite run (weekend, 2026-09-04 onward)

The 171-instance run above is the stratified table. The weekend run is the same comparison
over the whole suite — all **25,590** instances, enumerated by
`scripts/dump_instances.jl`, which calls `allgraphinstances()` rather than re-deriving the
per-family pairing rules (they differ between all eight families and are exactly what a
reimplementation gets subtly wrong).

Two design points, both forced by things that have already gone wrong here:

* **Chunked, not two-phase.** Producing every stock proof first needs them all on disk at
  once — the ~13 TB that exhausted `/scratch` before. `companion_run_all.sh` walks the
  shard in chunks of 96, into a per-chunk proof directory, and deletes that directory the
  moment the chunk's rows are in the CSV. Peak disk is one chunk. Resumable at chunk
  granularity via `.done` markers.
* **Random order, fixed seed.** The list is shuffled with `SEED=20260904` and dealt
  round-robin to the shards, so shards are disjoint and reproducible from the seed alone,
  and each walks the suite in random order. This run *will* be stopped before it finishes —
  25,590 instances through four arms is days of work — so what matters is that stopping it
  early leaves an **unbiased sample**, not everything whose name sorts first.

| shard | node | | 
|---|---|---|
| 1/3 | fataepyc-02 | |
| 2/3 | fataepyc-06 | also hosts the trimmer bug-fix work |
| 3/3 | fataepyc-01 | starts when the 171-instance run there finishes |

Settings: `CHUNK=96 JOBS=24 THREADS=92,1 ST=600 STNOPL=60 TT=1800 VT=1800 MAXMEM=32`.
Note `TT`/`VT` are **1800** here against **3600** for the 171-instance run — the two are
comparable arm-against-arm within each run, but pool their rows only under the lower cap.

**A checkout per node** (`~/trimnalyser-companion-<host>`), not one shared. `$HOME` is a
single NFS mount across all nine nodes, and two nodes building `trimnalyser.so` in one tree
is the shared-sysimage race that killed `lad-fc-pl` with a Bus error on 2026-09-01. The
launcher also builds each node's sysimage up front, so no two chunks can race on it, and
refuses to start if `src/` and `bin/` differ from the grid's `f70d02c`.

### The fix, and why the first launch was wrong

`feature_trimmer`'s bug is two lines in `src/trimmer.rs`. There are **two** label tables:
`Context::label_to_id`, which `PolRule`'s lexer consults for `pol` operands, and the
`Parser`'s own, which `Parser::constraint_id()` consults for hint lists (`... : @label`).
The parser's table is extended only from the return value of
`ProofProcessor::get_returned_constraint_id`. `Verifier` returns the id; `Trimmer` inserted
into the Context table and then returned `None` **unconditionally**, so the parser's table
stayed frozen at the formula's labels. That is exactly why substituting an `.opb`-defined
label made the error vanish, and why `pol` operands were unaffected.

```rust
-        let id = unsafe { self.get_returned_constraint_id().unwrap_unchecked() };
+        let id = self.get_returned_constraint_id()?;
         self.context.label_to_id.insert(label, id);
-        None
+        Some(id)
```

`?` in place of `unwrap_unchecked()` also removes latent UB: `trimmer.rs:93` sets
`returned_constraint_id = None` on the order-`pol` branch, so a labelled rule there was
unwrapping a `None` inside `unsafe`. `cargo test --release` is unchanged at 657 passed /
0 failed, and the trimmed proof now passes the reference checker. Patch:
`/cluster/arthur/veripb-bug/fix.patch`.

**The full run was first launched against the UNFIXED binary, and that was a mistake.**
Every proof the bug hits would have been banked as an `ft` refusal, and the paired ratios
computed on precisely the subset the bug spares — the exclusion-set bias this whole design
exists to avoid. Caught before either shard finished its first chunk; **0 rows banked**,
nothing to discard.

Two guards came out of it, both in `companion_compare.sh` / `companion_run_all.sh`:

* every run stamps the sha256 and version of each binary beside its CSV;
* the driver **refuses to append** to an output directory whose stamp disagrees, because
  `compare-all.csv` accumulates chunks over days across three nodes and a trimmer rebuilt
  mid-run would otherwise split a column into two populations that look like one.

The stamp earned itself immediately: its first output read `absent veripb_tb`. That binary
had been built on fataepyc-01's node-local `/scratch` and existed nowhere else, so the
third arm was being skipped on the other two shards — silently, in every respect except
the stamp. Same failure mode as `cake_pb` before it was staged in `dist`.

### Which run measures which trimmer

| run | `ft` binary | what its `ft` column means |
|---|---|---|
| 171-instance stratified (fataepyc-01) | **unfixed** `e98c4a31` | `feature_trimmer` *as published* — its refusal rate is the number we owe the VeriPB devs |
| full suite (all three shards) | `e98c4a31` **+ the fix** | the real head-to-head |

That split is deliberate, not an accident of timing: the sample is left alone to finish on
the unfixed binary, and fataepyc-01 installs the fixed one only afterwards, on its way into
shard 3.

## Disk reclaimed

The three finished NDS-rerun proof trees were deleted, ~10 TB in total, after checking that
each configuration's logs are in `/cluster/arthur/logs` — which is the entire reason logs
were moved out of the proof tree.

| node | tree | freed |
|---|---|---|
| fataepyc-01 | `gss/gss-nosupp-nds` | 825 GB |
| fataepyc-02 | `gss/gss-proof-nds` | 7.6 TB |
| fataepyc-06 | `gss/gss-cliques-nds` | 1.6 TB |

## Reproducing

```bash
bash scripts/companion_build.sh ft                          # -> /scratch/arthur/veripb_ft
bash scripts/companion_sample.sh ~/companion-sets 40        # -> the two instance lists
bash scripts/companion_proofs.sh --sync                     # move ~/trimnalyser-companion
bash scripts/companion_proofs.sh ~/companion-sets/set-all.txt gss-lazy     # phase 1
JOBS=16 TT=3600 VT=3600 bash scripts/companion_compare.sh \
     ~/companion-sets/set-all.txt /scratch/arthur/companion/proofs \
     /scratch/arthur/companion/compare.csv                                 # phase 2
julia scripts/companion_table.jl /scratch/arthur/companion/compare.csv \
     --tex=tab-configs-companion.tex
```

Two traps, both hit once already:

* **`tmux new-session` does not source `.bashrc`**, so `julia` is not on `PATH`. Every
  session here is launched as `tmux new-session -d -s X "bash -lc '…'"`.
* **A compute node reaches the outside world only through the head**, so `git fetch` of
  an unreachable remote does not fail — it hangs on connect, silently, forever. Every
  fetch in these scripts is `timeout`-bounded.

## Open

- [ ] fill `tab:configs-companion` and the four `\ph` of `sections/5-compression.tex`
- [ ] send the `wiplvl` label bug upstream, with the minimised repro
