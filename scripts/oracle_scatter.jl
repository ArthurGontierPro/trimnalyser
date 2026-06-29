#!/usr/bin/env julia
# Scatter plots comparing Glasgow search nodes across oracle conditions.
# Two log-log charts:
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
    "LV"           => "#1f77b4",
    "bio"          => "#2ca02c",
    "images-CVIU11"=> "#d62728",
    "images-PR15"  => "#ff7f0e",
    "meshes-CVIU11"=> "#9467bd",
    "phase"        => "#8c564b",
    "scalefree"    => "#e377c2",
    "si"           => "#7f7f7f",
    "unknown"      => "#bcbd22",
)

families = sort(unique(df.family))

# ── Build per-family traces for one scatter ──────────────────────────────────

function make_traces(df_filtered, xcol, ycol, xlab, ylab)
    traces = String[]
    for fam in families
        sub = filter(r -> r.family == fam, df_filtered)
        isempty(sub) && continue
        color = get(FAMILY_COLORS, fam, "#333333")

        xs    = sub[!, xcol]
        ys    = sub[!, ycol]
        names = sub.instance

        hover = [@sprintf("%s<br>%s: %d<br>%s: %d<br>ratio: %.3f",
                          names[i], xlab, xs[i], ylab, ys[i],
                          ys[i] / xs[i])
                 for i in eachindex(xs)]

        xs_js    = "[" * join(xs,    ",") * "]"
        ys_js    = "[" * join(ys,    ",") * "]"
        names_js = "[" * join(map(n -> "\"$n\"", names), ",") * "]"
        hover_js = "[" * join(map(h -> "\"$h\"", hover), ",") * "]"

        push!(traces, """
{
  x: $xs_js, y: $ys_js,
  mode: 'markers',
  type: 'scatter',
  name: $(repr(fam)),
  text: $hover_js,
  hovertemplate: '%{text}<extra></extra>',
  marker: { color: $(repr(color)), size: 5, opacity: 0.7 }
}""")
    end
    traces
end

function diag_trace(all_x, all_y)
    lo = max(1, min(minimum(all_x), minimum(all_y)))
    hi = max(maximum(all_x), maximum(all_y))
    """
{
  x: [$lo, $hi], y: [$lo, $hi],
  mode: 'lines', type: 'scatter',
  name: 'y = x',
  line: { color: '#333', width: 1, dash: 'dash' },
  hoverinfo: 'skip',
  showlegend: true
}"""
end

function scatter_div(div_id, title, traces, all_x, all_y, xlab, ylab, n_total, n_shown)
    all_traces = vcat(traces, diag_trace(all_x, all_y))
    traces_js  = join(all_traces, ",\n")
    subtitle   = "n=$n_shown shown ($(n_total - n_shown) trivial/missing excluded) · points below diagonal = $ylab wins"
    """
<div id="$div_id" style="width:100%;height:600px;"></div>
<script>
Plotly.newPlot('$div_id',
[$traces_js],
{
  title: { text: $(repr(title * "<br><sup>" * subtitle * "</sup>")), font: { size: 15 } },
  xaxis: { title: $(repr(xlab * " nodes")), type: 'log', exponentformat: 'power' },
  yaxis: { title: $(repr(ylab * " nodes")), type: 'log', exponentformat: 'power' },
  legend: { orientation: 'v', x: 1.02, xanchor: 'left' },
  margin: { r: 160 },
  hovermode: 'closest'
},
{ responsive: true }
);
</script>
"""
end

# ── Chart 1: cone vs baseline ────────────────────────────────────────────────

df1 = filter(r -> r.baseline_nodes > 0 && r.cone_nodes > 0, df)
n1_total = nrow(df)
n1_shown = nrow(df1)
t1 = make_traces(df1, :baseline_nodes, :cone_nodes, "baseline", "cone")
chart1 = scatter_div("chart1",
    "Cone order vs baseline — search nodes (log-log)",
    t1, df1.baseline_nodes, df1.cone_nodes,
    "baseline", "cone", n1_total, n1_shown)

# ── Chart 2: cone vs full ────────────────────────────────────────────────────

df2 = filter(r -> r.full_nodes > 0 && r.cone_nodes > 0, df)
n2_total = nrow(df)
n2_shown = nrow(df2)
t2 = make_traces(df2, :full_nodes, :cone_nodes, "full", "cone")
chart2 = scatter_div("chart2",
    "Cone order vs full-proof order — search nodes (log-log)",
    t2, df2.full_nodes, df2.cone_nodes,
    "full proof", "cone", n2_total, n2_shown)

# ── Stats summary ────────────────────────────────────────────────────────────

