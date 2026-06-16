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

# Row-aligned fraction stats for label columns.
# Computes count_col / denom_col per row, skipping rows where count is missing or denom is 0/missing.
# Unlike frac_stats (zip-based), this handles sparse label data correctly.
# .n = number of instances included (< nrow when the label is sparse).
function lbl_frac_stats(sub, count_col, denom_col)
    (count_col ∉ names(sub) || denom_col ∉ names(sub)) &&
        return (mean=NaN, med=NaN, q1=NaN, q3=NaN, n=0)
    v = Float64[]
    for i in 1:nrow(sub)
        c = sub[i, count_col]; d = sub[i, denom_col]
        (ismissing(c) || ismissing(d) || d == 0) && continue
        push!(v, Float64(c) / Float64(d))
    end
    isempty(v) && return (mean=NaN, med=NaN, q1=NaN, q3=NaN, n=0)
    qs = quantile(v, [0.25, 0.5, 0.75])
    (mean=avg(v), med=qs[2], q1=qs[1], q3=qs[3], n=length(v))
end

# Like lbl_frac_stats but treats a missing numerator as 0 (use for "always present" counts
# that are omitted from .out when zero, e.g. grim_cone_unlabeled, grim_cone_rup).
function lbl_frac_stats_z(sub, count_col, denom_col)
    denom_col ∉ names(sub) && return (mean=NaN, med=NaN, q1=NaN, q3=NaN, n=0)
    v = Float64[]
    for i in 1:nrow(sub)
        d = sub[i, denom_col]; (ismissing(d) || d == 0) && continue
        c = count_col ∈ names(sub) ? sub[i, count_col] : missing
        push!(v, Float64(ismissing(c) ? 0 : c) / Float64(d))
    end
    isempty(v) && return (mean=NaN, med=NaN, q1=NaN, q3=NaN, n=0)
    qs = quantile(v, [0.25, 0.5, 0.75])
    (mean=avg(v), med=qs[2], q1=qs[1], q3=qs[3], n=length(v))
end

# Computes (total_col - Σ minus_cols, treating missing minus values as 0) / denom_col per row.
# Use for "unlabeled = total - Σ(labeled)" residuals.
function row_diff_frac_stats(sub, total_col, minus_cols, denom_col)
    (total_col ∉ names(sub) || denom_col ∉ names(sub)) && return (mean=NaN, med=NaN, q1=NaN, q3=NaN, n=0)
    v = Float64[]
    for i in 1:nrow(sub)
        d = sub[i, denom_col]; (ismissing(d) || d == 0) && continue
        t = sub[i, total_col]; ismissing(t) && continue
        s = Float64(t)
        for col in minus_cols
            col ∉ names(sub) && continue
            c = sub[i, col]; !ismissing(c) && (s -= Float64(c))
        end
        push!(v, max(0.0, s) / Float64(d))
    end
    isempty(v) && return (mean=NaN, med=NaN, q1=NaN, q3=NaN, n=0)
    qs = quantile(v, [0.25, 0.5, 0.75])
    (mean=avg(v), med=qs[2], q1=qs[1], q3=qs[3], n=length(v))
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

