# `veripb trim` resolves a shadowed `pol` label against the *final* binding, not the line's

Branch `feature_trimmer`, tip `e98c4a31`, plus our earlier `ia`-hint fix
(`docs/veripb-trimmer-label-bug.md`). Found and fixed 2026-09-07.

This is the **second, unrelated** defect in the same branch. The first one rejected a proof
at parse time (`TRIM FAILED`); this one trims happily and emits a proof that no verifier
will accept (`TRIM OK`, then `VERI FAILED`).

## Symptom

```
Error: Verification error at LVg200g86.ft.pbp:3

Caused by:
    Accessing the database out of bound with index 24171.
    The index should be between -24171 and 24170.
```

Always at the first affected line, always exactly one past the end of the database.

## The proof step

Glasgow writes steps that re-define the label they consume:

```
@adj0_0_1 pol @inj0 x2_0 w … x9_0 w @adj0_0_1 + s ;
   ↑ defines                             ↑ uses the SAME label
```

The operand `@adj0_0_1` is the **formula** constraint of that name (id 1071 in
`LVg200g86.opb`); the step then rebinds `@adj0_0_1` to the constraint it derives (24171).
The two trimmers disagree on which one the operand means:

```
tb (feature/trimmer-base):  pol 21 x2_0 w … x9_0 w   1071 + s;   correct
ft (feature_trimmer):       pol 21 x2_0 w … x9_0 w  24171 + s;   the id of this very step
```

## Root cause

`Trimmer` stores each `pol` line by **file offset only** (`trimmer.rs:99`,
`lazy_pol_info`) and does not parse its body during the forward pass. The body is
re-read and parsed later, from `LazyPolDerivation::get_lazy_pol_constraint`:

```rust
let initial_line = self.read_cp_line(initial_id)?;                    // decoration.rs:305
let initial_lex  = RuleToken::lexer(&initial_line);
let initial_inst = PolRule::parse(initial_lex, context)?.instructions; // :309
```

`PolRule::parse` resolves `@label` against `context.label_to_id`
(`rules/cutting_planes.rs:158`), which by then holds the bindings as of the **end** of the
proof — `trimmer.rs:51` has long since overwritten the formula's `@adj0_0_1` with the
derived id. So the operand resolves to the constraint the line is about to produce.

`Verifier` is unaffected: it evaluates `pol` during the forward pass, when the binding is
still the right one. That is why the full proof verifies and only the trimmed one fails.

## Fix

`/cluster/arthur/veripb-bug/fix-lazy-label-shadowing.patch`, on top of the `ia`-hint patch.
Four files, +75/−4. Keep the displaced binding and resolve relative to the line being
re-parsed:

* `context.rs` — new `shadowed_labels: AHashMap<String, Vec<(usize, isize)>>`, entries
  `(first constraint id at which this binding is in effect, constraint id)`. Written only
  when a label is actually re-defined, so it stays empty for almost every proof.
* `trimmer.rs` — before overwriting `label_to_id`, push the displaced binding.
* `rules/cutting_planes.rs` — `resolve_label` picks the last binding that became active
  **strictly before** the current line's own id, which is what excludes the self-reference.
* `trimmer/decoration.rs` — `read_cp_line` announces the id it just read through a
  thread-local that `PolRule::parse` *takes*. Chosen over threading the id through nine
  call sites: every lazy parse goes through `read_cp_line`, and `take()` guarantees the id
  applies to exactly one parse and never leaks into the forward pass.

## Validation

| | before | after |
|---|---|---|
| 6-line minimal repro | `pol 3 2 +` → rejected | `pol 1 2 +` → `s VERIFIED` |
| `LVg200g86` (44 self-ref steps) | rejected at `:3` | `s VERIFIED` |
| `LVg23g59` (566) | rejected at `:3` | `s VERIFIED` |
| `LVg38g47` (1260) | rejected at `:3` | `s VERIFIED` |
| `cviu11_p18_t127` (384) | rejected at `:3` | `s VERIFIED` |
| `LVg10g22` (0 self-ref, 675 hint refs) | `s VERIFIED` | `s VERIFIED`, **byte-identical** output |

The null control matters: `LVg10g22` exercises no shadowing, and its trimmed proof is
unchanged to the byte, so the patch does nothing where the mechanism cannot fire.

Causation was established independently of the patch, by rewriting only the self-referencing
operands to their numeric formula ids and leaving everything else alone
(`scripts/deshadow_pbp.py`). The rewritten full proofs still verify — so the rewrite is
semantics-preserving — and the unmodified `ft` binary then trims all four correctly.

## Predicting which instances are affected

A proof is affected iff some labelled step uses its own label as an operand:

```bash
awk '{ if ($1 ~ /^@/) { lab=$1; rest=substr($0, length(lab)+2);
                        if (index(rest, lab" ")>0) c++ } } END{print c+0}' <proof>.pbp
```

On the 2026-09-07 `gss-lazy-ft` run this accounted for **every** `VERI FAILED`: 340 of 1363
trimmed proofs (25%), 312 of them `cviu11` and 16 `LV`.

## Binaries

| file | sha256 (16) | what |
|---|---|---|
| `veripb_ft_unfixed` | `f365c47a88ec0b4f` | upstream `e98c4a31` |
| `veripb_ft_fixed`   | `b2b2abe8bce49fff` | + `ia`-hint fix — **has this bug** |
| `veripb_ft_fixed2`  | `5e8663ceae5c0540` | + this fix — the one to measure with |

All in `/cluster/arthur/veripb-bug/`, with their patches beside them.
