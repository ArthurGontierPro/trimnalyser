#!/usr/bin/env python3
"""
Quick statistics from cluster results CSV (no dependencies beyond pandas).
Prints summary to terminal and saves to text file.

Usage: python3 quick_stats.py cluster_results.csv [output.txt]
"""

import pandas as pd
import sys
from pathlib import Path

def load_and_clean(csv_path):
    df = pd.read_csv(csv_path)
    # Convert boolean columns
    bool_cols = ['is_sat', 'is_unsat', 'has_proof', 'proof_truncated', 'has_error']
    for col in bool_cols:
        if col in df.columns:
            df[col] = df[col].map({'true': True, 'false': False, True: True, False: False})
    return df

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

    # Redirect output to both file and terminal
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

        # Overall counts
        print_section("OVERVIEW")
        print(f"Total instances:      {len(df):>10,}")
        print(f"SAT instances:        {df['is_sat'].sum():>10,}  ({df['is_sat'].sum()/len(df)*100:.1f}%)")
        print(f"UNSAT instances:      {df['is_unsat'].sum():>10,}  ({df['is_unsat'].sum()/len(df)*100:.1f}%)")
        print(f"With proof:           {df['has_proof'].sum():>10,}  ({df['has_proof'].sum()/len(df)*100:.1f}%)")
        print(f"Truncated proofs:     {df['proof_truncated'].sum():>10,}  ({df['proof_truncated'].sum()/len(df)*100:.1f}%)")
        print(f"Errors:               {df['has_error'].sum():>10,}  ({df['has_error'].sum()/len(df)*100:.1f}%)")

        resolv_count = (df['resolv_iterations'] > 0).sum() if 'resolv_iterations' in df.columns else 0
        print(f"Resolv iterations:    {resolv_count:>10,}")

        # Skip reasons
        if 'skip_reason' in df.columns:
            skip_counts = df[df['skip_reason'].notna()]['skip_reason'].value_counts()
            if not skip_counts.empty:
                print_section("SKIP REASONS")
                for reason, count in skip_counts.items():
                    pct = (count / len(df)) * 100
                    print(f"{reason:<30} {count:>8,}  ({pct:>5.1f}%)")

        # Error types
        if 'error_type' in df.columns and df['has_error'].sum() > 0:
            error_counts = df[df['has_error'] == True]['error_type'].value_counts()
            if not error_counts.empty:
                print_section("ERROR TYPES")
                for err_type, count in error_counts.items():
                    pct = (count / df['has_error'].sum()) * 100
                    print(f"{err_type:<30} {count:>8,}  ({pct:>5.1f}%)")

        # Filter to instances with proofs for timing stats
        proof_df = df[df['has_proof'] == True]

        if not proof_df.empty:
            # Timing statistics
            print_section("TIMING STATISTICS (instances with proofs)")
            time_cols = {
                'Parse Time': 'grim_parse_time',
                'Trim Time': 'grim_trim_time',
                'Write Time': 'grim_write_time',
                'Total Time': 'grim_total_time'
            }

            for label, col in time_cols.items():
                if col in proof_df.columns and not proof_df[col].isna().all():
                    data = proof_df[col].dropna()
                    print(f"\n{label}:")
                    print(f"  Mean:      {data.mean():>10.2f} s")
                    print(f"  Median:    {data.median():>10.2f} s")
                    print(f"  Min:       {data.min():>10.2f} s")
                    print(f"  Max:       {data.max():>10.2f} s")
                    print(f"  Std Dev:   {data.std():>10.2f} s")
                    print(f"  95th %ile: {data.quantile(0.95):>10.2f} s")

            # Size statistics
            print_section("SIZE STATISTICS (instances with proofs)")
            if 'inp_total_size' in proof_df.columns and 'grim_total_size' in proof_df.columns:
                inp_total = proof_df['inp_total_size'].sum()
                out_total = proof_df['grim_total_size'].sum()
                reduction = (inp_total - out_total) / inp_total * 100

                print(f"Total input size:     {inp_total/1024**3:>10.2f} GB")
                print(f"Total output size:    {out_total/1024**3:>10.2f} GB")
                print(f"Total reduction:      {reduction:>10.1f} %")

            # Constraint reduction
            if 'inp_total_nbeq' in proof_df.columns and 'grim_total_cone' in proof_df.columns:
                proof_df['constraint_reduction'] = (
                    (proof_df['inp_total_nbeq'] - proof_df['grim_total_cone']) /
                    proof_df['inp_total_nbeq']
                )
                valid = proof_df['constraint_reduction'].dropna()
                if not valid.empty:
                    print(f"\nConstraint Reduction Ratio:")
                    print(f"  Mean:      {valid.mean():>10.1%}")
                    print(f"  Median:    {valid.median():>10.1%}")
                    print(f"  Min:       {valid.min():>10.1%}")
                    print(f"  Max:       {valid.max():>10.1%}")

            # Literal reduction
            if 'grim_cone_literals' in proof_df.columns and 'grim_smol_literals' in proof_df.columns:
                proof_df['literal_reduction'] = (
                    (proof_df['grim_cone_literals'] - proof_df['grim_smol_literals']) /
                    proof_df['grim_cone_literals']
                )
                valid = proof_df['literal_reduction'].dropna()
                if not valid.empty:
                    print(f"\nLiteral Reduction Ratio:")
                    print(f"  Mean:      {valid.mean():>10.1%}")
                    print(f"  Median:    {valid.median():>10.1%}")
                    print(f"  Min:       {valid.min():>10.1%}")
                    print(f"  Max:       {valid.max():>10.1%}")

            # Core statistics
            if 'core_pattern_nodes' in proof_df.columns and 'core_pattern_total' in proof_df.columns:
                core_df = proof_df[proof_df['core_pattern_nodes'].notna()]
                if not core_df.empty:
                    print_section("UNSAT CORE STATISTICS")
                    print(f"Instances with cores: {len(core_df):>10,}")

                    pat_reduction = (
                        (core_df['core_pattern_total'] - core_df['core_pattern_nodes']) /
                        core_df['core_pattern_total']
                    )
                    tar_reduction = (
                        (core_df['core_target_total'] - core_df['core_target_nodes']) /
                        core_df['core_target_total']
                    )

                    print(f"\nPattern Core Reduction:")
                    print(f"  Mean:      {pat_reduction.mean():>10.1%}")
                    print(f"  Median:    {pat_reduction.median():>10.1%}")

                    print(f"\nTarget Core Reduction:")
                    print(f"  Mean:      {tar_reduction.mean():>10.1%}")
                    print(f"  Median:    {tar_reduction.median():>10.1%}")

            # Outliers (IQR method)
            print_section("OUTLIERS (> 1.5 IQR)")

            outlier_cols = {
                'Total Time': 'grim_total_time',
                'Trim Time': 'grim_trim_time',
            }

            for label, col in outlier_cols.items():
                if col in proof_df.columns:
                    data = proof_df[col].dropna()
                    Q1 = data.quantile(0.25)
                    Q3 = data.quantile(0.75)
                    IQR = Q3 - Q1
                    outliers = proof_df[
                        (proof_df[col] < Q1 - 1.5*IQR) |
                        (proof_df[col] > Q3 + 1.5*IQR)
                    ]
                    if not outliers.empty:
                        print(f"\n{label} Outliers ({len(outliers)}):")
                        for idx, row in outliers.nlargest(5, col).iterrows():
                            print(f"  {row['instance']:<30} {row[col]:>10.2f} s")

            # Top 10 slowest
            print_section("TOP 10 SLOWEST INSTANCES")
            if 'grim_total_time' in proof_df.columns:
                slowest = proof_df.nlargest(10, 'grim_total_time')
                for idx, row in slowest.iterrows():
                    inp = row['inp_total_nbeq'] if 'inp_total_nbeq' in row else 0
                    cone = row['grim_total_cone'] if 'grim_total_cone' in row else 0
                    print(f"{row['instance']:<30} {row['grim_total_time']:>8.1f}s  inp={inp:>7,}  cone={cone:>7,}")

            # Top 10 best reductions
            if 'constraint_reduction' in proof_df.columns:
                print_section("TOP 10 BEST CONSTRAINT REDUCTIONS")
                best = proof_df.nlargest(10, 'constraint_reduction')
                for idx, row in best.iterrows():
                    inp = row['inp_total_nbeq'] if 'inp_total_nbeq' in row else 0
                    cone = row['grim_total_cone'] if 'grim_total_cone' in row else 0
                    ratio = row['constraint_reduction']
                    print(f"{row['instance']:<30} {ratio:>6.1%}  ({inp:>7,} → {cone:>7,})")

        print("\n" + "="*70)
        print(f"Summary saved to: {output_file}")

        sys.stdout = original_stdout

    print(f"\n✓ Analysis complete!")
    print(f"  Results saved to: {output_file}")

if __name__ == '__main__':
    main()
