#!/usr/bin/env python3
"""
Quick statistics from cluster results CSV (no dependencies beyond pandas).
Prints summary to terminal and saves to text file.

Usage: python3 quick_stats.py cluster_results.csv [output.txt]
"""

import ast
import pandas as pd
import sys
from pathlib import Path


def load_and_clean(csv_path):
    df = pd.read_csv(csv_path)
    bool_cols = ['is_sat', 'is_unsat', 'has_proof', 'proof_truncated', 'has_error']
    for col in bool_cols:
        if col in df.columns:
            df[col] = df[col].map({'true': True, 'false': False, True: True, False: False})
    return df


def parse_list_col(series):
    """Parse a column of stringified lists like '[50,42,39]' into a list of lists."""
    result = []
    for v in series.dropna():
        try:
            parsed = ast.literal_eval(v) if isinstance(v, str) else v
            if isinstance(parsed, list):
                result.append(parsed)
        except Exception:
            pass
    return result


def print_section(title):
    print(f"\n{'='*70}")
    print(f" {title}")
    print('='*70)


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 quick_stats.py cluster_results.csv [output.txt]")
        sys.exit(1)

    csv_file = sys.argv[1]
    output_file = sys.argv[2] if len(sys.argv) > 2 else "stats_summary.txt"

    if not Path(csv_file).exists():
        print(f"Error: {csv_file} not found")
        sys.exit(1)

    print(f"Loading {csv_file}...")
    df = load_and_clean(csv_file)

    class Tee:
        def __init__(self, *files):
            self.files = files
        def write(self, data):
            for f in self.files:
                f.write(data)
        def flush(self):
            for f in self.files:
                f.flush()

    with open(output_file, 'w') as f:
        original_stdout = sys.stdout
        sys.stdout = Tee(sys.stdout, f)

        print(f"Cluster Results Analysis")
        print(f"CSV: {csv_file}")
        print(f"=" * 70)

        # ── Overview ──────────────────────────────────────────────────────────
        print_section("OVERVIEW")
        n = len(df)
        print(f"Total instances:      {n:>10,}")
        for col, label in [('is_sat','SAT'), ('is_unsat','UNSAT'), ('has_proof','With proof'),
                           ('proof_truncated','Truncated proofs'), ('has_error','Errors')]:
            if col in df.columns:
                c = df[col].sum()
                print(f"{label+':':<22} {int(c):>10,}  ({c/n*100:.1f}%)")

        if 'resolv_iterations' in df.columns:
            rc = (df['resolv_iterations'] > 0).sum()
            print(f"{'Resolv ran:':<22} {rc:>10,}  ({rc/n*100:.1f}%)")

        # ── Skip / error breakdown ─────────────────────────────────────────────
        if 'skip_reason' in df.columns:
            skip_counts = df[df['skip_reason'].notna()]['skip_reason'].value_counts()
            if not skip_counts.empty:
                print_section("SKIP REASONS")
                for reason, count in skip_counts.items():
                    print(f"  {reason:<35} {count:>7,}  ({count/n*100:.1f}%)")

        if 'error_type' in df.columns and df['has_error'].sum() > 0:
            error_counts = df[df['has_error'] == True]['error_type'].value_counts()
            if not error_counts.empty:
                print_section("ERROR TYPES")
                for err_type, count in error_counts.items():
                    print(f"  {err_type:<35} {count:>7,}  ({count/df['has_error'].sum()*100:.1f}%)")

        # ── Instances with proofs ──────────────────────────────────────────────
        proof_df = df[df['has_proof'] == True].copy()

        if proof_df.empty:
            print("\nNo instances with proofs found.")
            sys.stdout = original_stdout
            return

        # ── Timing ────────────────────────────────────────────────────────────
        print_section(f"TIMING STATISTICS  (n={len(proof_df):,} instances with proofs)")
        for label, col in [('Parse Time','grim_parse_time'), ('Trim Time','grim_trim_time'),
                           ('Write Time','grim_write_time'), ('Total Time','grim_total_time')]:
            if col in proof_df.columns:
                data = proof_df[col].dropna()
                if data.empty:
                    continue
                print(f"\n  {label}:")
                print(f"    Mean      {data.mean():>9.2f} s   Median {data.median():>9.2f} s")
                print(f"    Min       {data.min():>9.2f} s   Max    {data.max():>9.2f} s")
                print(f"    95th %ile {data.quantile(0.95):>9.2f} s   Std    {data.std():>9.2f} s")

        # ── Size / reduction ──────────────────────────────────────────────────
        print_section(f"SIZE & REDUCTION  (n={len(proof_df):,})")

        if 'inp_total_size' in proof_df.columns and 'grim_total_size' in proof_df.columns:
            valid = proof_df[['inp_total_size','grim_total_size']].dropna()
            if not valid.empty:
                inp_gb = valid['inp_total_size'].sum() / 1024**3
                out_gb = valid['grim_total_size'].sum() / 1024**3
                print(f"  Total input  {inp_gb:>8.2f} GB   Total output {out_gb:>8.2f} GB   "
                      f"Reduction {(1-out_gb/inp_gb)*100:.1f}%")

        if 'inp_total_nbeq' in proof_df.columns and 'grim_total_cone' in proof_df.columns:
            valid = proof_df[['inp_total_nbeq','grim_total_cone']].dropna()
            valid = valid[valid['inp_total_nbeq'] > 0]
            if not valid.empty:
                ratio = (valid['inp_total_nbeq'] - valid['grim_total_cone']) / valid['inp_total_nbeq']
                proof_df.loc[valid.index, 'constraint_reduction'] = ratio
                print(f"\n  Constraint reduction  mean {ratio.mean():>6.1%}   "
                      f"median {ratio.median():>6.1%}   "
                      f"min {ratio.min():>6.1%}   max {ratio.max():>6.1%}")

        if 'grim_cone_literals' in proof_df.columns and 'grim_smol_literals' in proof_df.columns:
            valid = proof_df[['grim_cone_literals','grim_smol_literals']].dropna()
            valid = valid[valid['grim_cone_literals'] > 0]
            if not valid.empty:
                ratio = (valid['grim_cone_literals'] - valid['grim_smol_literals']) / valid['grim_cone_literals']
                proof_df.loc[valid.index, 'literal_reduction'] = ratio
                print(f"  Literal reduction     mean {ratio.mean():>6.1%}   "
                      f"median {ratio.median():>6.1%}   "
                      f"min {ratio.min():>6.1%}   max {ratio.max():>6.1%}")

        # ── Cone step types (M2) ───────────────────────────────────────────────
        rup_col = 'grim_cone_rup'
        if rup_col in proof_df.columns and proof_df[rup_col].notna().any():
            step_cols = ['grim_cone_rup','grim_cone_pol','grim_cone_red','grim_cone_ia']
            step_df = proof_df[[c for c in step_cols if c in proof_df.columns]].dropna()
            if not step_df.empty:
                print_section(f"CONE STEP TYPES  (n={len(step_df):,})")
                total_steps = step_df.sum(axis=1)
                for col in step_df.columns:
                    label = col.replace('grim_cone_','').upper()
                    mean_n   = step_df[col].mean()
                    mean_pct = (step_df[col] / total_steps.replace(0, float('nan'))).mean()
                    print(f"  {label:<6}  mean count {mean_n:>9.1f}   mean share {mean_pct:>6.1%}   "
                          f"median {step_df[col].median():>7.0f}   max {step_df[col].max():>7.0f}")

        # ── Cone depth (M2) ───────────────────────────────────────────────────
        if 'grim_cone_depth_max' in proof_df.columns and proof_df['grim_cone_depth_max'].notna().any():
            dmax = proof_df['grim_cone_depth_max'].dropna()
            dmean = proof_df['grim_cone_depth_mean'].dropna() if 'grim_cone_depth_mean' in proof_df.columns else None
            print_section(f"CONE DAG DEPTH  (n={len(dmax):,})")
            print(f"  Max depth   mean {dmax.mean():>7.1f}   median {dmax.median():>7.1f}   "
                  f"min {dmax.min():>5.0f}   max {dmax.max():>5.0f}")
            if dmean is not None and not dmean.empty:
                print(f"  Mean depth  mean {dmean.mean():>7.2f}   median {dmean.median():>7.2f}   "
                      f"min {dmean.min():>5.2f}   max {dmean.max():>5.2f}")

        # ── Resolv loop (M2) ──────────────────────────────────────────────────
        if 'resolv_stop_reason' in df.columns and df['resolv_stop_reason'].notna().any():
            print_section("RESOLV LOOP")

            reasons = df['resolv_stop_reason'].value_counts()
            print(f"  Stop reason breakdown:")
            for reason, count in reasons.items():
                print(f"    {reason:<25} {count:>6,}  ({count/len(df)*100:.1f}%)")

            if 'resolv_iter_pat_nodes' in df.columns:
                lists = parse_list_col(df['resolv_iter_pat_nodes'])
                if lists:
                    n_iters = [len(l) - 1 for l in lists]   # iterations = len - 1 (iter 0 is initial)
                    shrinkages = [(l[0] - l[-1]) / l[0] for l in lists if l[0] > 0]
                    print(f"\n  Pattern graph shrinkage  (n={len(lists):,} instances that ran resolv):")
                    print(f"    Iterations  mean {sum(n_iters)/len(n_iters):.1f}   "
                          f"max {max(n_iters)}")
                    if shrinkages:
                        import statistics
                        print(f"    Node shrink mean {sum(shrinkages)/len(shrinkages):.1%}   "
                              f"median {statistics.median(shrinkages):.1%}   "
                              f"max {max(shrinkages):.1%}")

        # ── UNSAT core ────────────────────────────────────────────────────────
        if 'core_pattern_nodes' in proof_df.columns and proof_df['core_pattern_nodes'].notna().any():
            core_df = proof_df[proof_df['core_pattern_nodes'].notna()].copy()
            print_section(f"UNSAT CORE STATISTICS  (n={len(core_df):,})")
            for label, col in [('Pattern core nodes','core_pattern_nodes'),
                                ('Target core nodes', 'core_target_nodes')]:
                if col in core_df.columns:
                    data = core_df[col].dropna()
                    if not data.empty:
                        print(f"  {label:<25}  mean {data.mean():>8.1f}   "
                              f"median {data.median():>8.1f}   max {data.max():>8.0f}")

        # ── Outliers ──────────────────────────────────────────────────────────
        print_section("OUTLIERS (>1.5 IQR above Q3)")
        for label, col in [('Total Time','grim_total_time'), ('Trim Time','grim_trim_time')]:
            if col not in proof_df.columns:
                continue
            data = proof_df[col].dropna()
            Q1, Q3 = data.quantile(0.25), data.quantile(0.75)
            outliers = proof_df[proof_df[col] > Q3 + 1.5*(Q3-Q1)]
            if not outliers.empty:
                print(f"\n  {label} outliers ({len(outliers)}):")
                for _, row in outliers.nlargest(5, col).iterrows():
                    inp  = int(row['inp_total_nbeq'])  if 'inp_total_nbeq'  in row and pd.notna(row['inp_total_nbeq'])  else 0
                    cone = int(row['grim_total_cone']) if 'grim_total_cone' in row and pd.notna(row['grim_total_cone']) else 0
                    print(f"    {row['instance']:<35} {row[col]:>8.1f}s  inp={inp:>8,}  cone={cone:>7,}")

        # ── Top 10 slowest ────────────────────────────────────────────────────
        if 'grim_total_time' in proof_df.columns:
            print_section("TOP 10 SLOWEST")
            for _, row in proof_df.nlargest(10, 'grim_total_time').iterrows():
                inp  = int(row['inp_total_nbeq'])  if pd.notna(row.get('inp_total_nbeq',  float('nan'))) else 0
                cone = int(row['grim_total_cone']) if pd.notna(row.get('grim_total_cone', float('nan'))) else 0
                print(f"  {row['instance']:<35} {row['grim_total_time']:>8.1f}s  "
                      f"inp={inp:>8,}  cone={cone:>7,}")

        # ── Top 10 best constraint reductions ─────────────────────────────────
        if 'constraint_reduction' in proof_df.columns:
            print_section("TOP 10 BEST CONSTRAINT REDUCTIONS")
            for _, row in proof_df.nlargest(10, 'constraint_reduction').iterrows():
                inp  = int(row['inp_total_nbeq'])  if pd.notna(row.get('inp_total_nbeq',  float('nan'))) else 0
                cone = int(row['grim_total_cone']) if pd.notna(row.get('grim_total_cone', float('nan'))) else 0
                print(f"  {row['instance']:<35} {row['constraint_reduction']:>6.1%}  "
                      f"({inp:>8,} → {cone:>7,})")

        print("\n" + "="*70)
        print(f"Summary saved to: {output_file}")
        sys.stdout = original_stdout

    print(f"\nAnalysis complete. Results saved to: {output_file}")


if __name__ == '__main__':
    main()
