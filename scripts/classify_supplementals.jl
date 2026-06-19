#!/usr/bin/env julia
# Supplemental-graph usage classifier — training pipeline (steps 1–3).
# Joins graph_features.csv with cluster_results.csv, computes per-family
# usage stats for cone labels (g1adj, g2adj, g3adj, pathg, d2g, d3g), and
# ranks structural features by correlation with each target (binary).
# Output: terminal report + HTML + text file.
#
# Usage:
#   julia --project=scripts scripts/classify_supplementals.jl \
#       cluster_results.csv graph_features.csv [out.html]
#
# Always writes: <out>.html  (human report)  +  <out>.txt  (machine log)
# Default base:  classify_supplementals

using CSV, DataFrames, Statistics, Printf

# ── Constants ─────────────────────────────────────────────────────────────────

const FAMILIES = ["LV", "bio", "images-CVIU11", "images-PR15",
                  "meshes-CVIU11", "phase", "scalefree", "si"]

const FEATURES_RAW = [
    :pat_nodes,   :pat_edges,     :pat_density,
    :pat_deg_min, :pat_deg_max,   :pat_deg_mean,  :pat_deg_var,
    :pat_triangles, :pat_clustering,
    :pat_diameter,  :pat_radius,  :pat_girth,
    :pat_is_regular, :pat_is_bipartite,
    :tar_nodes,   :tar_edges,     :tar_density,
    :tar_deg_min, :tar_deg_max,   :tar_deg_mean,  :tar_deg_var,
    :tar_triangles, :tar_clustering,
    :tar_diameter,  :tar_radius,  :tar_girth,
    :tar_is_regular, :tar_is_bipartite,
    :node_ratio,  :density_ratio, :max_degree_ratio,
    :diameter_ratio, :degree_compat_frac,
    # Core graph features (from UNSAT core extraction)
    :core_pat_nodes,  :core_pat_edges,    :core_pat_density,
    :core_pat_deg_min,:core_pat_deg_max,  :core_pat_deg_mean, :core_pat_deg_var,
    :core_pat_triangles, :core_pat_clustering,
    :core_pat_diameter,  :core_pat_radius, :core_pat_girth,
    :core_pat_is_regular, :core_pat_is_bipartite,
    :core_tar_nodes,  :core_tar_edges,    :core_tar_density,
    :core_tar_deg_min,:core_tar_deg_max,  :core_tar_deg_mean, :core_tar_deg_var,
    :core_tar_triangles, :core_tar_clustering,
    :core_tar_diameter,  :core_tar_radius, :core_tar_girth,
    :core_tar_is_regular, :core_tar_is_bipartite,
    :core_node_ratio, :core_density_ratio, :core_max_degree_ratio,
    :core_diameter_ratio, :core_degree_compat_frac,
    # Original → core comparison
    :core_pat_node_shrink, :core_tar_node_shrink,
    :core_pat_density_shift, :core_tar_density_shift,
]

const LOG1P_FEATURES = [
    :pat_triangles, :tar_triangles,
    :pat_edges,     :tar_edges,
    :pat_nodes,     :tar_nodes,
    :pat_deg_var,   :tar_deg_var,
    :core_pat_triangles, :core_tar_triangles,
    :core_pat_edges,     :core_tar_edges,
    :core_pat_nodes,     :core_tar_nodes,
    :core_pat_deg_var,   :core_tar_deg_var,
]

const REDUNDANT_WITH = Dict(
    :pat_clustering      => :pat_triangles,
    :tar_clustering      => :tar_triangles,
    :core_pat_clustering => :core_pat_triangles,
    :core_tar_clustering => :core_tar_triangles,
)

# ── Output tee — writes to terminal + accumulated log buffer ──────────────────

const _LOG = IOBuffer()

tprint(args...)   = (print(args...);   print(_LOG, args...))
tprintln(args...) = (println(args...); println(_LOG, args...))

function tprintf(fmt::String, args...)
    buf = IOBuffer()
    Printf.format(buf, Printf.Format(fmt), args...)
    s = String(take!(buf))
    print(s); print(_LOG, s)
end

function save_log(path::String)
    write(path, String(take!(copy(_LOG))))
    println("Report saved → $path")
end

# ── Helpers ───────────────────────────────────────────────────────────────────

function instance_family(ins::AbstractString)
    startswith(ins, "LV")     && return "LV"
    startswith(ins, "bio")    && return "bio"
    startswith(ins, "cviu11") && return "images-CVIU11"
    startswith(ins, "pr15")   && return "images-PR15"
    startswith(ins, "mesh11") && return "meshes-CVIU11"
    startswith(ins, "ph_")    && return "phase"
    startswith(ins, "sf_")    && return "scalefree"
    startswith(ins, "si__")   && return "si"
    return "unknown"
end

nonnull_vec(df, col) = Float64[x for x in skipmissing(df[!, col])]

function safe_cor(x::Vector{Float64}, y::Vector{Float64})
    length(x) < 5 && return NaN
    sx = std(x); sy = std(y)
    (sx == 0 || sy == 0) && return NaN
    cor(x, y)
end

function univariate_auc(x::Vector{Float64}, y_bool::Vector{Bool})
    n_pos = sum(y_bool); n_neg = length(y_bool) - n_pos
    (n_pos == 0 || n_neg == 0) && return 0.5
    order = sortperm(x)
    concordant = 0; n_neg_seen = 0
    for i in order
        y_bool[i] ? (concordant += n_neg_seen) : (n_neg_seen += 1)
    end
    auc = concordant / (n_pos * n_neg)
    auc < 0.5 ? 1.0 - auc : auc
end

