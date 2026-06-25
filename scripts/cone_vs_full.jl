#!/usr/bin/env julia
# Mega barplot: full proof vs cone composition by label, per family.
# Two stacked bars per family (Full | Cone), all labels, normalized to full total.
# Charts: mean + median, each for all instances and for search-only instances.
#
# Usage:
#   julia --project=scripts scripts/cone_vs_full.jl cluster_results.csv [output.html]

using CSV, DataFrames, Statistics, Printf

# ── Label definitions ────────────────────────────────────────────────────────

const OPB_LABELS = [
    (:al1,   "al1 (≥1 domain)"),
    (:am1,   "am1 (≤1 domain)"),
    (:inj,   "inj (injectivity)"),
    (:g0adj, "g0adj (base adj)"),
    (:forb,  "forb (forbidden)"),
    (:noedge,"noedge"),
]

const PBP_LABELS = [
    (:loop,          "loop"),
    (:elimdegpol,    "elimdegpol"),
    (:elimdeg,       "elimdeg"),
    (:elimndspol,    "elimndspol"),
    (:elimndsconc,   "elimndsconc"),
    (:elimnds,       "elimnds"),
    (:hall,          "hall"),
    (:ptbig,         "ptbig"),
    (:prop,          "prop"),
    (:guess,         "guess"),
    (:nogood,        "nogood"),
    (:g1adj,         "g1adj"),
    (:g2adj,         "g2adj"),
    (:g3adj,         "g3adj"),
    (:gadj_other,    "gadj_other"),
    (:pathg1,        "pathg1"),
    (:pathg2,        "pathg2"),
    (:pathg3,        "pathg3"),
    (:pathg_other,   "pathg_other"),
    (:d2g1,          "d2g1"),
    (:d2g2,          "d2g2"),
    (:d2g3,          "d2g3"),
    (:d2g_other,     "d2g_other"),
    (:d3g1,          "d3g1"),
    (:d3g2,          "d3g2"),
    (:d3g3,          "d3g3"),
    (:d3g_other,     "d3g_other"),
    (:reelimdegpol,  "re-elimdegpol"),
    (:reelimdeg,     "re-elimdeg"),
    (:reelimndspol,  "re-elimndspol"),
    (:reelimndsconc, "re-elimndsconc"),
    (:unsatconc,     "unsatconc"),
    (:binback,       "binback"),
    (:colpol,        "colpol"),
    (:hombd,         "hombd"),
    (:hompol,        "hompol"),
    (:hominj,        "hominj"),
    (:homdom,        "homdom"),
    (:homfin,        "homfin"),
    (:homcross,      "homcross"),
    (:mcspart,       "mcspart"),
    (:mcsfin,        "mcsfin"),
    (:notconn,       "notconn"),
    (:cliqedge,      "cliqedge"),
]

const ALL_LABELS = vcat(OPB_LABELS, PBP_LABELS)

const COLORS = Dict(
    :al1 => "#1a6fbf", :am1 => "#7ab3e8", :inj => "#e85b5b",
    :g0adj => "#1b7837", :forb => "#ff7f0e", :noedge => "#bcbd22",
    :loop => "#8c564b", :elimdegpol => "#6a3d9a", :elimdeg => "#9467bd",
    :elimndspol => "#c5a0d3", :elimndsconc => "#dfc5e8", :elimnds => "#b07cc6",
    :hall => "#e6ab02", :ptbig => "#d4a373",
    :prop => "#e31a1c", :guess => "#fb6a4a", :nogood => "#fc9272",
    :g1adj => "#5aae61", :g2adj => "#a6dba0", :g3adj => "#d9f0d3", :gadj_other => "#c7e9c0",
    :pathg1 => "#fdd0a2", :pathg2 => "#fb9a99", :pathg3 => "#de2d26", :pathg_other => "#fee5d9",
    :d2g1 => "#fbb4b9", :d2g2 => "#f768a1", :d2g3 => "#c51b8a", :d2g_other => "#fde0dd",
    :d3g1 => "#d4b9da", :d3g2 => "#ae017e", :d3g3 => "#7a0177", :d3g_other => "#e7e1ef",
    :reelimdegpol => "#17becf", :reelimdeg => "#9edae5",
    :reelimndspol => "#aec7e8", :reelimndsconc => "#c6dbef",
    :unsatconc => "#636363", :binback => "#969696", :colpol => "#bdbdbd",
    :hombd => "#d62728", :hompol => "#ff9896", :hominj => "#2ca02c",
    :homdom => "#98df8a", :homfin => "#ffbb78", :homcross => "#c49c94",
    :mcspart => "#f7b6d2", :mcsfin => "#dbdb8d",
    :notconn => "#c7c7c7", :cliqedge => "#aaaaaa",
    :unlabeled_opb => "#dddddd", :unlabeled_pbp => "#888888",
)