function stacked_bar_chart(id, labels, datasets; ytitle="fraction of cone steps", ymax=1.0)
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
          x: { stacked: true },
          y: { stacked: true, min: 0, max: $ymax_s,
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
            # M3.5: cone width
            med_width_max  = med(nonnull(sub, "grim_cone_width_max")),
            med_width_cv   = med(nonnull(sub, "grim_cone_width_cv")),
            med_lit_weak   = med(nonnull(sub, "grim_literal_weakening_rate")),
            # M3.5: POL step structure
            med_pol_depth_mean     = med(nonnull(sub, "grim_pol_depth_mean")),
            med_pol_depth_cv       = med(nonnull(sub, "grim_pol_depth_cv")),
            med_pol_depth_frac_bot = med(nonnull(sub, "grim_pol_depth_frac_bot")),
            med_pol_depth_frac_top = med(nonnull(sub, "grim_pol_depth_frac_top")),
            med_pol_ante_mean      = med(nonnull(sub, "grim_pol_ante_mean")),
            med_pol_ante_max       = med(nonnull(sub, "grim_pol_ante_max")),
            med_pol_opb_frac       = med(nonnull(sub, "grim_pol_opb_frac")),
            # M3.5.3: branching heuristic — unique pattern nodes in OPB cone
            med_uniq_pat = med(nonnull(sub, "grim_cone_uniq_pat")),
            # §7: CP provenance — fraction of total cone (OPB+PBP)
            # Sparse labels (loop/elim/gNadj) computed only on instances that have them;
            # .n field reflects this subset size.
            ls_al1     = lbl_frac_stats(sub, "grim_cone_al1",     "grim_total_cone"),
            ls_am1     = lbl_frac_stats(sub, "grim_cone_am1",     "grim_total_cone"),
            ls_inj     = lbl_frac_stats(sub, "grim_cone_inj",     "grim_total_cone"),
            ls_g0adj   = lbl_frac_stats(sub, "grim_cone_g0adj",   "grim_total_cone"),
            ls_g1adj   = lbl_frac_stats(sub, "grim_cone_g1adj",   "grim_total_cone"),
            ls_g2adj   = lbl_frac_stats(sub, "grim_cone_g2adj",   "grim_total_cone"),
            ls_g3adj   = lbl_frac_stats(sub, "grim_cone_g3adj",   "grim_total_cone"),
            ls_forb    = lbl_frac_stats(sub, "grim_cone_forb",    "grim_total_cone"),
            ls_elimnds = lbl_frac_stats(sub, "grim_cone_elimnds", "grim_total_cone"),
            ls_elimdeg = lbl_frac_stats(sub, "grim_cone_elimdeg", "grim_total_cone"),
            ls_loop    = lbl_frac_stats(sub, "grim_cone_loop",    "grim_total_cone"),
            # §7/§9 stacked bars: _z variants (missing→0) so all means are over the same population.
            # Non-sparse OPB labels (al1/am1/inj/g0adj/forb) are always non-missing so ls_* = sz_*.
            # Sparse PBP labels need _z so instances without them contribute 0, not are skipped.
            sz_g0adj   = lbl_frac_stats_z(sub, "grim_cone_g0adj",   "grim_total_cone"),
            sz_loop    = lbl_frac_stats_z(sub, "grim_cone_loop",    "grim_total_cone"),
            sz_elimnds = lbl_frac_stats_z(sub, "grim_cone_elimnds", "grim_total_cone"),
            sz_elimdeg = lbl_frac_stats_z(sub, "grim_cone_elimdeg", "grim_total_cone"),
            sz_g1adj   = lbl_frac_stats_z(sub, "grim_cone_g1adj",   "grim_total_cone"),
            sz_g2adj   = lbl_frac_stats_z(sub, "grim_cone_g2adj",   "grim_total_cone"),
            sz_g3adj   = lbl_frac_stats_z(sub, "grim_cone_g3adj",   "grim_total_cone"),
            ls_unlabeled_total  = lbl_frac_stats_z(sub, "grim_cone_unlabeled", "grim_total_cone"),
            pb_unlabeled_total  = row_diff_frac_stats(sub, "grim_pbp_cone",
                ["grim_cone_loop","grim_cone_elimnds","grim_cone_elimdeg",
                 "grim_cone_g1adj","grim_cone_g2adj","grim_cone_g3adj"], "grim_total_cone"),
            # §7b: OPB-only breakdown (opb_cone denom) — OPB labels sum to 100%
            ob_al1       = lbl_frac_stats(sub, "grim_cone_al1",       "grim_opb_cone"),
            ob_am1       = lbl_frac_stats(sub, "grim_cone_am1",       "grim_opb_cone"),
            ob_inj       = lbl_frac_stats(sub, "grim_cone_inj",       "grim_opb_cone"),
            ob_g0adj     = lbl_frac_stats(sub, "grim_cone_g0adj",     "grim_opb_cone"),
            ob_forb      = lbl_frac_stats(sub, "grim_cone_forb",      "grim_opb_cone"),
            ob_unlabeled = lbl_frac_stats_z(sub, "grim_cone_unlabeled", "grim_opb_cone"),
            # §7c: PBP-only breakdown (pbp_cone denom)
            # step-type view (sums to 100% over instances with pbp_cone > 0)
            pb_rup  = lbl_frac_stats_z(sub, "grim_cone_rup", "grim_pbp_cone"),
            pb_pol  = lbl_frac_stats_z(sub, "grim_cone_pol", "grim_pbp_cone"),
            pb_ia   = lbl_frac_stats_z(sub, "grim_cone_ia",  "grim_pbp_cone"),
            pb_red  = lbl_frac_stats_z(sub, "grim_cone_red", "grim_pbp_cone"),
            # label-origin view (labeled level-0 vs unlabeled = search+intermediate)
            pb_loop      = lbl_frac_stats(sub, "grim_cone_loop",    "grim_pbp_cone"),
            pb_elimnds   = lbl_frac_stats(sub, "grim_cone_elimnds", "grim_pbp_cone"),
            pb_elimdeg   = lbl_frac_stats(sub, "grim_cone_elimdeg", "grim_pbp_cone"),
            pb_g1adj     = lbl_frac_stats(sub, "grim_cone_g1adj",   "grim_pbp_cone"),
            pb_g2adj     = lbl_frac_stats(sub, "grim_cone_g2adj",   "grim_pbp_cone"),
            pb_g3adj     = lbl_frac_stats(sub, "grim_cone_g3adj",   "grim_pbp_cone"),
            pb_unlabeled = row_diff_frac_stats(sub, "grim_pbp_cone",
                ["grim_cone_loop","grim_cone_elimnds","grim_cone_elimdeg",
                 "grim_cone_g1adj","grim_cone_g2adj","grim_cone_g3adj"], "grim_pbp_cone"),
            # §7b stacked bar: _z variants (missing → 0) so bars sum to 1 over all instances with opb_cone > 0
            obz_al1    = lbl_frac_stats_z(sub, "grim_cone_al1",   "grim_opb_cone"),
            obz_am1    = lbl_frac_stats_z(sub, "grim_cone_am1",   "grim_opb_cone"),
            obz_inj    = lbl_frac_stats_z(sub, "grim_cone_inj",   "grim_opb_cone"),
            obz_g0adj  = lbl_frac_stats_z(sub, "grim_cone_g0adj", "grim_opb_cone"),
            obz_forb   = lbl_frac_stats_z(sub, "grim_cone_forb",  "grim_opb_cone"),
            # §7c stacked bar: _z variants for PBP label-origin (missing → 0, same pop as pb_unlabeled)
            pbz_loop    = lbl_frac_stats_z(sub, "grim_cone_loop",    "grim_pbp_cone"),
            pbz_elimnds = lbl_frac_stats_z(sub, "grim_cone_elimnds", "grim_pbp_cone"),
            pbz_elimdeg = lbl_frac_stats_z(sub, "grim_cone_elimdeg", "grim_pbp_cone"),
            pbz_g1adj   = lbl_frac_stats_z(sub, "grim_cone_g1adj",   "grim_pbp_cone"),
            pbz_g2adj   = lbl_frac_stats_z(sub, "grim_cone_g2adj",   "grim_pbp_cone"),
            pbz_g3adj   = lbl_frac_stats_z(sub, "grim_cone_g3adj",   "grim_pbp_cone"),
            n_with_labels   = nrow(sub),
            n_unlabeled_pos = "grim_cone_unlabeled" ∈ names(sub) ?
                count(i -> !ismissing(sub[i,"grim_cone_unlabeled"]) && sub[i,"grim_cone_unlabeled"] > 0, 1:nrow(sub)) : 0,
            max_unlabeled   = "grim_cone_unlabeled" ∈ names(sub) ?
                let v = collect(skipmissing(sub[!, "grim_cone_unlabeled"]))
                    isempty(v) ? 0 : maximum(v)
                end : 0,
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
                fmtf(fd(f).med_p50, 1), fmtf(fd(f).med_p90, 1),
                fmtf(fd(f).med_width_max, 0), fmtf(fd(f).med_width_cv, 3),
                fmtf(fd(f).med_lit_weak, 4), fmtpct(fd(f).burst_pct)]
               for f in present]
    sh_html = html_table(
        ["Family", "n", "median entropy", "median bottom_frac", "median depth p50",
         "median depth p90", "median width_max", "median width_cv",
         "median lit_weak_rate", "POL-burst %"],
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

    # ── Section 7: CP constraint provenance table ────────────────────────────────
    function lbl_cell(ls)
        isnan(ls.mean) && return "—"
        "$(fmtpct(ls.mean)) ($(fmtpct(ls.med))) [$(fmtpct(ls.q1))–$(fmtpct(ls.q3))]"
    end
    # Like lbl_cell but appends (n=X) when label is sparse (n < ntot).
    function lbl_cell_n(ls, ntot)
        isnan(ls.mean) && return "—"
        n_tag = ls.n < ntot ? " (n=$(ls.n))" : ""
        "$(fmtpct(ls.mean)) ($(fmtpct(ls.med))) [$(fmtpct(ls.q1))–$(fmtpct(ls.q3))]$n_tag"
    end
    prov_rows = [[f, fd(f).n_with_labels,
                  lbl_cell(fd(f).ls_al1), lbl_cell(fd(f).ls_am1), lbl_cell(fd(f).ls_inj),
                  lbl_cell(fd(f).ls_g0adj),
                  lbl_cell_n(fd(f).ls_g1adj, fd(f).n_with_labels),
                  lbl_cell_n(fd(f).ls_g2adj, fd(f).n_with_labels),
                  lbl_cell_n(fd(f).ls_g3adj, fd(f).n_with_labels),
                  lbl_cell(fd(f).ls_forb),
                  lbl_cell_n(fd(f).ls_elimdeg, fd(f).n_with_labels),
                  lbl_cell_n(fd(f).ls_elimnds, fd(f).n_with_labels),
                  lbl_cell_n(fd(f).ls_loop,    fd(f).n_with_labels),
                  lbl_cell(fd(f).ls_unlabeled_total),
                  lbl_cell(fd(f).pb_unlabeled_total)] for f in present]
    prov_html = html_table(
        ["Family", "n", "al1", "am1", "inj", "g0adj", "g1adj", "g2adj", "g3adj",
         "forb", "elimdeg", "elimnds", "loop", "unlab OPB", "unlab PBP"],
        prov_rows)

    # ── Section 7b: OPB axiom breakdown ──────────────────────────────────────────
    prov_b_rows = [[f, fd(f).n_with_labels,
                    lbl_cell(fd(f).ob_al1), lbl_cell(fd(f).ob_am1), lbl_cell(fd(f).ob_inj),
                    lbl_cell(fd(f).ob_g0adj), lbl_cell(fd(f).ob_forb),
                    lbl_cell(fd(f).ob_unlabeled)] for f in present]
    prov_b_html = html_table(
        ["Family", "n", "al1", "am1", "inj", "g0adj", "forb", "unlabeled"],
        prov_b_rows)

    # ── Section 7c: PBP cone breakdown ───────────────────────────────────────────
    # Table 1: step-type view (sums to 100% for instances with pbp_cone > 0)
    prov_c_step_rows = [[f, fd(f).pb_rup.n,
                         lbl_cell(fd(f).pb_rup),  lbl_cell(fd(f).pb_pol),
                         lbl_cell(fd(f).pb_ia),   lbl_cell(fd(f).pb_red)] for f in present]
    prov_c_step_html = html_table(
        ["Family", "n (pbp>0)", "RUP", "POL", "IA", "RED"],
        prov_c_step_rows)
    # Table 2: label-origin view (labeled level-0 vs unlabeled, sums to 100%)
    prov_c_lbl_rows = [[f, fd(f).pb_rup.n,
                        lbl_cell_n(fd(f).pb_loop,    fd(f).pb_rup.n),
                        lbl_cell_n(fd(f).pb_elimnds, fd(f).pb_rup.n),
                        lbl_cell_n(fd(f).pb_elimdeg, fd(f).pb_rup.n),
                        lbl_cell_n(fd(f).pb_g1adj,   fd(f).pb_rup.n),
                        lbl_cell_n(fd(f).pb_g2adj,   fd(f).pb_rup.n),
                        lbl_cell_n(fd(f).pb_g3adj,   fd(f).pb_rup.n),
                        lbl_cell(fd(f).pb_unlabeled)] for f in present]
    prov_c_lbl_html = html_table(
        ["Family", "n (pbp>0)", "loop (RUP)", "elimnds (RUP)", "elimdeg (IA)",
         "g1adj (IA)", "g2adj (IA)", "g3adj (IA)", "unlabeled (Hall POL + search + intermed)"],
        prov_c_lbl_rows)
    # Table 3: cross-check — unlabeled PBP fraction by search presence
    SOLVER_COL = "solver_nodes"
    function pbp_unlab_by_search(sub)
        has_col = SOLVER_COL ∈ names(sub)
        minus_cols = ["grim_cone_loop","grim_cone_elimnds","grim_cone_elimdeg",
                      "grim_cone_g1adj","grim_cone_g2adj","grim_cone_g3adj"]
        if has_col
            nosearch_mask = [ismissing(sub[i, SOLVER_COL]) || sub[i, SOLVER_COL] <= 1 for i in 1:nrow(sub)]
            search_mask   = [!ismissing(sub[i, SOLVER_COL]) && sub[i, SOLVER_COL] > 1  for i in 1:nrow(sub)]
            ns = row_diff_frac_stats(sub[nosearch_mask, :], "grim_pbp_cone", minus_cols, "grim_pbp_cone")
            sr = row_diff_frac_stats(sub[search_mask,   :], "grim_pbp_cone", minus_cols, "grim_pbp_cone")
            (nosearch=ns, search=sr,
             n_nosearch=sum(nosearch_mask), n_search=sum(search_mask))
        else
            nothing
        end
    end
    cross_rows = []
    for f in present
        mask = isequal.(jdf.family, f) .& (jdf.has_proof .== true)
        sub  = jdf[mask, :]
        r = pbp_unlab_by_search(sub)
        if r === nothing
            push!(cross_rows, [f, "—", "—", "—", "—", "—"])
        else
            push!(cross_rows, [f,
                r.n_nosearch, isnan(r.nosearch.mean) ? "—" : fmtpct(r.nosearch.mean),
                r.n_search,   isnan(r.search.mean)   ? "—" : fmtpct(r.search.mean),
                isnan(r.nosearch.mean) || isnan(r.search.mean) ? "—" :
                    fmtpct(r.search.mean - r.nosearch.mean)])
        end
    end
    prov_c_cross_html = html_table(
        ["Family", "n no-search", "unlabeled PBP (no search)", "n search", "unlabeled PBP (search)", "Δ (search−no-search)"],
        cross_rows)

    # ── Section 8: CP composition stacked bar ────────────────────────────────────
    LC = (al1="#1a6fbf", am1="#7ab3e8", inj="#e85b5b",
          g0adj="#1b7837", g1adj="#5aae61", g2adj="#a6dba0", g3adj="#d9f0d3",
          forb="#ff7f0e", elimdeg="#9467bd", elimnds="#c5a0d3", loop="#8c564b",
          unlabeled_opb="#dddddd", unlabeled_pbp="#aaaaaa")
    mean_arr(field) = json_num_arr([let ls = getfield(fd(f), field); isnan(ls.mean) ? NaN : ls.mean end for f in present])
    med_arr(field)  = json_num_arr([let ls = getfield(fd(f), field); isnan(ls.med)  ? NaN : ls.med  end for f in present])

    comp_chart_mean = stacked_bar_chart("cpCompMean", present,
        [("al1 (≥1 domain)",          LC.al1,           mean_arr(:ls_al1)),
         ("am1 (≤1 domain)",          LC.am1,           mean_arr(:ls_am1)),
         ("inj (injectivity)",        LC.inj,           mean_arr(:ls_inj)),
         ("g0adj (base adj)",         LC.g0adj,         mean_arr(:ls_g0adj)),
         ("forb (forbidden)",         LC.forb,          mean_arr(:ls_forb)),
         ("unlabeled OPB",            LC.unlabeled_opb, mean_arr(:ls_unlabeled_total)),
         ("loop (PBP)",               LC.loop,          mean_arr(:sz_loop)),
         ("elimnds (NDS, PBP)",       LC.elimnds,       mean_arr(:sz_elimnds)),
         ("elimdeg (degree, PBP)",    LC.elimdeg,       mean_arr(:sz_elimdeg)),
         ("g1adj (supp. 1, PBP)",     LC.g1adj,         mean_arr(:sz_g1adj)),
         ("g2adj (supp. 2, PBP)",     LC.g2adj,         mean_arr(:sz_g2adj)),
         ("g3adj (supp. 3, PBP)",     LC.g3adj,         mean_arr(:sz_g3adj)),
         ("unlabeled PBP (search+intermed)", LC.unlabeled_pbp, mean_arr(:pb_unlabeled_total))];
        ytitle="fraction of total cone (OPB+PBP)")
    comp_chart_med = stacked_bar_chart("cpCompMed", present,
        [("al1",                 LC.al1,           med_arr(:ls_al1)),
         ("am1",                 LC.am1,           med_arr(:ls_am1)),
         ("inj",                 LC.inj,           med_arr(:ls_inj)),
         ("g0adj",               LC.g0adj,         med_arr(:ls_g0adj)),
         ("forb",                LC.forb,          med_arr(:ls_forb)),
         ("unlabeled OPB",       LC.unlabeled_opb, med_arr(:ls_unlabeled_total)),
         ("loop",                LC.loop,          med_arr(:sz_loop)),
         ("elimnds",             LC.elimnds,       med_arr(:sz_elimnds)),
         ("elimdeg",             LC.elimdeg,       med_arr(:sz_elimdeg)),
         ("g1adj",               LC.g1adj,         med_arr(:sz_g1adj)),
         ("g2adj",               LC.g2adj,         med_arr(:sz_g2adj)),
         ("g3adj",               LC.g3adj,         med_arr(:sz_g3adj)),
         ("unlabeled PBP",       LC.unlabeled_pbp, med_arr(:pb_unlabeled_total))];
        ytitle="fraction of total cone (OPB+PBP)")

    # ── Sections 7b / 7c stacked bars ────────────────────────────────────────────
    chart7b = stacked_bar_chart("opbCompChart", present,
        [("al1",       LC.al1,           mean_arr(:obz_al1)),
         ("am1",       LC.am1,           mean_arr(:obz_am1)),
         ("inj",       LC.inj,           mean_arr(:obz_inj)),
         ("g0adj",     LC.g0adj,         mean_arr(:obz_g0adj)),
         ("forb",      LC.forb,          mean_arr(:obz_forb)),
         ("unlabeled", LC.unlabeled_opb, mean_arr(:ob_unlabeled))];
        ytitle="fraction of OPB axioms in cone")
    chart7c_step = stacked_bar_chart("pbpStepChart", present,
        [("RUP", C.rup, mean_arr(:pb_rup)),
         ("POL", C.pol, mean_arr(:pb_pol)),
         ("IA",  C.ia,  mean_arr(:pb_ia)),
         ("RED", C.red, mean_arr(:pb_red))];
        ytitle="fraction of PBP cone steps")
    chart7c_lbl = stacked_bar_chart("pbpLblChart", present,
        [("loop (RUP)",    LC.loop,          mean_arr(:pbz_loop)),
         ("elimnds (RUP)", LC.elimnds,       mean_arr(:pbz_elimnds)),
         ("elimdeg (IA)",  LC.elimdeg,       mean_arr(:pbz_elimdeg)),
         ("g1adj (IA)",    LC.g1adj,         mean_arr(:pbz_g1adj)),
         ("g2adj (IA)",    LC.g2adj,         mean_arr(:pbz_g2adj)),
         ("g3adj (IA)",    LC.g3adj,         mean_arr(:pbz_g3adj)),
         ("unlabeled",     LC.unlabeled_pbp, mean_arr(:pb_unlabeled))];
        ytitle="fraction of PBP cone steps")

    # ── Section 9: Supplemental graph depth ──────────────────────────────────────
    # All four on grim_total_cone so depths are directly comparable.
    # Autoscale when total adjacency is small so bars aren't invisible at scale 0–1.
    max_gadj = let vals = [sum(isnan(getfield(fd(f), ls).mean) ? 0.0 : getfield(fd(f), ls).mean
                               for ls in (:sz_g0adj, :sz_g1adj, :sz_g2adj, :sz_g3adj))
                           for f in present]
                   isempty(vals) ? 0.0 : maximum(vals)
               end
    ymax_gadj = max_gadj >= 0.1 ? 1.0 : NaN
    supp9_chart = stacked_bar_chart("supp9Chart", present,
        [("g0adj (base, OPB)",   LC.g0adj, mean_arr(:sz_g0adj)),
         ("g1adj (depth 1, PBP)", LC.g1adj, mean_arr(:sz_g1adj)),
         ("g2adj (depth 2, PBP)", LC.g2adj, mean_arr(:sz_g2adj)),
         ("g3adj (depth 3, PBP)", LC.g3adj, mean_arr(:sz_g3adj))];
        ytitle="fraction of total cone (adjacency constraints by depth)",
        ymax=ymax_gadj)

    # ── Section 10: Elim fraction vs proof depth (scatter) ───────────────────────
    scatter_fam_colors = Dict(
        "LV"            => "rgba(0,76,201,0.45)",
        "bio"           => "rgba(237,125,49,0.45)",
        "images-CVIU11" => "rgba(27,120,55,0.45)",
        "images-PR15"   => "rgba(90,174,97,0.45)",
        "meshes-CVIU11" => "rgba(200,160,0,0.65)",
        "phase"         => "rgba(112,48,160,0.45)",
        "scalefree"     => "rgba(192,0,0,0.45)",
        "si"            => "rgba(0,140,200,0.45)")
    scatter_datasets = String[]
    for f in present
        mask  = isequal.(proof_jdf.family, f)
        sub_f = proof_jdf[mask, :]
        pts   = String[]
        for i in 1:nrow(sub_f)
            pbp   = "grim_pbp_cone"       ∈ names(sub_f) ? sub_f[i,"grim_pbp_cone"]       : missing
            depth = "grim_cone_depth_max"  ∈ names(sub_f) ? sub_f[i,"grim_cone_depth_max"]  : missing
            (ismissing(pbp) || ismissing(depth) || pbp == 0) && continue
            elim = 0.0
            for col in ("grim_cone_elimnds", "grim_cone_elimdeg")
                col ∈ names(sub_f) || continue
                v = sub_f[i, col]; ismissing(v) || (elim += Float64(v))
            end
            push!(pts, "{x:$(round(elim/Float64(pbp);digits=4)),y:$(Float64(depth))}")
        end
        isempty(pts) && continue
        color = get(scatter_fam_colors, f, "rgba(120,120,120,0.4)")
        push!(scatter_datasets,
            "{ label: $(repr(f)), backgroundColor: $(repr(color)), pointRadius: 3, data: [$(join(pts, ","))] }")
    end
    scatter_js   = join(scatter_datasets, ",\n")
    scatter_html = isempty(scatter_js) ? "<p class=\"note\">No elim data available yet.</p>" : """
    <div class="chart-box" style="width:760px;height:400px"><canvas id="elimDepthScatter"></canvas></div>
    <script>
    new Chart(document.getElementById("elimDepthScatter"), {
      type: "scatter",
      data: { datasets: [$scatter_js] },
      options: {
        responsive: true, maintainAspectRatio: false,
        plugins: { legend: { position: "right" } },
        scales: {
          x: { min: 0, title: { display: true, text: "(elimdeg + elimnds) / pbp_cone" } },
          y: { min: 0, title: { display: true, text: "cone depth max" } }
        }
      }
    });
    </script>
    """

    # ── Section 12: POL step structure ───────────────────────────────────────────
    pol_rows = [[f, fd(f).n,
                 fmtf(fd(f).med_pol_depth_mean, 2), fmtf(fd(f).med_pol_depth_cv, 3),
                 fmtpct(fd(f).med_pol_depth_frac_bot), fmtpct(fd(f).med_pol_depth_frac_top),
                 fmtf(fd(f).med_pol_ante_mean, 2), fmtf(fd(f).med_pol_ante_max, 0),
                 fmtpct(fd(f).med_pol_opb_frac)] for f in present]
    pol_html = html_table(
        ["Family", "n", "pol_depth_mean", "pol_depth_cv",
         "pol_frac_bot", "pol_frac_top",
         "pol_ante_mean", "pol_ante_max", "pol_opb_frac"],
        pol_rows)

    # ── Section 13: Branching heuristic — unique pattern nodes in OPB cone ───────
    uniq_rows = [[f, fd(f).n, fmtf(fd(f).med_uniq_pat, 0)] for f in present]
    uniq_html = html_table(["Family", "n", "median uniq_pat"], uniq_rows)

    # ── Section 11: Label coverage check ─────────────────────────────────────────
    cov_rows = [[f, fd(f).n, fd(f).n_with_labels,
                 fd(f).n_with_labels == 0 ? "no data" :
                     (fd(f).n_unlabeled_pos == 0 ? "✓ 0" : "⚠ $(fd(f).n_unlabeled_pos)"),
                 fd(f).max_unlabeled == 0 ? "0" : "⚠ $(fd(f).max_unlabeled)"]
                for f in present]
    cov_html = html_table(
        ["Family", "n total", "n with label data", "instances with unlabeled>0", "max unlabeled count"],
        cov_rows)

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

    <h2>7 — CP Constraint Provenance by Family</h2>
    <p class="note">Each cell: <strong>mean (median) [Q1–Q3]</strong> of the fraction of the <em>total cone</em>
    (OPB axioms + PBP level-0 + search PBP) attributed to each CP label category.
    Denominator = <code>grim_total_cone</code>. All columns are exhaustive: OPB labels + unlab OPB + PBP labels + unlab PBP = 100%.
    OPB labels (al1/am1/inj/g0adj/forb) live in the <code>.opb</code> file.
    PBP labels (g1/2/3adj, loop, elimdeg, elimnds) are level-0 derived steps in the <code>.pbp</code> file.
    Sparse labels (loop/elim/gNadj) show <em>(n=X)</em> when computed over fewer than all instances.</p>
    <p class="note">Categories: <em>al1</em> = at-least-one domain; <em>am1</em> = at-most-one domain;
    <em>inj</em> = injectivity; <em>g0adj</em> = base adjacency (OPB);
    <em>g1/2/3adj</em> = supplemental graph adjacency depth 1/2/3 (PBP level-0);
    <em>forb</em> = pre-search forbidden assignment (OPB);
    <em>elimdeg</em> = degree-incompatibility (PBP level-0, IA type);
    <em>elimnds</em> = NDS-incompatibility (PBP level-0, RUP type);
    <em>loop</em> = loop incompatibility (PBP, RUP type, only on instances with self-loops);
    <em>unlab OPB</em> = OPB axioms with no matching label (should be ~0 after M3.5);
    <em>unlab PBP</em> = PBP steps that are search-level or inherently unlabeled (Hall POL, intermediate POL).</p>
    $prov_html
    <p class="note">Mean composition — bars sum to 1 (exhaustive decomposition of total cone). Sparse PBP labels use missing→0 so the stacked mean is consistent:</p>
    $comp_chart_mean
    <p class="note">Median chart (more robust to outliers):</p>
    $comp_chart_med

    <h2>7b — OPB Axiom Breakdown</h2>
    <p class="note">Fraction of <em>OPB axioms in the cone</em> from each OPB label.
    Denominator = <code>grim_opb_cone</code>. These five categories + unlabeled sum to 100%.
    <em>unlabeled</em> = OPB axioms with no label (should be 0 after M3.5 — see §11).</p>
    $prov_b_html
    <p class="note">Mean composition (bars sum to 1):</p>
    $chart7b

    <h2>7c — PBP Cone Breakdown</h2>
    <p class="note">Denominator = <code>grim_pbp_cone</code> (all derived steps in cone).
    Only instances with at least one PBP step in the cone are included (n shown).
    <strong>Step-type view</strong> (below) must sum to 100%.
    <strong>Label-origin view</strong> separates labeled level-0 preprocessing steps from
    unlabeled steps = search-level RUP/POL/IA <em>plus</em> inherently unlabeled preprocessing
    (e.g. Hall-violator POL from <code>emit_hall_set_or_violator</code>, intermediate POL inside
    <code>incompatible_by_degrees</code>). Unlabeled ≈ 100% does not imply search.</p>
    <p class="note"><strong>Step-type view</strong> — RUP+POL+IA+RED = 100% of PBP cone:</p>
    $prov_c_step_html
    <p class="note">Mean step-type composition:</p>
    $chart7c_step
    <p class="note"><strong>Label-origin view</strong> — labeled level-0 + unlabeled = 100% of PBP cone.
    Sparse labels show (n=X). Missing labels treated as 0 for the stacked mean.</p>
    $prov_c_lbl_html
    <p class="note">Mean label-origin composition:</p>
    $chart7c_lbl
    <p class="note"><strong>Cross-check: unlabeled PBP by search presence</strong> — instances split by
    <code>solver_nodes &gt; 1</code>. The Δ measures how much additional unlabeled PBP search adds
    beyond the baseline from unlabeled preprocessing (Hall POL, intermediate POL).</p>
    $prov_c_cross_html

    <h2>9 — Supplemental Graph Depth Analysis</h2>
    <p class="note">All four adjacency depths expressed as fraction of <code>grim_total_cone</code>
    so they are directly comparable. Stack height = total adjacency burden in the cone;
    colour breakdown = which depth contributes.
    g0adj is an OPB axiom (base graph); g1/g2/g3adj are PBP level-0 derived steps (supplemental graphs).
    If gNadj ≈ 0, supplemental constraints at depth N are not proof-critical
    (candidate <code>--no-supplementals</code> flag for that family).
    Y-axis autoscales when total adjacency fraction is below 10%.</p>
    $supp9_chart

    <h2>10 — Elimination Fraction vs Proof Depth (Scatter)</h2>
    <p class="note">Each point = one instance.
    X = (elimdeg + elimnds) / <code>grim_pbp_cone</code> — elimination steps as fraction of all PBP cone steps.
    Y = maximum cone depth.
    Hypothesis: instances where preprocessing eliminates many assignments have shallower proofs
    (UNSAT certified by direct elimination chains without deep search propagation).
    A negative correlation supports that degree/NDS preprocessing reduces search depth.</p>
    $scatter_html

    <h2>11 — Label Coverage Check</h2>
    <p class="note">Diagnostic section. <em>n with label data</em> = instances whose proofs were generated
    after the M3.5 label additions (Glasgow commit de50e8c).
    <em>unlabeled</em> = OPB constraints in the cone with no matching label — should be 0 if
    the label taxonomy is complete. ⚠ warnings require investigation.</p>
    $cov_html

    <h2>12 — POL Step Structure</h2>
    <p class="note">All values are medians across proof instances in each family.<br>
    <em>pol_depth_mean</em>: mean depth of POL steps in the cone (relative to proof depth).
    <em>pol_depth_cv</em>: coefficient of variation of POL step depths — high = POL steps scattered across many levels.
    <em>pol_frac_bot/top</em>: fraction of POL steps at the bottom (depth ≤ 2) / top (depth ≥ depth_max−1) of the cone.
    <em>pol_ante_mean/max</em>: antecedent count per POL step (how many prior steps each POL combines).
    <em>pol_opb_frac</em>: fraction of POL antecedents that are OPB axioms (vs derived PBP steps).</p>
    $pol_html

    <h2>13 — Branching Heuristic: Unique Pattern Nodes in OPB Cone (M3.5.3)</h2>
    <p class="note"><em>uniq_pat</em> = number of distinct pattern graph vertices appearing in the OPB axioms
    kept in the cone. A smaller value means fewer pattern nodes are proof-critical — strong signal for
    branching order prioritisation. Written per-instance to <code>.var_order</code>.</p>
    $uniq_html
    </body>
    </html>
    """

    write(out_html, html)
    println("Wrote $out_html  ($n_total instances, $(length(present)) families)")
end

main()