function pearson_pvalue(r::Float64, n::Int)
    n < 3 && return NaN
    t  = r * sqrt(n - 2) / sqrt(max(1 - r^2, 1e-15))
    df = n - 2
    if df > 30
        z = abs(t) * (1 - 1/(4df))
        return 2 * 0.5 * erfc(z / sqrt(2))
    end
    _betai(df / (df + t^2), df / 2.0, 0.5)
end

function erfc(x::Float64)
    x < 0 && return 2.0 - erfc(-x)
    t = 1.0 / (1.0 + 0.3275911 * x)
    poly = t * (0.254829592 + t * (-0.284496736 + t * (1.421413741 +
                t * (-1.453152027 + t * 1.061405429))))
    poly * exp(-x * x)
end

lgamma(x::Float64) = ccall(:lgamma, Float64, (Float64,), x)

function _betai(x::Float64, a::Float64, b::Float64)
    x <= 0 && return 0.0; x >= 1 && return 1.0
    lbeta = lgamma(a + b) - lgamma(a) - lgamma(b)
    front = exp(log(x)*a + log(1-x)*b - lbeta) / a
    f = 1.0; C = 1.0; D = 1.0 - (a+b)*x/(a+1)
    abs(D) < 1e-30 && (D = 1e-30); D = 1/D; f = D
    for m in 1:100
        nm = a + 2m - 1
        d  = m*(b-m)*x / ((nm-1)*nm)
        D = 1 + d*D; abs(D)<1e-30 && (D=1e-30); D=1/D
        C = 1 + d/C; abs(C)<1e-30 && (C=1e-30); f *= C*D
        d  = -(a+m)*(a+b+m)*x / ((nm+1)*nm)
        D = 1 + d*D; abs(D)<1e-30 && (D=1e-30); D=1/D
        C = 1 + d/C; abs(C)<1e-30 && (C=1e-30)
        delta = C*D; f *= delta
        abs(delta-1) < 1e-10 && break
    end
    front * f
end

sig_stars(p) = isnan(p) ? "   " : p < 0.001 ? "***" : p < 0.01 ? "** " : p < 0.05 ? "*  " : "   "
auc_label(a) = a >= 0.75 ? "good" : a >= 0.65 ? "mod " : a >= 0.58 ? "weak" : "~rnd"

function rate_str(n_pos::Int, n_tot::Int)
    n_tot == 0 && return "   —  "
    @sprintf("%3.0f%%(%4d)", 100 * n_pos / n_tot, n_tot)
end

# ── Step 1 — Load and join ────────────────────────────────────────────────────

function load_and_join(cluster_csv, graph_csv)
    println("Loading $cluster_csv ...")
    df_proof = CSV.read(cluster_csv, DataFrame; missingstring=["", "NA"])
    println("  $(nrow(df_proof)) rows")

    println("Loading $graph_csv ...")
    df_graph = CSV.read(graph_csv, DataFrame; missingstring=["", "NA"])
    println("  $(nrow(df_graph)) rows")

    df = innerjoin(df_proof, df_graph; on=:instance)
    println("  $(nrow(df)) rows after inner join")
    n_proof_total = sum(coalesce.(df_proof.has_proof, false) .== true)
    coverage = round(Int, 100 * nrow(df) / max(n_proof_total, 1))
    n_proof_total > nrow(df) && println("  NOTE: graph_features covers ~$(coverage)% of proof instances — regenerate graph_features.csv to improve coverage.")

    df.family       = instance_family.(df.instance)
    df.g1adj_used   = coalesce.(df.grim_cone_g1adj, 0) .> 0
    df.solver_nodes = coalesce.(df.solver_nodes, 0)
    df.g1adj_count  = coalesce.(df.grim_cone_g1adj, 0)
    df.g2adj_count  = coalesce.(df.grim_cone_g2adj, 0)
    df.g3adj_count  = coalesce.(df.grim_cone_g3adj, 0)
    df.g0adj_count  = coalesce.(df.grim_cone_g0adj, 0)
    df.g1adj_ratio  = df.g1adj_count ./ max.(df.g0adj_count, 1)
    df.g2adj_used   = coalesce.(df.grim_cone_g2adj, 0) .> 0
    df.g3adj_used   = coalesce.(df.grim_cone_g3adj, 0) .> 0
    for g in (1, 2, 3)
        for pfx in ("pathg", "d2g", "d3g")
            col = "grim_cone_$(pfx)$(g)"
            sym_used  = Symbol("$(pfx)$(g)_used")
            sym_count = Symbol("$(pfx)$(g)_count")
            if col ∈ names(df)
                df[!, sym_used]  = coalesce.(df[!, col], 0) .> 0
                df[!, sym_count] = coalesce.(df[!, col], 0)
            else
                df[!, sym_used]  = fill(false, nrow(df))
                df[!, sym_count] = fill(0, nrow(df))
            end
        end
    end
    df.supp1_used = df.g1adj_used .| df.pathg1_used .| df.d2g1_used .| df.d3g1_used
    df.supp2_used = df.g2adj_used .| df.pathg2_used .| df.d2g2_used .| df.d3g2_used
    df.supp3_used = df.g3adj_used .| df.pathg3_used .| df.d2g3_used .| df.d3g3_used
    df.supp1_count = df.g1adj_count .+ df.pathg1_count .+ df.d2g1_count .+ df.d3g1_count
    df.supp2_count = df.g2adj_count .+ df.pathg2_count .+ df.d2g2_count .+ df.d3g2_count
    df.supp3_count = df.g3adj_count .+ df.pathg3_count .+ df.d2g3_count .+ df.d3g3_count

    has_proof = df.has_proof .=== true
    has_cone  = .!ismissing.(df.grim_total_cone)
    df_clean  = df[has_proof .& has_cone, :]
    println("  $(nrow(df_clean)) usable rows (has_proof & cone data)")
    df_clean
