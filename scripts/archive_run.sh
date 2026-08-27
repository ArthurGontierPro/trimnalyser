#!/bin/bash
# Archive the M7 grid's raw record + the canonical aggregation into shared storage.
# /cluster is NFS and persistent; /scratch is node-local and has been wiped before,
# so nothing here may depend on /scratch surviving.
set -uo pipefail
STAMP="${1:-$(date +%Y-%m-%d)}"
DEST=/cluster/arthur/archive/m7-grid-$STAMP
LOGS=/cluster/arthur/logs
BENCH=/cluster/arthur/benchlogs
mkdir -p "$DEST"
cd ~/trimnalyser

echo "=== provenance ==="
{
  echo "archived_at   : $(date -Is)"
  echo "host          : $(hostname)"
  echo "git_commit    : $(git rev-parse HEAD)"
  echo "git_describe  : $(git log --oneline -1)"
  echo "grid_launched : 2026-08-24T19:13 (commits 184043a, 3e8740f)"
  echo "logs_src      : $LOGS"
  echo "benchlogs_src : $BENCH"
} > "$DEST/PROVENANCE.txt"
cat "$DEST/PROVENANCE.txt"

echo
echo "=== per-config completion (ground truth = per-instance logs) ==="
ls "$LOGS" | gawk '
/\.out$/{ f=$0; sub(/\.out$/,"",f); n=split(f,p,".")
  if (f !~ /\.core[0-9]+\./) base[p[n]]++; else core[p[n]]++ }
END{ printf "%-18s %9s %9s %8s\n","config","instances","cores","pct";
     for(c in base) printf "%-18s %9d %9d %7.1f%%\n", c, base[c], core[c], 100*base[c]/25590 }' \
  | sort -k2,2nr | tee "$DEST/COMPLETION.txt"

echo
echo "=== tar raw logs (this is THE record: proof dirs are deleted as the run proceeds) ==="
tar -C /cluster/arthur -cf - logs | zstd -T8 -3 -q -o "$DEST/logs.tar.zst" && echo "  logs.tar.zst $(du -h "$DEST/logs.tar.zst" | cut -f1)"
tar -C /cluster/arthur -cf - benchlogs | zstd -T8 -3 -q -o "$DEST/benchlogs.tar.zst" && echo "  benchlogs.tar.zst $(du -h "$DEST/benchlogs.tar.zst" | cut -f1)"

echo
echo "=== derived failure scan ==="
mkdir -p "$DEST/failing-pairs"
cp /cluster/arthur/scan/*.tsv /cluster/arthur/scan/[ABCD].txt "$DEST/failing-pairs/" 2>/dev/null
ls -la "$DEST/failing-pairs/"

echo
echo "=== canonical aggregation (all configs in one CSV; config is a column) ==="
julia --startup-file=no scripts/aggregate_results.jl /scratch/arthur/proofs/gss/gss-lazy \
      "$DEST/results.csv" "$LOGS" 2>&1 | tail -5
echo "  rows: $(( $(wc -l < "$DEST/results.csv") - 1 ))"

echo
echo "=== checksums ==="
( cd "$DEST" && find . -type f ! -name MANIFEST.sha256 -print0 | sort -z \
  | xargs -0 sha256sum > MANIFEST.sha256 && wc -l < MANIFEST.sha256 )
du -sh "$DEST"
echo "DONE -> $DEST"
