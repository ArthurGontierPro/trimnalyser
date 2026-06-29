#!/usr/bin/env julia
# Scatter plots comparing Glasgow search nodes across oracle conditions.
# Two log-log charts (Chart.js, same CDN as proof_survey / cone_vs_full):
#   1. cone vs baseline  — does the cone order reduce search?
#   2. cone vs full      — does trimming (cone) improve the full-proof oracle?
# Points below the y=x diagonal are wins for the Y axis condition.
# Color-coded by instance family; hover shows instance name and exact values.
# Timeouts (nodes = -1) and trivial instances (nodes = 0) are excluded per chart.
#
# Usage:
#   julia --project=scripts scripts/oracle_scatter.jl <oracle_replay_results.csv> [output.html]

using CSV, DataFrames, Printf, Statistics

if length(ARGS) < 1
    println("Usage: julia --project=scripts scripts/oracle_scatter.jl <oracle_replay_results.csv> [output.html]")
    exit(1)
end

csv_path  = ARGS[1]
html_path = length(ARGS) >= 2 ? ARGS[2] : "oracle_scatter.html"

isfile(csv_path) || (println("File not found: $csv_path"); exit(1))

df = CSV.read(csv_path, DataFrame)

const FAMILY_COLORS = Dict(
    "LV"            => "#1f77b4",
    "bio"           => "#2ca02c",
    "images-CVIU11" => "#d62728",
    "images-PR15"   => "#ff7f0e",
    "meshes-CVIU11" => "#9467bd",
    "phase"         => "#8c564b",
    "scalefree"     => "#e377c2",
    "si"            => "#7f7f7f",
    "unknown"       => "#bcbd22",
)

families = sort(unique(df.family))

function js_str(s)
    # Escape for JS single-quoted string
    replace(replace(s, "\\" => "\\\\"), "'" => "\\'")
end

function make_datasets(df_f, xcol, ycol)
    parts = String[]
    for fam in families
        sub = filter(r -> r.family == fam, df_f)
        isempty(sub) && continue
        color = get(FAMILY_COLORS, fam, "#333333")
        xs    = sub[!, xcol]
        ys    = sub[!, ycol]
        names = sub.instance
        pts   = join([@sprintf("{x:%d,y:%d,ins:'%s'}", xs[i], ys[i], js_str(names[i]))
                      for i in eachindex(xs)], ",")
        push!(parts, """
    {
      label: '$(js_str(fam))',
      data: [$pts],
      backgroundColor: '$color',
      pointRadius: 3, pointHoverRadius: 6
    }""")
    end
    parts
end

function diag_dataset(all_x, all_y)
    lo = max(1, min(minimum(all_x), minimum(all_y)))
    hi = max(maximum(all_x), maximum(all_y))
    """
    {
      label: 'y = x',
      data: [{x:$lo,y:$lo},{x:$hi,y:$hi}],
      showLine: true, pointRadius: 0,
      borderColor: '#333', borderWidth: 1,
      borderDash: [6,4], backgroundColor: 'transparent'
    }"""
end

function chart_block(canvas_id, title, datasets, all_x, all_y, xlab, ylab, n_total, n_shown)
    all_ds = vcat(datasets, diag_dataset(all_x, all_y))
    ds_js  = join(all_ds, ",")
    lo = max(1, min(minimum(all_x), minimum(all_y)))
    hi = max(maximum(all_x), maximum(all_y))
    subtitle = "n=$n_shown ($(n_total-n_shown) trivial/missing excluded) — below diagonal = $ylab wins"
    """
<canvas id="$canvas_id" height="500"></canvas>
<p style="text-align:center;font-size:12px;color:#555;">$subtitle</p>
<script>
new Chart(document.getElementById('$canvas_id'), {
  type: 'scatter',
  data: { datasets: [$ds_js] },
  options: {
    responsive: true,
    plugins: {
      title: { display: true, text: '$(js_str(title))', font: { size: 14 } },
      tooltip: {
        callbacks: {
          label: (ctx) => {
            const d = ctx.raw;
            const r = (d.y / d.x).toFixed(3);
            return d.ins ? d.ins + ': x=' + d.x + ' y=' + d.y + ' ratio=' + r : '';
          }
        }
      }
    },
    scales: {
      x: { type: 'logarithmic', title: { display: true, text: '$(js_str(xlab))' }, min: $lo, max: $hi },
      y: { type: 'logarithmic', title: { display: true, text: '$(js_str(ylab))' }, min: $lo, max: $hi }
    }
  }
});
</script>
"""
end