end

# ── Step 2 — Per-family stats ─────────────────────────────────────────────────

function per_family_stats(df, label="ALL";
        target="g1adj", used_col=:g1adj_used, count_col=:g1adj_count)
    tprintln("\n── Per-family $(target) usage ($(label)) ──────────────────────────────────")
    tprintf("%-18s  %6s  %6s  %5s  %8s\n",
        "family", "total", "$(target)>0", "rate", "med_$(target)")
    tprintln(repeat("─", 60))

    results = NamedTuple[]
    missing_fams = String[]
    for fam in FAMILIES
        sub = df[isequal.(df.family, fam), :]
        if nrow(sub) == 0
            push!(missing_fams, fam)
            continue
        end
        n     = nrow(sub)
        n_pos = sum(sub[!, used_col])
        rate  = n_pos / n
        gv    = Float64.(sub[!, count_col])

        tprintf("%-18s  %6d  %6d  %4.0f%%  %8.0f\n",
            fam, n, n_pos, 100rate, median(gv))

        push!(results, (family=fam, n=n, n_pos=n_pos, rate=rate,
            med_target=median(gv)))
    end
    if !isempty(missing_fams)
        tprintln("  (no proof data: $(join(missing_fams, ", ")) — expected in larger cluster runs)")
    end
    tprintln()
    results
end

# ── Step 3 — Stratified g1adj rates per feature ───────────────────────────────
#
# For one stratum (df is already filtered): show g1adj usage rate per bucket.
# Returns a Dict{Symbol, NamedTuple} with (bucket_labels, rates, totals) for
# downstream discriminant-feature analysis.

function stratified_analysis(df, label="ALL")
    n     = nrow(df)
    rate  = round(Int, 100 * sum(df.g1adj_used) / n)
    tprintln()
    tprintln("── Stratified g1adj: $(rpad(label, 20)) (n=$(lpad(n,5)), overall=$(lpad(rate,2))%) ──")
    tprintln("   4 quantile buckets → rate(n). Monotone ↑↓ = useful split.")
    tprintln()

    results = Dict{Symbol, NamedTuple}()

    for feat in FEATURES_RAW
        feat ∉ propertynames(df) && continue
        col  = df[!, feat]
        vals = Float64[coalesce(v, NaN) for v in col]
        n_finite = sum(isfinite, vals)
        n_finite < 20 && continue

        yv = df.g1adj_used

        # Boolean features
        is_bool = all(v -> isnan(v) || v == 0.0 || v == 1.0, vals)
        if is_bool
            tprintln("$(rpad(string(feat), 24))  [boolean]")
            bucket_labels = String[]; rates = Float64[]; totals = Int[]
            for (tag, flag) in [("false", 0.0), ("true", 1.0)]
                mask = vals .== flag
                n_b  = sum(mask)
                np_b = sum(yv[mask])
                if n_b > 0
                    tprintf("  %-6s  %s\n", tag, rate_str(np_b, n_b))
                    push!(bucket_labels, tag)
                    push!(rates, np_b / n_b)
                    push!(totals, n_b)
                end
            end
            results[feat] = (bucket_labels=bucket_labels, rates=rates, totals=totals)
            tprintln()
            continue
        end

        finite_vals = sort(filter(isfinite, vals))
        mode_val    = finite_vals[length(finite_vals) ÷ 2]
        frac_mode   = count(==(mode_val), finite_vals) / length(finite_vals)

        # Spike-at-mode: binary split
        if frac_mode > 0.5
            eq_label = @sprintf("= %.4g", mode_val)
            ne_label = @sprintf("≠ %.4g", mode_val)
            tprintln("$(rpad(string(feat), 24))  [$eq_label]  |  [$ne_label]")
            eq_mask  = vals .== mode_val .&& isfinite.(vals)
            ne_mask  = vals .!= mode_val .&& isfinite.(vals)
            n_eq = sum(eq_mask); n_ne = sum(ne_mask)
            np_eq = sum(yv[eq_mask]); np_ne = sum(yv[ne_mask])
            tprintf("  %s  %s\n", rate_str(np_eq, n_eq), rate_str(np_ne, n_ne))
            results[feat] = (
                bucket_labels=[eq_label, ne_label],
                rates=[n_eq > 0 ? np_eq/n_eq : NaN, n_ne > 0 ? np_ne/n_ne : NaN],
                totals=[n_eq, n_ne])
            tprintln()
            continue
        end

        # Normal: 4-quantile buckets
        edges = unique(quantile(finite_vals, [0.0, 0.25, 0.50, 0.75, 1.0]))
        length(edges) < 2 && continue

        blabels = String[]; rates = Float64[]; totals = Int[]
        for i in 1:length(edges)-1
            lo = edges[i]; hi = edges[i+1]
            push!(blabels, i == 1 ? @sprintf("[%.3g,%.3g]", lo, hi) :
                                    @sprintf("(%.3g,%.3g]", lo, hi))
        end
        tprintln("$(rpad(string(feat), 24))  $(join(blabels, "  |  "))")

        tprintf("  ")
        for i in 1:length(edges)-1
            lo = edges[i]; hi = edges[i+1]
            mask = i == 1 ? (vals .>= lo .&& vals .<= hi .&& isfinite.(vals)) :
                            (vals .>  lo .&& vals .<= hi .&& isfinite.(vals))
            n_b  = sum(mask)
            np_b = sum(yv[mask])
            tprintf("  %s", rate_str(np_b, n_b))
            push!(rates, n_b > 0 ? np_b/n_b : NaN)
            push!(totals, n_b)
        end
        tprintln()

        results[feat] = (bucket_labels=blabels, rates=rates, totals=totals)
        tprintln()
    end

    results
