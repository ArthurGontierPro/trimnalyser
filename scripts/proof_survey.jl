#!/usr/bin/env julia
# M3 first-pass analysis: family-stratified proof structure + graph feature correlations.
# Generates a self-contained HTML report (no external assets needed beyond Chart.js CDN).
#
# Usage:
#   julia --project=scripts scripts/proof_survey.jl cluster_results.csv [graph_features.csv] [output.html]

using CSV, DataFrames, Statistics, Printf

# ── Helpers ──────────────────────────────────────────────────────────────────

function nonnull(df, col)
    col ∉ names(df) && return Float64[]
    Float64[x for x in skipmissing(df[!, col])]
end

fmtf(x, d=2)  = isnan(x) ? "—" : @sprintf("%.*f", d, x)
fmtpct(x)     = isnan(x) ? "—" : @sprintf("%.1f%%", x * 100)
med(v)        = isempty(v) ? NaN : median(v)
avg(v)        = isempty(v) ? NaN : mean(v)

function pearson_r(xs, ys)
    pairs = [(x, y) for (x, y) in zip(xs, ys) if !isnan(x) && !isnan(y)]
    length(pairs) < 5 && return NaN, 0
    cor([p[1] for p in pairs], [p[2] for p in pairs]), length(pairs)
end

# ── HTML helpers ─────────────────────────────────────────────────────────────

const CSS = """
body{font-family:monospace;max-width:1150px;margin:40px auto;padding:0 20px;background:#fafafa;color:#222}
h1{border-bottom:2px solid #333;padding-bottom:8px}
h2{margin-top:40px;border-bottom:1px solid #aaa;color:#333}
table{border-collapse:collapse;margin:12px 0;font-size:13px;width:auto}
th{background:#333;color:#fff;padding:6px 14px;text-align:right;white-space:nowrap}
th:first-child{text-align:left}
td{padding:5px 14px;border-bottom:1px solid #ddd;text-align:right;white-space:nowrap}
td:first-child{text-align:left;font-weight:bold}
tr:nth-child(even) td{background:#f2f2f2}
.chart-box{width:680px;height:320px;margin:18px 0}
p.note{color:#666;font-size:12px;margin:4px 0}
"""

function html_table(headers, rows)
    buf = IOBuffer()
    println(buf, "<table><thead><tr>")
    for h in headers; print(buf, "<th>$h</th>"); end
    println(buf, "</tr></thead><tbody>")
    for row in rows
        print(buf, "<tr>")
        for cell in row; print(buf, "<td>$cell</td>"); end
        println(buf, "</tr>")
    end
    println(buf, "</tbody></table>")
    String(take!(buf))
end

json_str_arr(v)   = "[" * join(("\"$x\"" for x in v), ",") * "]"
json_num_arr(v)   = "[" * join((isnan(x) ? "null" : @sprintf("%.4f", x) for x in v), ",") * "]"

function stacked_bar_chart(id, labels, datasets)
    # datasets: Vector of (label, color, num_array_json)
    ds = join(["{ label: \"$(d[1])\", backgroundColor: \"$(d[2])\", data: $(d[3]) }"
               for d in datasets], ",\n")
    """
    <div class="chart-box"><canvas id="$id"></canvas></div>
    <script>
    new Chart(document.getElementById("$id"), {
      type: "bar",
      data: { labels: $(json_str_arr(labels)), datasets: [$ds] },
      options: {
        responsive: true, maintainAspectRatio: false,
        plugins: { legend: { position: "top" } },
        scales: {
          x: { stacked: true },
          y: { stacked: true, min: 0, max: 1,
               title: { display: true, text: "fraction of cone steps" } }
        }
      }
    });
    </script>
    """
end

# ── Family list ───────────────────────────────────────────────────────────────

const FAMILIES = ["LV", "bio", "images-CVIU11", "images-PR15", "meshes-CVIU11",
                  "phase", "scalefree", "si"]

# ── Main ─────────────────────────────────────────────────────────────────────