const FAMILIES = ["LV", "bio", "images-CVIU11", "meshes-CVIU11", "scalefree"]

# ── Helpers ──────────────────────────────────────────────────────────────────

json_str_arr(v) = "[" * join(("\"$x\"" for x in v), ",") * "]"
json_num_arr(v) = "[" * join((isnan(x) ? "null" : @sprintf("%.6f", x) for x in v), ",") * "]"
fmtk(x) = isnan(x) ? "—" : x >= 1e6 ? @sprintf("%.1fM", x / 1e6) : x >= 1e3 ? @sprintf("%.1fK", x / 1e3) : @sprintf("%.0f", x)

function safecol(df, col)
    col ∉ names(df) && return zeros(nrow(df))
    [ismissing(x) ? 0.0 : Float64(x) for x in df[!, col]]
end

# ── Per-family stats ─────────────────────────────────────────────────────────

struct LabelStats
    mean_frac::Float64   # mean(label / full_total) across instances
    med_frac::Float64    # median(label / full_total) across instances
    mean_abs::Float64    # mean(label count) — absolute
    med_abs::Float64     # median(label count) — absolute
end

function compute_family_data(fsub)
    n = nrow(fsub)
    n == 0 && return nothing
    ft = fsub.full_total

    full = Dict{Symbol, LabelStats}()
    cone = Dict{Symbol, LabelStats}()

    for (sym, _) in ALL_LABELS
        full_raw = safecol(fsub, "grim_full_$sym")
        cone_raw = safecol(fsub, "grim_cone_$sym")
        full[sym] = LabelStats(mean(full_raw ./ ft), median(full_raw ./ ft),
                               mean(full_raw), median(full_raw))
        cone[sym] = LabelStats(mean(cone_raw ./ ft), median(cone_raw ./ ft),
                               mean(cone_raw), median(cone_raw))
    end

    # Unlabeled OPB
    full_opb_labeled = sum(safecol(fsub, "grim_full_$sym") for (sym, _) in OPB_LABELS)
    full_opb_raw = fsub.full_opb_total
    full_opb_unlabeled = max.(0.0, full_opb_raw .- full_opb_labeled)
    full[:unlabeled_opb] = LabelStats(mean(full_opb_unlabeled ./ ft), median(full_opb_unlabeled ./ ft),
                                      mean(full_opb_unlabeled), median(full_opb_unlabeled))

    cone_opb_labeled = sum(safecol(fsub, "grim_cone_$sym") for (sym, _) in OPB_LABELS)
    cone_opb_raw = safecol(fsub, "grim_opb_cone")
    cone_opb_unlabeled = max.(0.0, cone_opb_raw .- cone_opb_labeled)
    cone[:unlabeled_opb] = LabelStats(mean(cone_opb_unlabeled ./ ft), median(cone_opb_unlabeled ./ ft),
                                      mean(cone_opb_unlabeled), median(cone_opb_unlabeled))

    # Unlabeled PBP
    full_pbp_labeled = sum(safecol(fsub, "grim_full_$sym") for (sym, _) in PBP_LABELS)
    full_pbp_raw = fsub.full_pbp_total
    full_pbp_unlabeled = max.(0.0, full_pbp_raw .- full_pbp_labeled)
    full[:unlabeled_pbp] = LabelStats(mean(full_pbp_unlabeled ./ ft), median(full_pbp_unlabeled ./ ft),
                                      mean(full_pbp_unlabeled), median(full_pbp_unlabeled))

    cone_pbp_labeled = sum(safecol(fsub, "grim_cone_$sym") for (sym, _) in PBP_LABELS)
    cone_pbp_raw = safecol(fsub, "grim_pbp_cone")
    cone_pbp_unlabeled = max.(0.0, cone_pbp_raw .- cone_pbp_labeled)
    cone[:unlabeled_pbp] = LabelStats(mean(cone_pbp_unlabeled ./ ft), median(cone_pbp_unlabeled ./ ft),
                                      mean(cone_pbp_unlabeled), median(cone_pbp_unlabeled))

    cone_ratio_mean = mean(fsub.cone_total ./ ft)
    cone_ratio_med  = median(fsub.cone_total ./ ft)
    full_total_mean = mean(ft)
    full_total_med  = median(ft)

    (n=n, full=full, cone=cone,
     cone_ratio_mean=cone_ratio_mean, cone_ratio_med=cone_ratio_med,
     full_total_mean=full_total_mean, full_total_med=full_total_med)