end

# ── Discriminant features — cross-stratum breakdown ───────────────────────────
#
# For each feature whose rate range (max-min) across buckets exceeds `thresh`,
# show a compact cross-stratum table so the reader can judge generalisation.

function cross_stratum_analysis(all_strata_results, strata_labels, threshold=0.15)
    tprintln()
    tprintln("── Cross-stratum breakdown — discriminant features (range > $(round(Int, 100*threshold))pp) ──")
    tprintln("   Each block: one feature. Rows = strata. Cols = buckets.")
    tprintln("   Useful if the pattern is consistent across strata (not family-specific).")
    tprintln()

    # Identify discriminant features from the first stratum (ALL)
    all_res = all_strata_results[1]
    disc_feats = Symbol[]
    for feat in FEATURES_RAW
        haskey(all_res, feat) || continue
        r = all_res[feat].rates
        finite_r = filter(isfinite, r)
        length(finite_r) >= 2 || continue
        maximum(finite_r) - minimum(finite_r) >= threshold && push!(disc_feats, feat)
    end

    isempty(disc_feats) && (tprintln("  (none found at threshold $(round(Int, 100*threshold))pp)"); return)

    for feat in disc_feats
        # Use bucket labels from ALL stratum
        blabels = all_strata_results[1][feat].bucket_labels
        header  = join([@sprintf("%9s", l[1:min(9,end)]) for l in blabels], "  ")
        tprintln("$(rpad(string(feat), 24))  $header")

        for (i, res) in enumerate(all_strata_results)
            haskey(res, feat) || continue
            r = res[feat].rates
            t = res[feat].totals
            label = strata_labels[i]
            tprintf("  %-20s", label)
            for j in eachindex(r)
                j > length(blabels) && break
                if isfinite(r[j]) && t[j] >= 10
                    tprintf("  %3.0f%%(%3d)", 100*r[j], t[j])
                else
                    tprintf("  %9s", "—")
                end
            end
            tprintln()
        end
        tprintln()
    end
end

# ── Step 3b — Feature correlations (AUC + r) ─────────────────────────────────

function feature_correlations(df, label="ALL", target=:g1adj_used)
    y      = Float64.(df[!, target])
    y_bool = Bool.(df[!, target])
    n_total = length(y)
    rows = NamedTuple[]
    sparse_feats = String[]

    feat_cols = Dict{String, Vector{Float64}}()
    for feat in FEATURES_RAW
        feat ∉ propertynames(df) && continue
        vals = Float64[coalesce(v, NaN) for v in df[!, feat]]
        feat_cols[string(feat)] = vals
        if feat in LOG1P_FEATURES
            feat_cols["log1p_"*string(feat)] = log1p.(max.(vals, 0.0))
        end
    end

    for (fname, vals) in sort(collect(feat_cols), by=first)
        mask = isfinite.(vals)
        n_ok = sum(mask)
        n_ok < 10 && continue
        missing_pct = 100.0 * (n_total - n_ok) / n_total
        x   = vals[mask]
        yf  = y[mask]
        yb  = Vector{Bool}(y_bool[mask])
        r   = safe_cor(x, yf)
        isnan(r) && continue
        auc  = univariate_auc(x, yb)
        pval = pearson_pvalue(r, n_ok)
        μ_neg = mean(x[.!yb]); μ_pos = mean(x[yb])
        push!(rows, (feature=fname, r=r, abs_r=abs(r), auc=auc,
                     pval=pval, n=n_ok, missing_pct=missing_pct,
                     mu_neg=μ_neg, mu_pos=μ_pos))
        missing_pct > 20 && push!(sparse_feats, fname)
    end

    sort!(rows, by=x -> -x.auc)

    tprintln()
    tprintln("── Feature correlations with $target ($(label), n=$(nrow(df))) ────────────")
    tprintln("   Sorted by AUC. AUC: ~rnd<0.58 | weak 0.58–0.65 | mod 0.65–0.75 | good ≥0.75")
    tprintln("   Note: p-values are decorative at n=$(nrow(df)) — nearly all features are ***.")
    tprintln()
    tprintf("%-28s  %+6s  %5s  %4s  %3s  %5s  %12s  %6s\n",
        "feature", "r", "AUC", "qual", "sig", "miss%", "mean(0→1)", "n")
    tprintln(repeat("─", 80))
    for row in rows
        delta = @sprintf("%+.3g→%+.3g", row.mu_neg, row.mu_pos)
        tag   = startswith(row.feature, "log1p_") ? " ‡" : "  "
        tprintf("%-28s  %+6.3f  %.3f  %s  %s  %4.0f%%  %12s  %6d%s\n",
            row.feature, row.r, row.auc, auc_label(row.auc),
            sig_stars(row.pval), row.missing_pct, delta, row.n, tag)
    end
    tprintln("  (‡ = log1p-transformed; same CART split quality, better AUC linearity)")
    if !isempty(sparse_feats)
        tprintln()
        tprintln("  (>20% missing: $(join(sparse_feats, ", "))")
        tprintln("   computed only for graphs ≤500 nodes — subsample AUC may differ from global)")
    end
    rows
end