# ── Chart 1: cone vs baseline ────────────────────────────────────────────────

df1      = filter(r -> r.baseline_nodes > 0 && r.cone_nodes > 0, df)
n1_shown = nrow(df1)
ds1      = make_datasets(df1, :baseline_nodes, :cone_nodes)
c1       = chart_block("c1", "Cone order vs baseline — search nodes (log-log)",
                        ds1, df1.baseline_nodes, df1.cone_nodes,
                        "baseline nodes", "cone nodes", nrow(df), n1_shown)

# ── Chart 2: cone vs full ────────────────────────────────────────────────────

df2      = filter(r -> r.full_nodes > 0 && r.cone_nodes > 0, df)
n2_shown = nrow(df2)
ds2      = make_datasets(df2, :full_nodes, :cone_nodes)
c2       = chart_block("c2", "Cone order vs full-proof order — search nodes (log-log)",
                        ds2, df2.full_nodes, df2.cone_nodes,
                        "full-proof nodes", "cone nodes", nrow(df), n2_shown)

# ── Stats table ──────────────────────────────────────────────────────────────

function stats(df_f, xcol, ycol)
    r = df_f[!, ycol] ./ df_f[!, xcol]
    (n=length(r), wins=count(<(1.0), r), ties=count(==(1.0), r),
     losses=count(>(1.0), r), med=round(median(r); digits=3), mn=round(mean(r); digits=3))
end

s1 = stats(df1, :baseline_nodes, :cone_nodes)
s2 = stats(df2, :full_nodes,     :cone_nodes)

trow(label, s) = """
<tr>
  <td>$label</td><td>$(s.n)</td>
  <td style="color:green">$(s.wins)</td><td>$(s.ties)</td>
  <td style="color:red">$(s.losses)</td>
  <td>$(s.med)</td><td>$(s.mn)</td>
</tr>"""

table = """
<table style="border-collapse:collapse;font-size:14px;margin:16px auto;">
<thead><tr style="background:#f0f0f0;">
  <th style="padding:6px 14px;border:1px solid #ccc;">Comparison</th>
  <th style="padding:6px 14px;border:1px solid #ccc;">n</th>
  <th style="padding:6px 14px;border:1px solid #ccc;">Wins (Y&lt;X)</th>
  <th style="padding:6px 14px;border:1px solid #ccc;">Ties</th>
  <th style="padding:6px 14px;border:1px solid #ccc;">Losses</th>
  <th style="padding:6px 14px;border:1px solid #ccc;">Median ratio</th>
  <th style="padding:6px 14px;border:1px solid #ccc;">Mean ratio</th>
</tr></thead>
<tbody>
$(trow("cone vs baseline", s1))
$(trow("cone vs full", s2))
</tbody></table>"""

# ── Write HTML ───────────────────────────────────────────────────────────────

html = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Oracle replay scatter</title>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js"></script>
<style>
  body { font-family: sans-serif; max-width: 1000px; margin: 0 auto; padding: 20px; }
  h1 { font-size: 20px; }
  h2 { font-size: 16px; margin-top: 36px; }
  p.note { font-size: 13px; color: #555; }
  td, th { border: 1px solid #ccc; padding: 6px 14px; }
</style>
</head>
<body>
<h1>Oracle replay — branching order comparison</h1>
<p class="note">
  <b>cone</b>: order derived from UNSAT cone (minimal subset) ·
  <b>full</b>: order from entire proof ·
  <b>baseline</b>: Glasgow default heuristic.<br>
  Log-log axes. Points <em>below</em> the dashed diagonal = Y-axis condition wins (fewer nodes).
</p>

$table

<h2>Chart 1 — cone vs baseline</h2>
$c1

<h2>Chart 2 — cone vs full-proof order</h2>
$c2

</body>
</html>
"""

write(html_path, html)
println("Written: $html_path")
println(@sprintf("cone vs base: %d wins / %d losses / %d ties  median=%.3f", s1.wins, s1.losses, s1.ties, s1.med))
println(@sprintf("cone vs full: %d wins / %d losses / %d ties  median=%.3f", s2.wins, s2.losses, s2.ties, s2.med))