function main()
    length(ARGS) < 1 && (println("Usage: julia proof_survey.jl <cluster.csv> [graph.csv] [out.html]"); exit(1))

    cluster_csv = ARGS[1]
    graph_csv   = nothing
    out_html    = "proof_survey.html"
    for arg in ARGS[2:end]
        if endswith(arg, ".html"); out_html = arg
        elseif endswith(arg, ".csv") && isfile(arg); graph_csv = arg
        end
    end

    println("Loading $cluster_csv...")
    df = CSV.read(cluster_csv, DataFrame; missingstring=["", "NA"])
    for col in (:is_sat, :is_unsat, :has_proof, :proof_truncated, :has_error)
        col ∈ propertynames(df) || continue
        df[!, col] = map(x -> !ismissing(x) && (x == "true" || x == true), df[!, col])
    end

    gf = nothing
    if graph_csv !== nothing
        println("Loading $graph_csv...")
        gf = CSV.read(graph_csv, DataFrame; missingstring=["", "NA"])
    end

    jdf = gf !== nothing ? leftjoin(df, gf; on=:instance) : df

    n_total = nrow(df)
    n_proof = sum(df.has_proof)
    proof_jdf = jdf[jdf.has_proof .== true, :]

    # ── Gather per-family data ────────────────────────────────────────────────

    present = String[]
    fam_data = Dict{String, Any}()

    for fam in FAMILIES
        mask = isequal.(jdf.family, fam) .& (jdf.has_proof .== true)
        sub  = jdf[mask, :]
        nrow(sub) == 0 && continue
        push!(present, fam)

        fam_data[fam] = (
            n           = nrow(sub),
            med_cone    = med(nonnull(sub, "grim_total_cone")),
            med_depth   = med(nonnull(sub, "grim_cone_depth_max")),
            med_time    = med(nonnull(sub, "grim_total_time")),
            mean_rup    = avg(nonnull(sub, "grim_rup_frac")),
            mean_pol    = avg(nonnull(sub, "grim_pol_frac")),
            mean_ia     = avg(nonnull(sub, "grim_ia_frac")),
            mean_red    = avg(nonnull(sub, "grim_red_frac")),
            med_entropy = med(nonnull(sub, "grim_cone_depth_entropy")),
            med_botfrac = med(nonnull(sub, "grim_cone_bottom_frac")),
            med_p50     = med(nonnull(sub, "grim_cone_depth_p50")),
            med_p90     = med(nonnull(sub, "grim_cone_depth_p90")),
            burst_pct   = let bd = Float64[x for x in skipmissing(sub[!, "grim_pol_before_rup_burst"])]
                              isempty(bd) ? NaN : mean(==(1), bd)
                          end,
            n_resolv    = let ps = filter(x -> x > 0, nonnull(sub, "resolv_pat_shrinkage"))
                              length(ps)
                          end,
            mean_pat_sh = avg(filter(x -> x > 0, nonnull(sub, "resolv_pat_shrinkage"))),
            mean_tar_sh = avg(filter(x -> x > 0, nonnull(sub, "resolv_tar_shrinkage"))),
            max_pat_sh  = let ps = filter(x -> x > 0, nonnull(sub, "resolv_pat_shrinkage"))
                              isempty(ps) ? NaN : maximum(ps)
                          end,
        )
    end

    isempty(present) && (println("No families with proofs found."); exit(1))
    fd(f) = fam_data[f]

    # ── Section 1: Family overview ────────────────────────────────────────────
    ov_rows = [[f, fd(f).n, fmtf(fd(f).med_cone, 0), fmtf(fd(f).med_depth, 0), fmtf(fd(f).med_time)]
               for f in present]
    ov_html = html_table(["Family", "n proofs", "median cone size", "median depth max", "median time (s)"], ov_rows)

    # ── Section 2: Step type mix ──────────────────────────────────────────────
    st_rows = [[f, fd(f).n, fmtpct(fd(f).mean_rup), fmtpct(fd(f).mean_pol),
                fmtpct(fd(f).mean_ia), fmtpct(fd(f).mean_red)] for f in present]
    st_html = html_table(["Family", "n", "RUP %", "POL %", "IA %", "RED %"], st_rows)
    chart_html = stacked_bar_chart("stepChart", present,
        [("RUP", "#4e9af1", json_num_arr([fd(f).mean_rup for f in present])),
         ("POL", "#f18a4e", json_num_arr([fd(f).mean_pol for f in present])),
         ("IA",  "#5cb85c", json_num_arr([fd(f).mean_ia  for f in present])),
         ("RED", "#c44ef1", json_num_arr([fd(f).mean_red for f in present]))])

    # ── Section 3: Proof shape ────────────────────────────────────────────────
    sh_rows = [[f, fd(f).n, fmtf(fd(f).med_entropy, 3), fmtf(fd(f).med_botfrac, 3),
                fmtf(fd(f).med_p50, 1), fmtf(fd(f).med_p90, 1), fmtpct(fd(f).burst_pct)]
               for f in present]
    sh_html = html_table(
        ["Family", "n", "median entropy", "median bottom_frac", "median depth p50",
         "median depth p90", "POL-burst %"],
        sh_rows)

    # ── Section 4: Resolv shrinkage ───────────────────────────────────────────
    rs_rows = [[f, fd(f).n_resolv, fmtpct(fd(f).mean_pat_sh), fmtpct(fd(f).mean_tar_sh),
                fmtpct(fd(f).max_pat_sh)] for f in present]
    rs_html = html_table(
        ["Family", "n resolved", "mean pat shrinkage", "mean tar shrinkage", "max pat shrinkage"],
        rs_rows)

    # ── Section 5: Correlations with graph features ───────────────────────────
    corr_html = ""
    if gf !== nothing
        shrink_vals = [ismissing(x) ? NaN : Float64(x) for x in proof_jdf[!, :resolv_pat_shrinkage]]
        corr_features = [
            ("pat_density",    "Pattern density"),
            ("pat_deg_var",    "Pattern degree variance"),
            ("pat_diameter",   "Pattern diameter"),
            ("node_ratio",     "Node ratio (pat/tar)"),
            ("density_ratio",  "Density ratio (pat/tar)"),
            ("max_degree_ratio","Max degree ratio"),
        ]
        c_rows = []
        for (col, label) in corr_features
            col ∉ names(proof_jdf) && continue
            feat = [ismissing(x) ? NaN : Float64(x) for x in proof_jdf[!, col]]
            r, np = pearson_r(feat, shrink_vals)
            push!(c_rows, [label, isnan(r) ? "—" : @sprintf("%.3f", r), np])
        end
        corr_html = """
        <h2>Correlations with Pattern Node Shrinkage</h2>
        <p class="note">Pearson r between <code>resolv_pat_shrinkage</code> and graph structural features.
        Computed over proof instances only. Positive r = more shrinkage when feature is larger.</p>
        """ * html_table(["Graph feature", "Pearson r", "n pairs"], c_rows)
    end

    # ── Assemble HTML ─────────────────────────────────────────────────────────
    sources = cluster_csv * (gf !== nothing ? " + $graph_csv" : "")
    html = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <title>Proof Survey</title>
    <script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js"></script>
    <style>$CSS</style>
    </head>
    <body>
    <h1>Proof Survey</h1>
    <p class="note">Sources: $sources<br>
    Total instances: $n_total &nbsp;|&nbsp; With proofs: $n_proof &nbsp;|&nbsp;
    Families present: $(join(present, ", "))</p>

    <h2>1 — Family Overview</h2>
    <p class="note">Median cone size = number of constraints kept in trimmed proof.</p>
    $ov_html

    <h2>2 — Step Type Mix</h2>
    <p class="note">Mean fraction of each step type across all proof instances in the family.</p>
    $st_html
    $chart_html

    <h2>3 — Proof Shape</h2>
    <p class="note">
    entropy: Shannon entropy of per-depth step counts — 0 = all steps at same depth (chain), high = spread across many depths.<br>
    bottom_frac: fraction of cone steps at depth ≤ 2 (direct propagation from axioms).<br>
    POL-burst: fraction of instances where a POL step is immediately followed by a RUP surge at depth+1.</p>
    $sh_html

    <h2>4 — Resolv Shrinkage</h2>
    <p class="note">n resolved = instances where resolv ran and pattern graph shrank. Shrinkage = (initial − final) / initial.</p>
    $rs_html

    $corr_html
    </body>
    </html>
    """

    write(out_html, html)
    println("Wrote $out_html  ($n_total instances, $(length(present)) families)")
end

main()