function per_family_correlations(df, top_features; target=:g1adj_used, target_name="g1adj")
    tprintln()
    tprintln("── Per-family correlations — $target_name (top features) ─────────────")
    tprintf("%-26s", "family (n, rate)")
    for feat in top_features
        tprintf("  %+10s", string(feat)[1:min(10, end)])
    end
    tprintln()
    tprintln(repeat("─", 26 + 12 * length(top_features)))

    for fam in FAMILIES
        sub = df[isequal.(df.family, fam), :]
        nrow(sub) < 5 && continue
        y = Float64.(sub[!, target])
        tgt_rate = mean(y)
        const_rate = (std(y) == 0)
        label = @sprintf("%s (n=%d, %d%%)", fam, nrow(sub), round(Int, 100tgt_rate))
        tprintf("%-26s", label[1:min(26, end)])
        for fname in top_features
            if const_rate
                tprintf("  %10s", tgt_rate == 1.0 ? "100%=const" : "0%=const")
                continue
            end
            raw = Symbol(replace(fname, "log1p_" => ""))
            raw ∉ propertynames(sub) && (tprintf("  %10s", "—"); continue)
            vals = Float64[coalesce(v, NaN) for v in sub[!, raw]]
            startswith(fname, "log1p_") && (vals = log1p.(max.(vals, 0.0)))
            mask = isfinite.(vals)
            sum(mask) < 5 && (tprintf("  %10s", "—"); continue)
            r = safe_cor(vals[mask], y[mask])
            isnan(r) ? tprintf("  %10s", "—") : tprintf("  %+10.3f", r)
        end
        tprintln()
    end
    tprintln("  (100%=const / 0%=const → within-family rate is constant; no discriminant)")
end

# ── HTML report ───────────────────────────────────────────────────────────────

# White → steel-blue gradient keyed on rate ∈ [0, 1].
function rate_bg(r::Float64)
    isnan(r) && return "background:#eee;color:#aaa"
    r = clamp(r, 0.0, 1.0)
    ri = round(Int, 255 - r * 210); gi = round(Int, 255 - r * 140); bi = round(Int, 255 - r * 60)
    tc = r > 0.52 ? "#fff" : "#222"
    "background:rgb($ri,$gi,$bi);color:$tc"
end

function html_cell(r::Float64, n::Int)
    (isnan(r) || n < 5) && return "<td class='na'>—</td>"
    "<td style='$(rate_bg(r))'>$(round(Int, 100r))%<br><small>($n)</small></td>"
end

# Classify a feature based on its bucket labels and rate range in the ALL stratum.
function feature_type(feat::Symbol, all_res::Dict)
    haskey(all_res, feat) || return "weak"
    bl = all_res[feat].bucket_labels
    # Spike: bucket labels start with "=" (no "[" prefix — produced by @sprintf("= %.4g",...))
    any(l -> startswith(l, "=") || startswith(l, "≠"), bl) && return "spike"
    any(l -> l in ("true", "false"), bl) && return "bool"
    r = filter(isfinite, all_res[feat].rates)
    length(r) < 2 && return "weak"
    rng = maximum(r) - minimum(r)
    rng >= 0.15 ? "monotone" : rng >= 0.08 ? "moderate" : "weak"
end

# Check if monotone direction (first→last bucket) is consistent across key strata.
const KEY_STRATA = ("no-search", "bio/no-search", "LV/no-search", "bio", "LV")

function consistency_tag(feat::Symbol, strata_labels, strata_results)
    dirs = Int[]
    for (i, label) in enumerate(strata_labels)
        label in KEY_STRATA || continue
        haskey(strata_results[i], feat) || continue
        r = filter(isfinite, strata_results[i][feat].rates)
        t = strata_results[i][feat].totals
        (length(r) < 2 || sum(t) < 30) && continue
        d = sign(r[end] - r[1])
        d != 0 && push!(dirs, d)
    end
    isempty(dirs) && return ""
    all(==(dirs[1]), dirs) && return "<span class='badge ok'>✓ consistent</span>"
    "<span class='badge warn'>⚠ mixed</span>"
end

function type_tag_html(ftype::String)
    ftype == "spike"    && return "<span class='tag spike'>spike-at-zero</span>"
    ftype == "monotone" && return "<span class='tag mono'>monotone</span>"
    ftype == "bool"     && return "<span class='tag bool'>boolean</span>"
    ftype == "moderate" && return "<span class='tag mod'>moderate</span>"
    "<span class='tag weak'>weak</span>"
end

const HTML_CSS = """<!DOCTYPE html>
<html><head><meta charset="utf-8">
<title>Supplemental Graph Classifier — Cone Label Analysis</title>
<style>
*{box-sizing:border-box}
body{font-family:system-ui,sans-serif;max-width:1100px;margin:1.5em auto;
     padding:0 1.5em;color:#222;font-size:14px;line-height:1.5}
h1{font-size:1.35em;margin-bottom:0.2em}
h2{font-size:1.1em;border-bottom:2px solid #999;padding-bottom:0.2em;margin-top:2.5em}
h3{font-size:0.95em;font-family:monospace;margin:1.5em 0 0.3em;color:#333}
p.meta{color:#555;margin:0 0 1.2em}
table{border-collapse:collapse;margin:0.5em 0 1.2em;font-size:0.82em}
th{background:#e8e8e8;padding:4px 10px;border:1px solid #bbb;text-align:center;
   white-space:nowrap;font-size:0.85em}
th.lbl{text-align:left}
td{padding:3px 9px;border:1px solid #ddd;text-align:center;white-space:nowrap;vertical-align:middle}
td.lbl{text-align:left;font-weight:600;background:#f7f7f7;font-family:monospace}
td.na{color:#bbb;background:#fafafa}
td small{display:block;font-size:0.78em;opacity:0.75}
tr.key > td.lbl{border-left:3px solid #e07000}
.box{border-left:4px solid #dda000;background:#fffcef;padding:0.6em 1.2em;
     margin:1em 0;border-radius:0 4px 4px 0}
.box.red{border-color:#b00;background:#fff4f4}
.box ul{margin:0.3em 0;padding-left:1.6em}
.box li{margin:0.25em 0}
.badge{font-size:0.75em;padding:1px 6px;border-radius:3px;margin-left:5px;
       font-weight:normal;vertical-align:middle}
.badge.ok{background:#d4edda;color:#155724}
.badge.warn{background:#fff3cd;color:#7a5800}
.badge.miss{background:#f8d7da;color:#721c24}
.tag{font-size:0.72em;padding:1px 5px;border-radius:3px;margin-left:4px;
     vertical-align:middle;font-weight:normal}
.tag.spike{background:#e5e5e5;color:#555}
.tag.mono{background:#c8e6c9;color:#1b5e20}
.tag.bool{background:#bbdefb;color:#0d47a1}
.tag.mod{background:#fff9c4;color:#5d4037}
.tag.weak{background:#fafafa;color:#aaa;border:1px solid #ddd}
.note{color:#888;font-size:0.82em;font-style:italic}
</style></head><body>
"""