end

# ── Chart builder ────────────────────────────────────────────────────────────

const ALL_SEGMENTS = vcat(ALL_LABELS, [(:unlabeled_opb, "unlabeled OPB"), (:unlabeled_pbp, "unlabeled PBP")])

function build_chart(id, present, fam_data, significant, mode::Symbol)
    # mode: :mean or :median
    frac_field = mode == :mean ? :mean_frac : :med_frac
    abs_field  = mode == :mean ? :mean_abs  : :med_abs
    other_abs  = mode == :mean ? :med_abs   : :mean_abs
    abs_label  = mode == :mean ? "mean" : "median"
    other_label = mode == :mean ? "median" : "mean"

    # Build absolute-value lookup tables for tooltip (JSON objects per family)
    # We embed them as custom dataset properties
    datasets_js = IOBuffer()
    first = true
    for (sym, name) in significant
        color = get(COLORS, sym, "#999999")
        full_fracs = [getfield(fam_data[f].full[sym], frac_field) for f in present]
        cone_fracs = [getfield(fam_data[f].cone[sym], frac_field) for f in present]

        full_abs_main  = [getfield(fam_data[f].full[sym], abs_field) for f in present]
        full_abs_other = [getfield(fam_data[f].full[sym], other_abs) for f in present]
        cone_abs_main  = [getfield(fam_data[f].cone[sym], abs_field) for f in present]
        cone_abs_other = [getfield(fam_data[f].cone[sym], other_abs) for f in present]

        !first && print(datasets_js, ",\n")
        first = false
        # Full bar
        print(datasets_js, """{ label: "$name", backgroundColor: "$color", stack: "Full", """)
        print(datasets_js, """data: $(json_num_arr(full_fracs)), """)
        print(datasets_js, """absMain: $(json_num_arr(full_abs_main)), """)
        print(datasets_js, """absOther: $(json_num_arr(full_abs_other)) }""")
        # Cone bar
        print(datasets_js, """,\n{ label: "$name (cone)", backgroundColor: "$color", stack: "Cone", """)
        print(datasets_js, """data: $(json_num_arr(cone_fracs)), """)
        print(datasets_js, """absMain: $(json_num_arr(cone_abs_main)), """)
        print(datasets_js, """absOther: $(json_num_arr(cone_abs_other)), """)
        print(datasets_js, """borderColor: "#000", borderWidth: 1 }""")
    end
    ds_str = String(take!(datasets_js))

    # Per-family totals for the tooltip header
    fam_totals_js = IOBuffer()
    print(fam_totals_js, "{")
    for (i, f) in enumerate(present)
        i > 1 && print(fam_totals_js, ", ")
        d = fam_data[f]
        print(fam_totals_js, "\"$f\": { mainTotal: $(@sprintf("%.0f", mode == :mean ? d.full_total_mean : d.full_total_med)), ")
        print(fam_totals_js, "otherTotal: $(@sprintf("%.0f", mode == :mean ? d.full_total_med : d.full_total_mean)), ")
        print(fam_totals_js, "n: $(d.n) }")
    end
    print(fam_totals_js, "}")
    totals_str = String(take!(fam_totals_js))

    """
    <div class="chart-box" style="width:1100px;height:600px"><canvas id="$id"></canvas></div>
    <script>
    (function() {
      var totals = $totals_str;
      new Chart(document.getElementById("$id"), {
        type: "bar",
        data: {
          labels: $(json_str_arr(present)),
          datasets: [$ds_str]
        },
        options: {
          responsive: true, maintainAspectRatio: false,
          plugins: {
            legend: {
              position: "right",
              labels: {
                filter: function(item) { return !item.text.endsWith("(cone)"); },
                font: { size: 10 },
                boxWidth: 12
              }
            },
            tooltip: {
              callbacks: {
                title: function(items) {
                  if (!items.length) return "";
                  var fam = items[0].label;
                  var t = totals[fam];
                  var stack = items[0].dataset.stack;
                  return fam + " (" + stack + ") — n=" + t.n +
                    "\\n$abs_label full total: " + fmtK(t.mainTotal) +
                    "  |  $other_label: " + fmtK(t.otherTotal);
                },
                label: function(ctx) {
                  var pct = (ctx.raw * 100).toFixed(2) + "%";
                  var absM = ctx.dataset.absMain ? ctx.dataset.absMain[ctx.dataIndex] : null;
                  var absO = ctx.dataset.absOther ? ctx.dataset.absOther[ctx.dataIndex] : null;
                  var abs_str = "";
                  if (absM != null) abs_str = "  ($abs_label " + fmtK(absM) + " | $other_label " + fmtK(absO) + ")";
                  return ctx.dataset.label + ": " + pct + abs_str;
                }
              }
            }
          },
          scales: {
            x: { stacked: true },
            y: { stacked: true, min: 0, max: 1.0,
                 title: { display: true, text: "fraction of full proof total ($abs_label)" } }
          }
        }
      });
    })();
    </script>
    """
