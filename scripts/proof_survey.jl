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

function grouped_bar_chart(id, labels, datasets; ytitle="", ymax=1.0)
    # datasets: Vector of (label, color, num_array_json)
    ds = join(["{ label: \"$(d[1])\", backgroundColor: \"$(d[2])\", data: $(d[3]) }"
               for d in datasets], ",\n")
    ymax_s = isnan(ymax) ? "undefined" : @sprintf("%.4f", ymax)
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
          x: { stacked: false },
          y: { stacked: false, min: 0, max: $ymax_s,
               title: { display: true, text: $(repr(ytitle)) } }
        }
      }
    });
    </script>
    """
end

function stacked_bar_chart(id, labels, datasets; ytitle="fraction of cone steps")
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
               title: { display: true, text: $(repr(ytitle)) } }
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

        # Per-instance fraction vectors — used for mean/median/IQR
        total_v  = nonnull(sub, "grim_total_cone")
        full_v   = nonnull(sub, "inp_total_nbeq")
        opb_in_v = nonnull(sub, "inp_opb_nbeq")
        pbp_in_v = nonnull(sub, "inp_pbp_nbeq")

        function frac_vec(num_col, denom_v)
            num_v = nonnull(sub, num_col)
            (isempty(num_v) || isempty(denom_v)) && return Float64[]
            [n / d for (n, d) in zip(num_v, denom_v) if d > 0]
        end
        function frac_stats(num_col, denom_v)
            v = frac_vec(num_col, denom_v)
            isempty(v) && return (mean=NaN, med=NaN, q1=NaN, q3=NaN)
            qs = quantile(v, [0.25, 0.5, 0.75])
            (mean=avg(v), med=qs[2], q1=qs[1], q3=qs[3])
        end
        function removed_frac(inp_col, cone_col)
            inp_v  = nonnull(sub, inp_col)
            cone_v = nonnull(sub, cone_col)
            (isempty(inp_v) || isempty(cone_v) || isempty(full_v)) && return NaN
            avg([max(0.0, i - c) / t for (i, c, t) in zip(inp_v, cone_v, full_v) if t > 0])
        end

        # Step type fracs within cone
        fs_opb = frac_stats("grim_opb_cone", total_v)
        fs_rup = frac_stats("grim_cone_rup", total_v)
        fs_pol = frac_stats("grim_cone_pol", total_v)
        fs_ia  = frac_stats("grim_cone_ia",  total_v)
        fs_red = frac_stats("grim_cone_red", total_v)
        # OPB/PBP-specific survival rates (on their own denominator)
        sv_opb = frac_stats("grim_opb_cone",  opb_in_v)
        sv_pbp = frac_stats("grim_pbp_cone",  pbp_in_v)

        fam_data[fam] = (
            n           = nrow(sub),
            med_cone    = med(nonnull(sub, "grim_total_cone")),
            med_depth   = med(nonnull(sub, "grim_cone_depth_max")),
            med_time    = med(nonnull(sub, "grim_total_time")),
            # cone step type fractions (mean / med / q1 / q3)
            mean_opb=fs_opb.mean, med_opb=fs_opb.med, q1_opb=fs_opb.q1, q3_opb=fs_opb.q3,
            mean_rup=fs_rup.mean, med_rup=fs_rup.med, q1_rup=fs_rup.q1, q3_rup=fs_rup.q3,
            mean_pol=fs_pol.mean, med_pol=fs_pol.med, q1_pol=fs_pol.q1, q3_pol=fs_pol.q3,
            mean_ia =fs_ia.mean,  med_ia =fs_ia.med,  q1_ia =fs_ia.q1,  q3_ia =fs_ia.q3,
            mean_red=fs_red.mean, med_red=fs_red.med, q1_red=fs_red.q1, q3_red=fs_red.q3,
            # survival fractions vs full proof (denominator = inp_total_nbeq)
            surv_opb    = avg(frac_vec("grim_opb_cone", full_v)),
            surv_rup    = avg(frac_vec("grim_cone_rup", full_v)),
            surv_pol    = avg(frac_vec("grim_cone_pol", full_v)),
            surv_ia     = avg(frac_vec("grim_cone_ia",  full_v)),
            surv_red    = avg(frac_vec("grim_cone_red", full_v)),
            surv_cone   = avg(frac_vec("grim_total_cone", full_v)),
            rem_opb     = removed_frac("inp_opb_nbeq", "grim_opb_cone"),
            rem_pbp     = removed_frac("inp_pbp_nbeq", "grim_pbp_cone"),
            # OPB/PBP-specific survival rates (own denominator)
            sv_opb_mean=sv_opb.mean, sv_opb_med=sv_opb.med, sv_opb_q1=sv_opb.q1, sv_opb_q3=sv_opb.q3,
            sv_pbp_mean=sv_pbp.mean, sv_pbp_med=sv_pbp.med, sv_pbp_q1=sv_pbp.q1, sv_pbp_q3=sv_pbp.q3,
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
    st_rows = [[f, fd(f).n,
                fmtpct(fd(f).mean_opb), fmtpct(fd(f).mean_rup), fmtpct(fd(f).mean_pol),
                fmtpct(fd(f).mean_ia), fmtpct(fd(f).mean_red)] for f in present]
    st_html = html_table(["Family", "n", "OPB %", "RUP %", "POL %", "IA %", "RED %"], st_rows)
    # Shared palette: OPB/RUP/POL/IA/RED use the same hues in both charts
    # Removed segments use clearly distinct muted tones (warm salmon vs cool silver)
    C = (opb="#004cc9", rup="#ed7d31", pol="#70ad47", ia="#ffc000", red="#7030a0",
         rem_opb="#c0eeff", rem_pbp="#dbffc0")
    # C = (opb="#5b9bd5", rup="#ed7d31", pol="#70ad47", ia="#ffc000", red="#7030a0",
        #  rem_opb="#b0b0b0", rem_pbp="#f4a582")

    # Step type mix — mean chart + median chart + IQR table
    st_rows = [[f, fd(f).n,
                "$(fmtpct(fd(f).mean_opb)) / $(fmtpct(fd(f).med_opb))",
                "$(fmtpct(fd(f).mean_rup)) / $(fmtpct(fd(f).med_rup))",
                "$(fmtpct(fd(f).mean_pol)) / $(fmtpct(fd(f).med_pol))",
                "$(fmtpct(fd(f).mean_ia))  / $(fmtpct(fd(f).med_ia))",
                "$(fmtpct(fd(f).mean_red)) / $(fmtpct(fd(f).med_red))"] for f in present]
    st_html = html_table(["Family", "n", "OPB mean/med", "RUP mean/med", "POL mean/med", "IA mean/med", "RED mean/med"],
                         st_rows)

    iqr_rows = [[f, fd(f).n,
                 "[$(fmtpct(fd(f).q1_opb)), $(fmtpct(fd(f).q3_opb))]",
                 "[$(fmtpct(fd(f).q1_rup)), $(fmtpct(fd(f).q3_rup))]",
                 "[$(fmtpct(fd(f).q1_pol)), $(fmtpct(fd(f).q3_pol))]",
                 "[$(fmtpct(fd(f).q1_ia)),  $(fmtpct(fd(f).q3_ia))]",
                 "[$(fmtpct(fd(f).q1_red)), $(fmtpct(fd(f).q3_red))]"] for f in present]
    iqr_html = html_table(["Family", "n", "OPB [p25,p75]", "RUP [p25,p75]", "POL [p25,p75]", "IA [p25,p75]", "RED [p25,p75]"],
                          iqr_rows)

    chart_html     = stacked_bar_chart("stepChart",    present,
        [("OPB", C.opb, json_num_arr([fd(f).mean_opb for f in present])),
         ("RUP", C.rup, json_num_arr([fd(f).mean_rup for f in present])),
         ("POL", C.pol, json_num_arr([fd(f).mean_pol for f in present])),
         ("IA",  C.ia,  json_num_arr([fd(f).mean_ia  for f in present])),
         ("RED", C.red, json_num_arr([fd(f).mean_red for f in present]))])
    chart_med_html = stacked_bar_chart("stepChartMed", present,
        [("OPB", C.opb, json_num_arr([fd(f).med_opb for f in present])),
         ("RUP", C.rup, json_num_arr([fd(f).med_rup for f in present])),
         ("POL", C.pol, json_num_arr([fd(f).med_pol for f in present])),
         ("IA",  C.ia,  json_num_arr([fd(f).med_ia  for f in present])),
         ("RED", C.red, json_num_arr([fd(f).med_red for f in present]))])

    # Survival chart: each step type as fraction of full proof total
    # Removed split into OPB-removed and PBP-removed
    surv_rows = [[f, fd(f).n,
                  fmtpct(fd(f).surv_opb), fmtpct(fd(f).surv_rup), fmtpct(fd(f).surv_pol),
                  fmtpct(fd(f).surv_ia), fmtpct(fd(f).surv_red),
                  fmtpct(fd(f).rem_opb), fmtpct(fd(f).rem_pbp)] for f in present]
    surv_html  = html_table(
        ["Family", "n", "OPB kept", "RUP kept", "POL kept", "IA kept", "RED kept", "OPB removed", "PBP removed"],
        surv_rows)
    surv_chart = stacked_bar_chart("survChart", present,
        [("OPB kept",     C.opb,     json_num_arr([fd(f).surv_opb for f in present])),
         ("RUP kept",     C.rup,     json_num_arr([fd(f).surv_rup for f in present])),
         ("POL kept",     C.pol,     json_num_arr([fd(f).surv_pol for f in present])),
         ("IA kept",      C.ia,      json_num_arr([fd(f).surv_ia  for f in present])),
         ("RED kept",     C.red,     json_num_arr([fd(f).surv_red for f in present])),
         ("OPB removed",  C.rem_opb, json_num_arr([fd(f).rem_opb  for f in present])),
         ("PBP removed",  C.rem_pbp, json_num_arr([fd(f).rem_pbp  for f in present]))];
        ytitle="fraction of full proof (OPB+PBP)")

    # OPB/PBP survival rates on their own denominators (mean / med / IQR)
    sv_rows = [[f, fd(f).n,
                "$(fmtpct(fd(f).sv_opb_mean)) / $(fmtpct(fd(f).sv_opb_med))",
                "[$(fmtpct(fd(f).sv_opb_q1)), $(fmtpct(fd(f).sv_opb_q3))]",
                "$(fmtpct(fd(f).sv_pbp_mean)) / $(fmtpct(fd(f).sv_pbp_med))",
                "[$(fmtpct(fd(f).sv_pbp_q1)), $(fmtpct(fd(f).sv_pbp_q3))]"] for f in present]
    sv_html = html_table(
        ["Family", "n", "OPB survival mean/med", "OPB survival [p25,p75]",
         "PBP survival mean/med", "PBP survival [p25,p75]"],
        sv_rows)
    # Grouped charts: p25 / mean / median / p75 per family (no stacking — quartiles don't add up)
    # Colors go light→dark for p25→p75 to suggest the IQR range visually
    sv_chart_opb = grouped_bar_chart("svOpbChart", present,
        [("p25",    "#aecde8", json_num_arr([fd(f).sv_opb_q1   for f in present])),
         ("mean",   "#5b9bd5", json_num_arr([fd(f).sv_opb_mean for f in present])),
         ("median", "#1a5fa8", json_num_arr([fd(f).sv_opb_med  for f in present])),
         ("p75",    "#0d2f52", json_num_arr([fd(f).sv_opb_q3   for f in present]))];
        ytitle="OPB axiom survival rate")
    sv_chart_pbp = grouped_bar_chart("svPbpChart", present,
        [("p25",    "#c6e9b0", json_num_arr([fd(f).sv_pbp_q1   for f in present])),
         ("mean",   "#70ad47", json_num_arr([fd(f).sv_pbp_mean for f in present])),
         ("median", "#3d7a1a", json_num_arr([fd(f).sv_pbp_med  for f in present])),
         ("p75",    "#1a3a08", json_num_arr([fd(f).sv_pbp_q3   for f in present]))];
        ytitle="PBP step survival rate")

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

    # ── Section 5: Step type mix — search vs no-search ───────────────────────
    search_html = ""
    if "solver_nodes" ∈ names(proof_jdf)
        has_search  = proof_jdf[(!ismissing).(proof_jdf.solver_nodes) .& (proof_jdf.solver_nodes .> 1), :]
        no_search   = proof_jdf[ismissing.(proof_jdf.solver_nodes) .| (proof_jdf.solver_nodes .<= 1), :]

        function step_mix(sub)
            total_v = nonnull(sub, "grim_pbp_cone")
            function tf(col)
                num_v = nonnull(sub, col)
                isempty(num_v) || isempty(total_v) && return NaN
                avg([n / t for (n, t) in zip(num_v, total_v) if t > 0])
            end
            (n=nrow(sub), opb=avg([r for r in skipmissing(sub.grim_opb_cone ./ sub.grim_total_cone)]),
             rup=tf("grim_cone_rup"), pol=tf("grim_cone_pol"), ia=tf("grim_cone_ia"), red=tf("grim_cone_red"))
        end

        sm_search   = step_mix(has_search)
        sm_nosearch = step_mix(no_search)

        sc_rows = [
            ["search (nodes>1)", sm_search.n,   fmtpct(sm_search.opb),   fmtpct(sm_search.rup),
             fmtpct(sm_search.pol),   fmtpct(sm_search.ia),   fmtpct(sm_search.red)],
            ["no/trivial search", sm_nosearch.n, fmtpct(sm_nosearch.opb), fmtpct(sm_nosearch.rup),
             fmtpct(sm_nosearch.pol), fmtpct(sm_nosearch.ia), fmtpct(sm_nosearch.red)],
        ]
        search_table = html_table(["Group", "n", "OPB %", "RUP %", "POL %", "IA %", "RED %"], sc_rows)

        # Per-family: how many instances have search?
        sc_fam_rows = []
        for f in present
            mask = isequal.(proof_jdf.family, f)
            sub_f = proof_jdf[mask, :]
            n_s  = sum((!ismissing).(sub_f.solver_nodes) .& (sub_f.solver_nodes .> 1))
            push!(sc_fam_rows, [f, nrow(sub_f), n_s, fmtpct(n_s / max(1, nrow(sub_f)))])
        end
        search_fam_table = html_table(["Family", "n total", "n with search", "search %"], sc_fam_rows)

        search_html = """
        <h2>5 — Step Type Mix: Search vs No-Search Proofs</h2>
        <p class="note">Search = <code>solver_nodes &gt; 1</code> (solver had to backtrack). Low RUP is <em>not</em> explained
        by a lack of search proofs: even with search, RUP remains rare — the main shift is IA vs POL balance.</p>
        $search_table
        <p class="note">Search incidence by family:</p>
        $search_fam_table
        """
    end

    # ── Section 6: Correlations with graph features ───────────────────────────
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

    <h2>2 — Step Type Mix (within cone)</h2>
    <p class="note">Fraction of each step type within the trimmed cone. Columns show mean / median per family.
    Large mean–median gaps indicate a skewed distribution (a few outlier instances pull the average).</p>
    $st_html
    <p class="note">Mean chart (outliers inflate):</p>
    $chart_html
    <p class="note">Median chart (more robust):</p>
    $chart_med_html
    <p class="note">IQR [p25, p75] — wide range = high within-family variance:</p>
    $iqr_html

    <h2>2b — Survival: cone steps as fraction of full proof</h2>
    <p class="note">Each segment = mean(cone_X / inp_total_nbeq). Removed is split into OPB-removed and PBP-removed.
    The internal type breakdown of removed PBP steps is not available without a re-run.</p>
    $surv_html
    $surv_chart

    <h2>2c — OPB vs PBP survival rates (separate denominators)</h2>
    <p class="note">OPB survival = cone_opb / inp_opb_nbeq (what fraction of <em>axioms</em> were kept).
    PBP survival = cone_pbp / inp_pbp_nbeq (what fraction of <em>derived steps</em> were kept).
    Using separate denominators removes the "big OPB inflates the mix" confound.
    Charts show median; table shows mean / median and [p25, p75].</p>
    $sv_html
    $sv_chart_opb
    $sv_chart_pbp

    <h2>3 — Proof Shape</h2>
    <p class="note">
    entropy: Shannon entropy of per-depth step counts — 0 = all steps at same depth (chain), high = spread across many depths.<br>
    bottom_frac: fraction of cone steps at depth ≤ 2 (direct propagation from axioms).<br>
    POL-burst: fraction of instances where a POL step is immediately followed by a RUP surge at depth+1.</p>
    $sh_html

    <h2>4 — Resolv Shrinkage</h2>
    <p class="note">n resolved = instances where resolv ran and pattern graph shrank. Shrinkage = (initial − final) / initial.</p>
    $rs_html

    $search_html

    $corr_html
    </body>
    </html>
    """

    write(out_html, html)
    println("Wrote $out_html  ($n_total instances, $(length(present)) families)")
end

main()