function write_html(path, df, fam_stats_supp1, fam_stats_supp2, fam_stats_supp3,
                    strata_labels, strata_results, all_corr_rows)
    all_res = strata_results[1]   # first stratum must be ALL

    # Discriminant features: range > 15pp in ALL
    disc_feats = [feat for feat in FEATURES_RAW
                  if haskey(all_res, feat) &&
                     let r = filter(isfinite, all_res[feat].rates)
                         length(r) >= 2 && maximum(r) - minimum(r) >= 0.15
                     end]

    open(path, "w") do io
        n      = nrow(df)
        rate   = round(Int, 100 * sum(df.g1adj_used) / n)
        n_ns   = sum(df.solver_nodes .<= 1)
        n_ws   = sum(df.solver_nodes .> 1)
        bio_n  = sum(isequal.(df.family, "bio"))
        lv_n   = sum(isequal.(df.family, "LV"))

        write(io, HTML_CSS)

        # ── Title ──
        write(io, "<h1>Supplemental Graph Classifier — Cone Label Analysis</h1>\n")
        write(io, "<p class='meta'>$n instances &nbsp;|&nbsp; ")
        write(io, "overall g1adj rate: <strong>$rate%</strong> &nbsp;|&nbsp; ")
        write(io, "no-search: <strong>$n_ns</strong> ($(round(Int, 100n_ns/n))%) &nbsp;|&nbsp; ")
        write(io, "with-search: <strong>$n_ws</strong> ($(round(Int, 100n_ws/n))%) &nbsp;|&nbsp; ")
        write(io, "bio: <strong>$bio_n</strong> ($(round(Int, 100bio_n/n))%) &nbsp;|&nbsp; ")
        write(io, "LV: <strong>$lv_n</strong> ($(round(Int, 100lv_n/n))%)</p>\n")

        # ── Caveats ──
        write(io, """<div class="box red">
<strong>Statistical caveats — read before interpreting</strong>
<ul>
<li><strong>Two-population confound:</strong> with-search = 81% g1adj rate, no-search = 18%.
  The biggest predictor of g1adj usage is "did the solver search?", not graph structure.
  <strong>Look at the no-search rows</strong> for structural signal (highlighted in orange).</li>
<li><strong>Family imbalance:</strong> bio = $(round(Int, 100bio_n/n))% of data.
  ALL-stratum rates ≈ bio rates. A feature must also show signal in LV to be considered general.</li>
<li><strong>p-values (omitted):</strong> at n=$n every feature reaches p&lt;0.001 by arithmetic.
  Effect size — rate difference across buckets, AUC — is what matters, not stars.</li>
<li><strong>AUC unreliable for spike-at-zero features</strong>
  (marked <span class="tag spike">spike-at-zero</span>):
  AUC is rank-based and blind to a binary split on the modal value.
  pat_triangles has AUC=0.52 but a 27%→7% rate ratio — it IS a useful feature for a decision tree.
  Use the rate tables, not AUC, for spike features.</li>
<li><strong>Missing data (diameter, radius):</strong> computed only for graphs ≤500 nodes
  (57–86% missing). Their AUC is measured on a biased subsample — treat with caution.
  Features with high missingness are flagged <span class="badge miss">⚠ miss</span>.</li>
</ul></div>
""")

        # ── §1 — Per-family (ALL / no-search / with-search) for g1/g2/g3 ──
        write(io, "<h2>1. Per-family supplemental graph usage</h2>\n")
        write(io, "<p class='note'>Three views per target: ALL instances, no-search (solver_nodes ≤ 1 — confound removed), with-search only. Comparing rates across columns reveals how much of the signal is driven by solver search vs graph structure.</p>\n")

        function write_fam_table(io, label, stats, target)
            write(io, "<div>\n<p style='font-weight:bold;margin-bottom:4px'>$label</p>\n")
            write(io, "<table><tr>")
            for h in ["family", "n", "$(target) > 0", "rate", "med $(target)"]
                write(io, "<th$(h == "family" ? " class='lbl'" : "")>$h</th>")
            end
            write(io, "</tr>\n")
            for row in stats
                rp = round(Int, 100 * row.rate)
                write(io, "<tr><td class='lbl'>$(row.family)</td>")
                write(io, "<td>$(row.n)</td><td>$(row.n_pos)</td>")
                write(io, "<td style='$(rate_bg(row.rate))'>$rp%</td>")
                write(io, "<td>$(round(Int, row.med_target))</td></tr>\n")
            end
            write(io, "</table>\n</div>\n")
        end

        for (tname, trio) in [("supp1", fam_stats_supp1), ("supp2", fam_stats_supp2), ("supp3", fam_stats_supp3)]
            write(io, "<h3>$tname</h3>\n")
            write(io, "<div style='display:flex;gap:2em;flex-wrap:wrap;align-items:flex-start'>\n")
            for (label, stats) in trio
                write_fam_table(io, label, stats, tname)
            end
            write(io, "</div>\n")
        end

        # ── §2 — Cross-stratum discriminant features ──
        write(io, """<h2>2. Discriminant features — cross-stratum (rate range &gt; 15pp in ALL)</h2>
<p>Each table: rows = strata, cols = feature buckets. Cells coloured by g1adj rate
(white = 0%, dark blue = 100%). <strong>Orange-bordered rows</strong> = structural signal
(no-search strata — confound removed). Key question: does the pattern hold in
<em>bio/no-search</em> <em>and</em> <em>LV/no-search</em>?
<span class="badge ok">✓ consistent</span> = same monotone direction in all key strata.
<span class="badge warn">⚠ mixed</span> = sign flips between families.</p>
""")

        for feat in disc_feats
            blabels  = all_res[feat].bucket_labels
            ctag     = consistency_tag(feat, strata_labels, strata_results)
            ftype    = feature_type(feat, all_res)
            red_note = haskey(REDUNDANT_WITH, feat) ?
                " <span class='note'>(identical split to $(REDUNDANT_WITH[feat]))</span>" : ""

            write(io, "<h3>$feat$red_note &nbsp; $(type_tag_html(ftype)) $ctag</h3>\n")
            write(io, "<table><tr><th class='lbl'>stratum</th>")
            for bl in blabels
                write(io, "<th>$bl</th>")
            end
            write(io, "</tr>\n")

            for (i, slabel) in enumerate(strata_labels)
                res = strata_results[i]
                haskey(res, feat) || continue
                r = res[feat].rates; t = res[feat].totals
                any(n -> n >= 10, t) || continue
                is_key = slabel in ("no-search", "bio/no-search", "LV/no-search")
                write(io, "<tr$(is_key ? " class='key'" : "")>")
                write(io, "<td class='lbl'>$slabel</td>")
                for j in eachindex(blabels)
                    j > length(r) && break
                    write(io, html_cell(r[j], t[j]))
                end
                write(io, "</tr>\n")
            end
            write(io, "</table>\n")
        end

        subsets = ["ALL", "no-search", "with-search", "bio", "LV",
                   "images-CVIU11", "meshes-CVIU11"]
        subset_notes = ["ALL stratum", "no-search — confound removed",
                        "with-search only", "bio family", "LV family",
                        "images-CVIU11 family", "meshes-CVIU11 family"]
        for (sec_num, tname) in [("3","supp1"), ("4","supp2"), ("5","supp3")]
            rows_by_subset = all_corr_rows[tname]
            for (si, slabel) in enumerate(subsets)
                haskey(rows_by_subset, slabel) || continue
                subsec   = si == 1 ? sec_num : "$sec_num.$(si-1)"
                subtitle = "$(tname) — $(subset_notes[si])"
                write_corr_table(io, rows_by_subset[slabel], all_res, n, subsec, subtitle)
            end
        end

        write(io, "<p class='note' style='margin-top:3em'>")
        write(io, "classify_supplementals.jl — $(nrow(df)) instances, ")
        write(io, "$(length(disc_feats)) discriminant features</p>\n")
        write(io, "</body></html>")
    end
    println("HTML report → $path")