function ratio_stats(df_f, xcol, ycol)
    ratios = df_f[!, ycol] ./ df_f[!, xcol]
    wins   = count(r -> r < 1.0, ratios)
    ties   = count(r -> r == 1.0, ratios)
    losses = count(r -> r > 1.0, ratios)
    med    = round(median(ratios); digits=3)
    mn     = round(mean(ratios);   digits=3)
    (wins=wins, ties=ties, losses=losses, median=med, mean=mn, n=length(ratios))
end

s1 = ratio_stats(df1, :baseline_nodes, :cone_nodes)
s2 = ratio_stats(df2, :full_nodes, :cone_nodes)

stats_html = """
<table style="border-collapse:collapse;font-size:14px;margin:20px auto;">
<thead>
<tr style="background:#f0f0f0;">
  <th style="padding:8px 16px;border:1px solid #ccc;">Comparison</th>
  <th style="padding:8px 16px;border:1px solid #ccc;">n</th>
  <th style="padding:8px 16px;border:1px solid #ccc;">Wins (Y &lt; X)</th>
  <th style="padding:8px 16px;border:1px solid #ccc;">Ties</th>
  <th style="padding:8px 16px;border:1px solid #ccc;">Losses</th>
  <th style="padding:8px 16px;border:1px solid #ccc;">Median ratio</th>
  <th style="padding:8px 16px;border:1px solid #ccc;">Mean ratio</th>
</tr>
</thead>
<tbody>
<tr>
  <td style="padding:8px 16px;border:1px solid #ccc;">cone vs baseline</td>
  <td style="padding:8px 16px;border:1px solid #ccc;">{s1_n}</td>
  <td style="padding:8px 16px;border:1px solid #ccc;color:green;">{s1_wins}</td>
  <td style="padding:8px 16px;border:1px solid #ccc;">{s1_ties}</td>
  <td style="padding:8px 16px;border:1px solid #ccc;color:red;">{s1_losses}</td>
  <td style="padding:8px 16px;border:1px solid #ccc;">{s1_med}</td>
  <td style="padding:8px 16px;border:1px solid #ccc;">{s1_mean}</td>
</tr>
<tr>
  <td style="padding:8px 16px;border:1px solid #ccc;">cone vs full</td>
  <td style="padding:8px 16px;border:1px solid #ccc;">{s2_n}</td>
  <td style="padding:8px 16px;border:1px solid #ccc;color:green;">{s2_wins}</td>
  <td style="padding:8px 16px;border:1px solid #ccc;">{s2_ties}</td>
  <td style="padding:8px 16px;border:1px solid #ccc;color:red;">{s2_losses}</td>
  <td style="padding:8px 16px;border:1px solid #ccc;">{s2_med}</td>
  <td style="padding:8px 16px;border:1px solid #ccc;">{s2_mean}</td>
</tr>
</tbody>
</table>
"""
stats_html = replace(stats_html,
    "{s1_n}" => s1.n, "{s1_wins}" => s1.wins, "{s1_ties}" => s1.ties,
    "{s1_losses}" => s1.losses, "{s1_med}" => s1.median, "{s1_mean}" => s1.mean,
    "{s2_n}" => s2.n, "{s2_wins}" => s2.wins, "{s2_ties}" => s2.ties,
    "{s2_losses}" => s2.losses, "{s2_med}" => s2.median, "{s2_mean}" => s2.mean,
)

# ── Write HTML ───────────────────────────────────────────────────────────────

html = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Oracle replay scatter</title>
<script src="https://cdn.plot.ly/plotly-2.27.0.min.js"></script>
<style>
  body { font-family: sans-serif; max-width: 1100px; margin: 0 auto; padding: 20px; }
  h1 { font-size: 20px; }
  h2 { font-size: 16px; margin-top: 40px; }
  p.note { font-size: 13px; color: #555; }
</style>
</head>
<body>
<h1>Oracle replay — branching order comparison</h1>
<p class="note">
  <b>cone</b>: order derived from the UNSAT cone (minimal proof subset) ·
  <b>full</b>: order derived from the entire proof · <b>baseline</b>: Glasgow default heuristic<br>
  Axes are log-scale. Points <em>below</em> the dashed diagonal mean the Y-axis condition explores fewer nodes.
  Ratio &lt; 1 = Y wins.
</p>

$stats_html

<h2>Chart 1 — cone vs baseline</h2>
$chart1

<h2>Chart 2 — cone vs full-proof order</h2>
$chart2

</body>
</html>
"""

write(html_path, html)
println("Written: $html_path  ($n1_shown / $n1_total instances in chart 1, $n2_shown / $n2_total in chart 2)")
println(@sprintf("cone vs base : %d wins / %d losses / %d ties  (median ratio %.3f)",
    s1.wins, s1.losses, s1.ties, s1.median))
println(@sprintf("cone vs full : %d wins / %d losses / %d ties  (median ratio %.3f)",
    s2.wins, s2.losses, s2.ties, s2.median))