end

# ── Main ─────────────────────────────────────────────────────────────────────

function main()
    csv_path = ARGS[1]
    out_path = length(ARGS) >= 2 ? ARGS[2] : "cone_vs_full.html"

    df = CSV.read(csv_path, DataFrame)

    sub = filter(row -> !ismissing(row.is_unsat) && row.is_unsat == true &&
                        !ismissing(row.grim_total_cone) && row.grim_total_cone > 0 &&
                        !ismissing(row.grim_full_rup), df)
    println("Instances with full+cone data: $(nrow(sub))")

    sub.full_pbp_total = safecol(sub, "grim_full_rup") .+ safecol(sub, "grim_full_pol") .+
                         safecol(sub, "grim_full_ia") .+ safecol(sub, "grim_full_red")
    sub.full_opb_total = safecol(sub, "inp_opb_nbeq")
    sub.full_total = sub.full_opb_total .+ sub.full_pbp_total
    sub.cone_total = safecol(sub, "grim_total_cone")

    # has_search: cone has prop+guess+nogood > 0
    sub.has_search = (safecol(sub, "grim_cone_prop") .+ safecol(sub, "grim_cone_guess") .+
                      safecol(sub, "grim_cone_nogood")) .> 0

    sub_search = filter(row -> row.has_search, sub)
    println("  with search: $(nrow(sub_search))")

    present = [f for f in FAMILIES if any(sub.family .== f)]

    # Compute data for all and search-only
    fam_all    = Dict{String, Any}()
    fam_search = Dict{String, Any}()
    for fam in present
        fsub_all = filter(row -> row.family == fam && row.full_total > 0, sub)
        fam_all[fam] = compute_family_data(fsub_all)

        fsub_s = filter(row -> row.family == fam && row.full_total > 0, sub_search)
        d = compute_family_data(fsub_s)
        d !== nothing && (fam_search[fam] = d)
    end

    present_search = [f for f in present if haskey(fam_search, f) && fam_search[f].n >= 5]
    println("Families (all): ", join(present, ", "))
    println("Families (search): ", join(present_search, ", "))

    # Significant labels (across all)
    significant = filter(ALL_SEGMENTS) do (sym, _)
        any(fam_all[f].full[sym].mean_frac > 0.001 || fam_all[f].cone[sym].mean_frac > 0.001 for f in present)
    end
    significant_search = filter(ALL_SEGMENTS) do (sym, _)
        any(haskey(fam_search, f) && (fam_search[f].full[sym].mean_frac > 0.001 ||
            fam_search[f].cone[sym].mean_frac > 0.001) for f in present_search)
    end

    println("Significant labels (all): $(length(significant))  (search): $(length(significant_search))")

    # Build charts (mean only — median visible in tooltips)
    chart_mean_all    = build_chart("megaMeanAll",    present,        fam_all,    significant,        :mean)
    chart_mean_search = build_chart("megaMeanSearch", present_search, fam_search, significant_search, :mean)

    # Overview table
    ov_buf = IOBuffer()
    for f in present
        d = fam_all[f]
        ds = haskey(fam_search, f) ? fam_search[f] : nothing
        ns = ds !== nothing ? ds.n : 0
        println(ov_buf, "<tr><td>$f</td><td>$(d.n)</td>",
            "<td>$(@sprintf("%.1f%%", d.cone_ratio_mean * 100))</td>",
            "<td>$(@sprintf("%.1f%%", d.cone_ratio_med * 100))</td>",
            "<td>$(fmtk(d.full_total_mean))</td>",
            "<td>$(fmtk(d.full_total_med))</td>",
            "<td>$ns ($(@sprintf("%.0f%%", 100 * ns / d.n)))</td></tr>")
    end
    ov_str = String(take!(ov_buf))

    # Search overview table (with Δ vs all)
    sov_buf = IOBuffer()
    for f in present_search
        d = fam_search[f]
        da = fam_all[f]
        delta_mean = d.cone_ratio_mean - da.cone_ratio_mean
        delta_med  = d.cone_ratio_med  - da.cone_ratio_med
        sign_mean = delta_mean >= 0 ? "+" : ""
        sign_med  = delta_med  >= 0 ? "+" : ""
        println(sov_buf, "<tr><td>$f</td><td>$(d.n)</td>",
            "<td>$(@sprintf("%.1f%%", d.cone_ratio_mean * 100))</td>",
            "<td>$(sign_mean)$(@sprintf("%.1f", delta_mean * 100))pp</td>",
            "<td>$(@sprintf("%.1f%%", d.cone_ratio_med * 100))</td>",
            "<td>$(sign_med)$(@sprintf("%.1f", delta_med * 100))pp</td>",
            "<td>$(fmtk(d.full_total_mean))</td>",
            "<td>$(fmtk(d.full_total_med))</td></tr>")
    end
    sov_str = String(take!(sov_buf))

    # Survival table
    surv_buf = IOBuffer()
    for (sym, name) in significant
        vals = [let ff = fam_all[f].full[sym].mean_frac, cc = fam_all[f].cone[sym].mean_frac
                    ff > 1e-6 ? @sprintf("%.1f%%", cc / ff * 100) : "—"
                end for f in present]
        println(surv_buf, "<tr><td>$name</td>", join("<td>$v</td>" for v in vals), "</tr>")
    end
    surv_str = String(take!(surv_buf))
    fam_headers = join("<th>$f</th>" for f in present)

    html = """
    <!DOCTYPE html>
    <html><head><meta charset="utf-8"><title>Full vs Cone — Label Composition</title>
    <style>
    body{font-family:monospace;max-width:1200px;margin:40px auto;padding:0 20px;background:#fafafa;color:#222}
    h1{border-bottom:2px solid #333;padding-bottom:8px}
    h2{margin-top:40px;border-bottom:1px solid #aaa;color:#333}
    h3{margin-top:24px;color:#555}
    table{border-collapse:collapse;margin:12px 0;font-size:13px}
    th{background:#333;color:#fff;padding:6px 14px;text-align:right;white-space:nowrap}
    th:first-child{text-align:left}
    td{padding:5px 14px;border-bottom:1px solid #ddd;text-align:right;white-space:nowrap}
    td:first-child{text-align:left;font-weight:bold}
    tr:nth-child(even) td{background:#f2f2f2}
    .chart-box{margin:18px 0}
    p.note{color:#666;font-size:12px;margin:4px 0}
    </style>
    <script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.0/dist/chart.umd.min.js"></script>
    <script>
    function fmtK(x) {
      if (x == null || isNaN(x)) return "—";
      if (x >= 1e6) return (x / 1e6).toFixed(1) + "M";
      if (x >= 1e3) return (x / 1e3).toFixed(1) + "K";
      return x.toFixed(0);
    }
    </script>
    </head><body>
    <h1>Full Proof vs Cone — Label Composition</h1>

    <h2>Overview</h2>
    <table><thead><tr><th>Family</th><th>n</th><th>cone/full (mean)</th><th>cone/full (med)</th>
    <th>full total (mean)</th><th>full total (med)</th><th>has search</th></tr></thead>
    <tbody>$ov_str</tbody></table>

    <h2>All instances</h2>
    <p class="note">Left bar = full proof, right bar = cone. Same scale (fraction of full total).
    Hover for absolute step counts (mean + median).</p>
    $chart_mean_all

    <h2>Search instances only (prop+guess+nogood &gt; 0 in cone)</h2>
    <table><thead><tr><th>Family</th><th>n</th><th>cone/full (mean)</th><th>&Delta; vs all</th>
    <th>cone/full (med)</th><th>&Delta; vs all</th>
    <th>full total (mean)</th><th>full total (med)</th></tr></thead>
    <tbody>$sov_str</tbody></table>
    <p class="note">Same layout, restricted to instances where the cone contains search steps.
    &Delta; in percentage points vs all-instances overview.</p>
    $chart_mean_search

    <h2>Label Survival Rates (mean cone/full per label)</h2>
    <p class="note">Fraction of each label's steps that survive trimming.</p>
    <table><thead><tr><th>Label</th>$fam_headers</tr></thead>
    <tbody>$surv_str</tbody></table>

    </body></html>
    """

    open(out_path, "w") do io
        write(io, html)
    end
    println("Written: $out_path")
end

main()