end

function write_corr_table(io, rows, all_res, _n_unused, section, subtitle)
    n_sub = isempty(rows) ? 0 :
            maximum(r.n for r in rows if !startswith(r.feature, "log1p_"); init=0)
    write(io, """<h2>$section. Feature quality — $subtitle</h2>
<p>Sorted by AUC (n=$n_sub).
<span class="tag mono">monotone</span> = clear gradient across quantile buckets.
<span class="tag spike">spike-at-zero</span> = AUC unreliable — use rate table instead.
<span class="badge miss">⚠ miss</span> = &gt;50% missing (biased subsample).</p>
<p class="note">p-values omitted: at n=$n_sub every feature reaches p&lt;0.001 by arithmetic.</p>
""")
    write(io, "<table><tr>")
    for h in ["feature", "type", "AUC", "|r|", "mean (=0)", "mean (=1)", "n", "miss%"]
        write(io, "<th$(h == "feature" ? " class='lbl'" : "")>$h</th>")
    end
    write(io, "</tr>\n")
    for row in rows
        startswith(row.feature, "log1p_") && continue
        feat_sym = Symbol(row.feature)
        ftype    = feature_type(feat_sym, all_res)
        red_note = haskey(REDUNDANT_WITH, feat_sym) ?
            " <span class='note'>≡ $(REDUNDANT_WITH[feat_sym])</span>" : ""
        miss_tag = row.missing_pct > 50 ?
            " <span class='badge miss'>$(round(Int, row.missing_pct))% miss</span>" :
            row.missing_pct > 20 ?
            " <span class='badge warn'>$(round(Int, row.missing_pct))% miss</span>" : ""
        auc_str  = ftype == "spike" ?
            "<span class='note'>$(round(row.auc, digits=3)) ⚠</span>" :
            "$(round(row.auc, digits=3))"
        write(io, "<tr>")
        write(io, "<td class='lbl'>$(row.feature)$miss_tag$red_note</td>")
        write(io, "<td>$(type_tag_html(ftype))</td>")
        write(io, "<td>$auc_str</td>")
        write(io, "<td>$(round(abs(row.r), digits=3))</td>")
        write(io, "<td>$(round(row.mu_neg, sigdigits=3))</td>")
        write(io, "<td>$(round(row.mu_pos, sigdigits=3))</td>")
        write(io, "<td style='color:#666'>$(row.n)</td>")
        write(io, "<td style='color:#999'>$(row.missing_pct > 2 ?
            string(round(Int, row.missing_pct))*"%" : "")</td>")
        write(io, "</tr>\n")
    end
    write(io, "</table>\n")
end

# ── Main ──────────────────────────────────────────────────────────────────────

function main()
    length(ARGS) < 2 && begin
        println("Usage: julia --project=scripts scripts/classify_supplementals.jl \\")
        println("           cluster_results.csv graph_features.csv [out.html]")
        exit(1)
    end
    # Derive both output paths from optional arg or default base name.
    base    = length(ARGS) >= 3 ? replace(ARGS[3], r"\.(html|txt)$" => "") :
                                  "classify_supplementals"
    html_path = base * ".html"
    txt_path  = base * ".txt"

    df = load_and_join(ARGS[1], ARGS[2])

    no_srch_mask = df.solver_nodes .<= 1
    wi_srch_mask = df.solver_nodes .>  1
    function trio(target, used_col, count_col)
        [("ALL",         per_family_stats(df,                    "ALL";         target, used_col, count_col)),
         ("no-search",   per_family_stats(df[no_srch_mask, :],  "no-search";   target, used_col, count_col)),
         ("with-search", per_family_stats(df[wi_srch_mask, :],  "with-search"; target, used_col, count_col))]
    end
    fam_stats_supp1 = trio("supp1", :supp1_used, :supp1_count)
    fam_stats_supp2 = trio("supp2", :supp2_used, :supp2_count)
    fam_stats_supp3 = trio("supp3", :supp3_used, :supp3_count)

    # Define strata — primary split is search/no-search (main confound), then family
    no_srch = no_srch_mask
    wi_srch = wi_srch_mask

    strata = Tuple{String, DataFrame}[
        ("ALL",              df),
        ("no-search",        df[no_srch, :]),
        ("with-search",      df[wi_srch, :]),
    ]
    # Add per-family strata for families with enough data
    for fam in FAMILIES
        fam_mask = isequal.(df.family, fam)
        sum(fam_mask) >= 50 && push!(strata, (fam, df[fam_mask, :]))
    end
    # Add family × search-mode cross strata
    for fam in FAMILIES
        fam_mask = isequal.(df.family, fam)
        ns_mask  = fam_mask .& no_srch
        ws_mask  = fam_mask .& wi_srch
        sum(ns_mask) >= 50 && push!(strata, ("$(fam)/no-search", df[ns_mask, :]))
        sum(ws_mask) >= 50 && push!(strata, ("$(fam)/with-search", df[ws_mask, :]))
    end

    strata_labels  = [s[1] for s in strata]
    strata_results = [stratified_analysis(s[2], s[1]) for s in strata]

    # Cross-stratum breakdown for discriminant features
    cross_stratum_analysis(strata_results, strata_labels)

    # Correlations — all targets × all subsets
    subsets = [
        ("ALL",            df),
        ("no-search",      df[df.solver_nodes .<= 1, :]),
        ("with-search",    df[df.solver_nodes .>  1, :]),
        ("bio",            df[isequal.(df.family, "bio"), :]),
        ("LV",             df[isequal.(df.family, "LV"),  :]),
        ("images-CVIU11",  df[isequal.(df.family, "images-CVIU11"), :]),
        ("meshes-CVIU11",  df[isequal.(df.family, "meshes-CVIU11"), :]),
    ]
    targets = [(:supp1_used, "supp1"), (:supp2_used, "supp2"), (:supp3_used, "supp3")]
    all_corr_rows = Dict(
        tname => Dict(slabel => feature_correlations(sdf, slabel, tcol)
                      for (slabel, sdf) in subsets)
        for (tcol, tname) in targets
    )
    for (tcol, tname) in targets
        rows = all_corr_rows[tname]["ALL"]
        top5 = [r.feature for r in rows[1:min(5, end)]]
        per_family_correlations(df, top5; target=tcol, target_name=tname)
    end

    tprintln()
    tprintln("── suppN usage (gNadj + intermediates) ───────────────────────────")
    for (label, col) in [("supp1 (g1adj+pathg1+d2g1+d3g1)", :supp1_used),
                          ("supp2 (g2adj+pathg2+d2g2+d3g2)", :supp2_used),
                          ("supp3 (g3adj+d2g3+d3g3+pathg3)", :supp3_used)]
        n_pos = sum(df[!, col])
        tprintf("  %-40s  %5d / %5d  (%.0f%%)\n",
            label, n_pos, nrow(df), 100n_pos/nrow(df))
    end
    tprintln()
    tprintln("── gNadj-only vs suppN comparison ──────────────────────────────")
    for (g, adj_col, supp_col) in [(1, :g1adj_used, :supp1_used),
                                     (2, :g2adj_used, :supp2_used),
                                     (3, :g3adj_used, :supp3_used)]
        n_adj  = sum(df[!, adj_col])
        n_supp = sum(df[!, supp_col])
        delta  = n_supp - n_adj
        tprintf("  g%dadj=%5d  supp%d=%5d  Δ=%+d (instances with intermediates but no gNadj)\n",
            g, n_adj, g, n_supp, delta)
    end

    tprintln()
    tprintf("Done. %d instances analysed.\n", nrow(df))

    write(txt_path, String(take!(copy(_LOG))))
    println("Text report  → $txt_path")

    write_html(html_path, df, fam_stats_supp1, fam_stats_supp2, fam_stats_supp3,
               strata_labels, strata_results, all_corr_rows)
end

main()
