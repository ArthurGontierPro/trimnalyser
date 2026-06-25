#!/usr/bin/env julia
#
# Aggregate per-instance .out/.err files into a single CSV.
#
# Input:  a proof directory containing <instance>.out files written by TrimAnalyser
#         (and optionally <instance>.err, .coreN.out for resolv iterations, .smol.opb/.smol.pbp).
#
# Output: one CSV row per .out file, with ~147 columns covering input stats, cone stats
#         (grim/gclt/gbfs), verification, solver stats, resolv iterations, label provenance,
#         and derived fractions.
#
# .out line format conventions:
#   - TrimAnalyser lines:  "<prefix> <TAG> <value>"       e.g. "grim TRIM TIME 5.3"
#   - Fraction lines:      "<prefix> <TAG> cone/total"    e.g. "grim OPB 1516/7810"
#   - Label lines:         "<prefix> LABEL <TAG> cone/total"
#   - Glasgow solver lines (piped to .out): "key = value" e.g. "status = false"
#
# .coreN.out files are resolv iteration outputs — each is also a valid .out file and appears
# as its own row (e.g. instance "LVg10g12.core1"). The base instance additionally aggregates
# per-iteration metrics into JSON array columns.
#
# Usage: julia aggregate_results.jl <proofs_directory> [output.csv]

# Map instance name prefix to benchmark family (newSIP naming conventions).
function instance_family(instance)
    startswith(instance, "LV")     && return "LV"
    startswith(instance, "bio")    && return "bio"
    startswith(instance, "cviu11") && return "images-CVIU11"
    startswith(instance, "pr15")   && return "images-PR15"
    startswith(instance, "mesh11") && return "meshes-CVIU11"
    startswith(instance, "ph_")    && return "phase"
    startswith(instance, "sf_")    && return "scalefree"
    startswith(instance, "si__")   && return "si"
    return "unknown"
end

# Column names for the CSV
const CSV_COLUMNS = [
    "instance", "family",
    # Input stats
    "inp_opb_size", "inp_pbp_size", "inp_total_size",
    "inp_literals", "inp_variables",
    "inp_opb_nbeq", "inp_pbp_nbeq", "inp_total_nbeq",
    # Grim (DFS) results
    "grim_parse_time", "grim_trim_time", "grim_write_time", "grim_total_time",
    "grim_opb_cone", "grim_pbp_cone", "grim_total_cone",
    "grim_cone_literals", "grim_smol_literals", "grim_cone_variables",
    "grim_opb_size", "grim_pbp_size", "grim_total_size",
    # Gclt (clit) results
    "gclt_trim_time",
    "gclt_opb_cone", "gclt_pbp_cone", "gclt_total_cone",
    "gclt_cone_literals", "gclt_smol_literals", "gclt_cone_variables",
    # Gbfs (BFS) results
    "gbfs_trim_time",
    "gbfs_opb_cone", "gbfs_pbp_cone", "gbfs_total_cone",
    "gbfs_cone_literals", "gbfs_smol_literals", "gbfs_cone_variables",
    # Verification
    "veri_smol_time", "veri_total_time",
    "veri_smol_verified",
    "veri_opb_size", "veri_pbp_size", "veri_total_size",
    # Solver stats (if available)
    "pattern_vertices", "target_vertices", "runtime_ms", "status", "solver_nodes", "solver_propagations",
    # UNSAT core statistics (if core files exist)
    "core_pattern_nodes", "core_target_nodes", "core_pattern_total", "core_target_total",
    # Instance classification
    "is_sat", "is_unsat", "has_proof",
    "skip_reason", "proof_truncated", "truncation_reason",
    # Error tracking
    "has_error", "error_type", "error_details",
    # Resolv iterations
    "resolv_iterations",
    # Per-iteration size changes (JSON arrays for flexibility)
    "iter_sizes_total", "iter_sizes_opb", "iter_sizes_pbp",
    # Per-iteration constraint/variable/literal tracking
    "iter_nbeq", "iter_var", "iter_lit",
    # M2: step-type breakdown in trimmed cone (grim)
    "grim_cone_rup", "grim_cone_pol", "grim_cone_red", "grim_cone_ia",
    # M3.5.7: full-proof step types
    "grim_full_rup", "grim_full_pol", "grim_full_red", "grim_full_ia",
    # M2: cone depth stats
    "grim_cone_depth_max", "grim_cone_depth_mean",
    # M3.5.7: full-proof depth stats
    "grim_full_depth_max", "grim_full_depth_mean",
    # M2: cone depth distribution
    "grim_cone_depth_p50", "grim_cone_depth_p90", "grim_cone_depth_entropy",
    "grim_cone_bottom_frac", "grim_cone_bottleneck_depth",
    "grim_cone_width_max", "grim_cone_width_cv",
    "grim_cone_rup_depth_cv",
    "grim_cone_pol_depth_mean", "grim_cone_pol_depth_cv",
    "grim_cone_pol_depth_frac_bot", "grim_cone_pol_depth_frac_top",
    "grim_cone_pol_ante_mean", "grim_cone_pol_ante_max", "grim_cone_pol_opb_frac",
    "grim_cone_pol_before_rup_burst",
    # M3.5.7: full-proof depth distribution
    "grim_full_depth_p50", "grim_full_depth_p90", "grim_full_depth_entropy",
    "grim_full_bottom_frac",
    "grim_full_width_max", "grim_full_width_cv",
    "grim_full_rup_depth_cv",
    "grim_full_pol_depth_mean", "grim_full_pol_depth_cv",
    "grim_full_pol_ante_mean", "grim_full_pol_ante_max", "grim_full_pol_opb_frac",
    "grim_full_pol_before_rup_burst",
    # M2: step-type fractions (derived: count / total_cone)
    "grim_rup_frac", "grim_pol_frac", "grim_ia_frac", "grim_red_frac",
    # M3.5.7: full step-type fractions (derived: count / total_nbeq)
    "grim_full_rup_frac", "grim_full_pol_frac", "grim_full_ia_frac", "grim_full_red_frac",
    # M2: literal compression
    "grim_literal_weakening_rate",
    # M2: resolv shrinkage curve and stop reason
    "resolv_iter_pat_nodes", "resolv_iter_tar_nodes", "resolv_stop_reason",
    # M2: resolv total shrinkage (derived)
    "resolv_pat_shrinkage", "resolv_tar_shrinkage",
    # M3.5: CP constraint provenance — cone counts
    "grim_cone_al1", "grim_cone_am1", "grim_cone_inj",
    "grim_cone_g0adj", "grim_cone_g1adj", "grim_cone_g2adj", "grim_cone_g3adj", "grim_cone_gadj_other",
    "grim_cone_forb", "grim_cone_noedge",
    "grim_cone_elimdegpol", "grim_cone_elimdeg",
    "grim_cone_elimndspol", "grim_cone_elimndsconc", "grim_cone_elimnds",
    "grim_cone_loop",
    "grim_cone_ptbig", "grim_cone_hall",
    "grim_cone_prop", "grim_cone_guess", "grim_cone_nogood",
    "grim_cone_pathg1", "grim_cone_pathg2", "grim_cone_pathg3", "grim_cone_pathg_other",
    "grim_cone_d2g1", "grim_cone_d2g2", "grim_cone_d2g3", "grim_cone_d2g_other",
    "grim_cone_d3g1", "grim_cone_d3g2", "grim_cone_d3g3", "grim_cone_d3g_other",
    "grim_cone_reelimdegpol", "grim_cone_reelimdeg",
    "grim_cone_reelimndspol", "grim_cone_reelimndsconc",
    "grim_cone_unsatconc",
    "grim_cone_binback", "grim_cone_colpol",
    "grim_cone_hombd", "grim_cone_hompol", "grim_cone_hominj",
    "grim_cone_homdom", "grim_cone_homfin", "grim_cone_homcross",
    "grim_cone_mcspart", "grim_cone_mcsfin",
    "grim_cone_notconn", "grim_cone_cliqedge",
    "grim_cone_unlabeled",
    # M3.5.7: full-proof label counts
    "grim_full_al1", "grim_full_am1", "grim_full_inj",
    "grim_full_g0adj", "grim_full_g1adj", "grim_full_g2adj", "grim_full_g3adj", "grim_full_gadj_other",
    "grim_full_forb", "grim_full_noedge",
    "grim_full_elimdegpol", "grim_full_elimdeg",
    "grim_full_elimndspol", "grim_full_elimndsconc", "grim_full_elimnds",
    "grim_full_loop",
    "grim_full_ptbig", "grim_full_hall",
    "grim_full_prop", "grim_full_guess", "grim_full_nogood",
    "grim_full_pathg1", "grim_full_pathg2", "grim_full_pathg3", "grim_full_pathg_other",
    "grim_full_d2g1", "grim_full_d2g2", "grim_full_d2g3", "grim_full_d2g_other",
    "grim_full_d3g1", "grim_full_d3g2", "grim_full_d3g3", "grim_full_d3g_other",
    "grim_full_reelimdegpol", "grim_full_reelimdeg",
    "grim_full_reelimndspol", "grim_full_reelimndsconc",
    "grim_full_unsatconc",
    "grim_full_binback", "grim_full_colpol",
    "grim_full_hombd", "grim_full_hompol", "grim_full_hominj",
    "grim_full_homdom", "grim_full_homfin", "grim_full_homcross",
    "grim_full_mcspart", "grim_full_mcsfin",
    "grim_full_notconn", "grim_full_cliqedge",
    "grim_full_unlabeled",
    # M3.5: CP constraint provenance (fractions of total cone)
    "grim_cone_frac_inj", "grim_cone_frac_g0adj",
    "grim_cone_frac_g1adj", "grim_cone_frac_g2adj", "grim_cone_frac_g3adj",
    "grim_cone_frac_forb", "grim_cone_frac_noedge",
    "grim_cone_frac_elimdegpol", "grim_cone_frac_elimnds", "grim_cone_frac_elimdeg",
    "grim_cone_frac_hall",
    "grim_cone_frac_prop", "grim_cone_frac_guess", "grim_cone_frac_nogood",
    "grim_cone_frac_pathg1", "grim_cone_frac_pathg2", "grim_cone_frac_pathg3", "grim_cone_frac_pathg_other",
    "grim_cone_frac_d2g1", "grim_cone_frac_d2g2", "grim_cone_frac_d2g3", "grim_cone_frac_d2g_other",
    "grim_cone_frac_d3g1", "grim_cone_frac_d3g2", "grim_cone_frac_d3g3", "grim_cone_frac_d3g_other",
    # M3.5: variable order — cone and full
    "grim_cone_uniq_pat", "grim_cone_uniq_tar",
    "grim_full_uniq_pat", "grim_full_uniq_tar"
]

function _parse_frac(s)
    p = findfirst('/', s)
    p === nothing && return (tryparse(Int, s), nothing)
    (tryparse(Int, s[1:p-1]), tryparse(Int, s[p+1:end]))
end

# CP constraint provenance label tags (shared by parser, cone row builder, full row builder).
const _LABEL_TAGS = [
    "al1", "am1", "inj", "g0adj", "g1adj", "g2adj", "g3adj", "gadj_other",
    "forb", "noedge", "elimdegpol", "elimdeg", "elimndspol", "elimndsconc", "elimnds",
    "loop", "ptbig", "hall", "prop", "guess", "nogood",
    "pathg1", "pathg2", "pathg3", "pathg_other",
    "d2g1", "d2g2", "d2g3", "d2g_other",
    "d3g1", "d3g2", "d3g3", "d3g_other",
    "reelimdegpol", "reelimdeg", "reelimndspol", "reelimndsconc",
    "unsatconc", "binback", "colpol",
    "hombd", "hompol", "hominj", "homdom", "homfin", "homcross",
    "mcspart", "mcsfin", "notconn", "cliqedge"
]

const _LABEL_REGEXES = Dict(
    tag => Regex("^grim LABEL $(uppercase(tag)) (\\d+/\\d+)\$")
    for tag in _LABEL_TAGS
)

# ── Table-driven .out parser ─────────────────────────────────────────────────
# Each table is a Vector of tuples, precompiled once.  parse_out_file iterates
# all three tables per line, then falls through to the handful of special cases.

# Suffix rules: line contains `substr` → data[key] = tryparse(T, last_token)
const _SUFFIX_RULES = [
    # Input stats
    ("inp OPB SIZE ",     "inp_opb_size",    Int),
    ("inp PBP SIZE ",     "inp_pbp_size",    Int),
    ("inp SIZE ",         "inp_total_size",  Int),
    ("inp LIT ",          "inp_literals",    Int),
    ("inp VAR ",          "inp_variables",   Int),
    # Grim timing & output sizes
    ("grim PARSE TIME ",  "grim_parse_time", Float64),
    ("grim TRIM TIME ",   "grim_trim_time",  Float64),
    ("grim WRITE TIME ",  "grim_write_time", Float64),
    ("grim TIME ",        "grim_total_time", Float64),
    ("grim OPB SIZE ",    "grim_opb_size",   Int),
    ("grim PBP SIZE ",    "grim_pbp_size",   Int),
    ("grim SIZE ",        "grim_total_size", Int),
    # Alt trim modes
    ("gclt TRIM TIME ",   "gclt_trim_time",  Float64),
    ("gbfs TRIM TIME ",   "gbfs_trim_time",  Float64),
    # Verification
    ("veri smol TIME ",   "veri_smol_time",  Float64),
    ("veri TIME ",        "veri_total_time", Float64),
]

# Regex rules: match(rx, line) → data[key] = tryparse(T, capture[1])
const _REGEX_RULES = [
    # Depth — cone
    (r"^grim CONE DEPTH MAX (\d+)",               "grim_cone_depth_max",           Int),
    (r"^grim CONE DEPTH MEAN ([\d.]+)",            "grim_cone_depth_mean",          Float64),
    (r"^grim CONE DEPTH P50 (\d+)",                "grim_cone_depth_p50",           Int),
    (r"^grim CONE DEPTH P90 (\d+)",                "grim_cone_depth_p90",           Int),
    (r"^grim CONE DEPTH ENTROPY ([\d.]+)",         "grim_cone_depth_entropy",       Float64),
    (r"^grim CONE BOTTOM FRAC ([\d.]+)",           "grim_cone_bottom_frac",         Float64),
    (r"^grim CONE BOTTLENECK DEPTH (-?\d+)",       "grim_cone_bottleneck_depth",    Int),
    (r"^grim CONE WIDTH MAX (\d+)",                "grim_cone_width_max",           Int),
    (r"^grim CONE WIDTH CV ([\d.]+)",              "grim_cone_width_cv",            Float64),
    (r"^grim CONE RUP DEPTH CV ([\d.]+)",          "grim_cone_rup_depth_cv",        Float64),
    (r"^grim CONE POL DEPTH MEAN ([\d.]+)",        "grim_cone_pol_depth_mean",      Float64),
    (r"^grim CONE POL DEPTH CV ([\d.]+)",          "grim_cone_pol_depth_cv",        Float64),
    (r"^grim CONE POL DEPTH FRAC BOT ([\d.]+)",   "grim_cone_pol_depth_frac_bot",  Float64),
    (r"^grim CONE POL DEPTH FRAC TOP ([\d.]+)",   "grim_cone_pol_depth_frac_top",  Float64),
    (r"^grim CONE POL ANTE MEAN ([\d.]+)",         "grim_cone_pol_ante_mean",       Float64),
    (r"^grim CONE POL ANTE MAX (\d+)",             "grim_cone_pol_ante_max",        Int),
    (r"^grim CONE POL OPB FRAC ([\d.]+)",          "grim_cone_pol_opb_frac",        Float64),
    (r"^grim CONE POL BURST ([01])",               "grim_cone_pol_before_rup_burst",Int),
    # Depth — full
    (r"^grim FULL DEPTH MAX (\d+)",                "grim_full_depth_max",           Int),
    (r"^grim FULL DEPTH MEAN ([\d.]+)",            "grim_full_depth_mean",          Float64),
    (r"^grim FULL DEPTH P50 (\d+)",                "grim_full_depth_p50",           Int),
    (r"^grim FULL DEPTH P90 (\d+)",                "grim_full_depth_p90",           Int),
    (r"^grim FULL DEPTH ENTROPY ([\d.]+)",         "grim_full_depth_entropy",       Float64),
    (r"^grim FULL BOTTOM FRAC ([\d.]+)",           "grim_full_bottom_frac",         Float64),
    (r"^grim FULL WIDTH MAX (\d+)",                "grim_full_width_max",           Int),
    (r"^grim FULL WIDTH CV ([\d.]+)",              "grim_full_width_cv",            Float64),
    (r"^grim FULL RUP DEPTH CV ([\d.]+)",          "grim_full_rup_depth_cv",        Float64),
    (r"^grim FULL POL DEPTH MEAN ([\d.]+)",        "grim_full_pol_depth_mean",      Float64),
    (r"^grim FULL POL DEPTH CV ([\d.]+)",          "grim_full_pol_depth_cv",        Float64),
    (r"^grim FULL POL ANTE MEAN ([\d.]+)",         "grim_full_pol_ante_mean",       Float64),
    (r"^grim FULL POL ANTE MAX (\d+)",             "grim_full_pol_ante_max",        Int),
    (r"^grim FULL POL OPB FRAC ([\d.]+)",          "grim_full_pol_opb_frac",        Float64),
    (r"^grim FULL POL BURST ([01])",               "grim_full_pol_before_rup_burst",Int),
    # SMOL LIT (single value, not a fraction)
    (r"^grim SMOL LIT (\d+)",                      "grim_smol_literals",            Int),
    (r"^gclt SMOL LIT (\d+)",                      "gclt_smol_literals",            Int),
    (r"^gbfs SMOL LIT (\d+)",                      "gbfs_smol_literals",            Int),
    # Solver stats (written by Glasgow solver, piped to .out by runsipsolver)
    (r"^pattern_vertices\s*=\s*(\d+)",             "pattern_vertices",              Int),
    (r"^target_vertices\s*=\s*(\d+)",              "target_vertices",               Int),
    (r"^runtime\s*=\s*(\d+)",                      "runtime_ms",                    Int),
    (r"^nodes\s*=\s*(\d+)",                        "solver_nodes",                  Int),
    (r"^propagations\s*=\s*(\d+)",                 "solver_propagations",           Int),
]

# Fraction rules: match(rx, line) → _parse_frac → data[key_a] = numerator
# If key_b is not nothing, data[key_b] = denominator.
const _FRAC_RULES = [
    # Grim cone/inp fractions
    (r"^grim OPB (\d+/\d+)$",   "grim_opb_cone",       "inp_opb_nbeq"),
    (r"^grim PBP (\d+/\d+)$",   "grim_pbp_cone",       "inp_pbp_nbeq"),
    (r"^grim NBEQ (\d+/\d+)$",  "grim_total_cone",     "inp_total_nbeq"),
    # Grim step type cone/full fractions
    (r"^grim RUP (\d+/\d+)$",   "grim_cone_rup",       "grim_full_rup"),
    (r"^grim POL (\d+/\d+)$",   "grim_cone_pol",       "grim_full_pol"),
    (r"^grim RED (\d+/\d+)$",   "grim_cone_red",       "grim_full_red"),
    (r"^grim IA (\d+/\d+)$",    "grim_cone_ia",        "grim_full_ia"),
    # Grim literal/variable cone fractions (denominator discarded)
    (r"^grim LIT (\d+/\d+)$",   "grim_cone_literals",  nothing),
    (r"^grim VAR (\d+/\d+)$",   "grim_cone_variables", nothing),
    # Grim unlabeled + variable order (cone/full)
    (r"^grim UNLABELED (\d+/\d+)$", "grim_cone_unlabeled", "grim_full_unlabeled"),
    (r"^grim UNIQ PAT (\d+/\d+)$",  "grim_cone_uniq_pat",  "grim_full_uniq_pat"),
    (r"^grim UNIQ TAR (\d+/\d+)$",  "grim_cone_uniq_tar",  "grim_full_uniq_tar"),
    # Gclt fractions (cone only)
    (r"^gclt OPB (\d+/\d+)$",   "gclt_opb_cone",       nothing),
    (r"^gclt PBP (\d+/\d+)$",   "gclt_pbp_cone",       nothing),
    (r"^gclt NBEQ (\d+/\d+)$",  "gclt_total_cone",     nothing),
    (r"^gclt LIT (\d+/\d+)$",   "gclt_cone_literals",  nothing),
    (r"^gclt VAR (\d+/\d+)$",   "gclt_cone_variables", nothing),
    # Gbfs fractions (cone only)
    (r"^gbfs OPB (\d+/\d+)$",   "gbfs_opb_cone",       nothing),
    (r"^gbfs PBP (\d+/\d+)$",   "gbfs_pbp_cone",       nothing),
    (r"^gbfs NBEQ (\d+/\d+)$",  "gbfs_total_cone",     nothing),
    (r"^gbfs LIT (\d+/\d+)$",   "gbfs_cone_literals",  nothing),
    (r"^gbfs VAR (\d+/\d+)$",   "gbfs_cone_variables", nothing),
]

function parse_out_file(filepath)
    data = Dict{String, Any}()
    isfile(filepath) || return data

    for line in eachline(filepath)
        for (substr, key, T) in _SUFFIX_RULES
            occursin(substr, line) && (data[key] = tryparse(T, split(line)[end]))
        end
        for (rx, key, T) in _REGEX_RULES
            let m = match(rx, line); m !== nothing && (data[key] = tryparse(T, m.captures[1])); end
        end
        for (rx, key_a, key_b) in _FRAC_RULES
            let m = match(rx, line)
                if m !== nothing
                    a, b = _parse_frac(m.captures[1])
                    data[key_a] = a
                    key_b !== nothing && (data[key_b] = b)
                end
            end
        end
        # Label fractions: "grim LABEL TAG cone/full"
        for tag in _LABEL_TAGS
            let m = match(_LABEL_REGEXES[tag], line)
                if m !== nothing
                    a, b = _parse_frac(m.captures[1])
                    data["grim_cone_$tag"] = a
                    data["grim_full_$tag"] = b
                end
            end
        end
        # Special cases that don't fit a table pattern
        line == "veri smol VERIFIED"     && (data["veri_smol_verified"] = 1)
        line == "veri smol NOT VERIFIED" && (data["veri_smol_verified"] = 0)
        let m = match(r"^status\s*=\s*(\w+)", line); m !== nothing && (data["status"] = m.captures[1]); end
        let m = match(r"^resolv ITER \d+ PAT (\d+) TAR (\d+)$", line)
            if m !== nothing
                push!(get!(data, "resolv_iter_pat") do; Int[] end, parse(Int, m.captures[1]))
                push!(get!(data, "resolv_iter_tar") do; Int[] end, parse(Int, m.captures[2]))
            end
        end
        let m = match(r"^resolv STOP (\w+)", line)
            m !== nothing && (data["resolv_stop_reason"] = m.captures[1])
        end
    end

    return data
end

# Classify error from .err file. Returns (has_error, type, details).
# Types: "OOM", "Timeout", "Int32Overflow", "BoundsError", "Unknown".
function parse_err_file(filepath)
    isfile(filepath) || return (false, "", "")

    content = read(filepath, String)
    isempty(strip(content)) && return (false, "", "")

    m = match(r"OOM at ([\d.]+G)", content)
    m !== nothing && return (true, "OOM", m.captures[1])
    m = match(r"OOM killed \(exceeded ([\d.]+ GB)\)", content)
    m !== nothing && return (true, "OOM", m.captures[1])

    if occursin("Timeout", content)
        m = match(r"Timeout after (\d+s)", content)
        details = m !== nothing ? m.captures[1] : "unknown"
        return (true, "Timeout", details)
    end

    if occursin("trunc(Int32", content)
        m = match(r"trunc\(Int32, (\d+)\)", content)
        details = m !== nothing ? "value=$(m.captures[1])" : "unknown"
        return (true, "Int32Overflow", details)
    end

    if occursin("BoundsError", content)
        return (true, "BoundsError", "")
    end

    return (true, "Unknown", strip(content)[1:min(100, end)])
end

function count_resolv_iterations(proofdir, instance)
    n = 0
    while isfile(joinpath(proofdir, instance * ".core$(n+1)" * ".out"))
        n += 1
    end
    return n
end

# Extract a list of keys from each .coreN.out file for the given instance.
function get_iteration_fields(proofdir, instance, n_iterations, keys)
    result = [[] for _ in keys]
    for i in 1:n_iterations
        out_file = joinpath(proofdir, instance * ".core$i" * ".out")
        if isfile(out_file)
            data = parse_out_file(out_file)
            for (j, k) in enumerate(keys); push!(result[j], get(data, k, nothing)); end
        else
            for j in eachindex(keys); push!(result[j], nothing); end
        end
    end
    return Tuple(result)
end

function parse_lad_node_count(filepath)
    isfile(filepath) || return nothing
    try; return parse(Int, readline(filepath)); catch; return nothing; end
end

function get_core_stats(proofdir, instance)
    vis_dir = joinpath(proofdir, "vis")
    isdir(vis_dir) || return (nothing, nothing, nothing, nothing)
    core_pat_nodes = parse_lad_node_count(joinpath(vis_dir, instance * ".core.pat.lad"))
    core_tar_nodes = parse_lad_node_count(joinpath(vis_dir, instance * ".core.tar.lad"))
    pat_total = parse_lad_node_count(joinpath(vis_dir, instance * ".pat.lad"))
    tar_total = parse_lad_node_count(joinpath(vis_dir, instance * ".tar.lad"))
    return (core_pat_nodes, core_tar_nodes, pat_total, tar_total)
end

# Why this instance has no trimmed proof. "SAT" = solver found a mapping (no proof to trim),
# "truncated_*" = solver wrote a partial proof, "no_proof_generated" = UNSAT but no .pbp.
function detect_skip_reason(err_filepath, has_proof, status_val)
    if status_val == "true"; return "SAT"; end
    if isfile(err_filepath)
        content = read(err_filepath, String)
        occursin("proof truncated: no conclusion", content) && return "truncated_no_conclusion"
        occursin("proof truncated: output line missing", content) && return "truncated_no_output"
        occursin("proof truncated", content) && return "truncated"
    end
    if status_val == "false" && !has_proof; return "no_proof_generated"; end
    return ""
end

function get_verification_sizes(proofdir, instance)
    opb_smol = joinpath(proofdir, instance * ".smol.opb")
    pbp_smol = joinpath(proofdir, instance * ".smol.pbp")
    if isfile(opb_smol) && isfile(pbp_smol)
        veri_opb = filesize(opb_smol); veri_pbp = filesize(pbp_smol)
        return (veri_opb, veri_pbp, veri_opb + veri_pbp)
    end
    return (nothing, nothing, nothing)
end

csv_quote(s) = "\"" * replace(string(s), "\"" => "\"\"") * "\""

function format_array(arr)
    isempty(arr) && return ""
    vals = [v !== nothing ? string(v) : "null" for v in arr]
    return csv_quote("[" * join(vals, ",") * "]")
end

function aggregate_results(proofdir::String, output_csv::String)
    println("Scanning directory: $proofdir")

    all_files = readdir(proofdir)
    out_files = filter(f -> endswith(f, ".out") &&
                           !endswith(f, ".smolverif.out") &&
                           !endswith(f, ".verif.out"), all_files)

    instances = [splitext(f)[1] for f in out_files]
    println("Found $(length(instances)) instances")

    open(output_csv, "w") do io
        println(io, join(CSV_COLUMNS, ","))

        for (i, instance) in enumerate(instances)
            i % 100 == 0 && println("Processing $i/$(length(instances))...")

            out_file = joinpath(proofdir, instance * ".out")
            data = parse_out_file(out_file)

            err_file = joinpath(proofdir, instance * ".err")
            has_error, error_type, error_details = parse_err_file(err_file)

            resolv_iters = count_resolv_iterations(proofdir, instance)
            iter_sizes_total, iter_sizes_opb, iter_sizes_pbp = get_iteration_fields(
                proofdir, instance, resolv_iters, ["grim_total_size", "grim_opb_size", "grim_pbp_size"])
            iter_nbeq, iter_var, iter_lit = get_iteration_fields(
                proofdir, instance, resolv_iters, ["inp_total_nbeq", "inp_variables", "inp_literals"])

            row = []
            push!(row, csv_quote(instance))
            push!(row, csv_quote(instance_family(instance)))

            # Input stats
            push!(row, get(data, "inp_opb_size", ""))
            push!(row, get(data, "inp_pbp_size", ""))
            push!(row, get(data, "inp_total_size", ""))
            push!(row, get(data, "inp_literals", ""))
            push!(row, get(data, "inp_variables", ""))
            push!(row, get(data, "inp_opb_nbeq", ""))
            push!(row, get(data, "inp_pbp_nbeq", ""))
            push!(row, get(data, "inp_total_nbeq", ""))

            # Grim stats
            push!(row, get(data, "grim_parse_time", ""))
            push!(row, get(data, "grim_trim_time", ""))
            push!(row, get(data, "grim_write_time", ""))
            push!(row, get(data, "grim_total_time", ""))
            push!(row, get(data, "grim_opb_cone", ""))
            push!(row, get(data, "grim_pbp_cone", ""))
            push!(row, get(data, "grim_total_cone", ""))
            push!(row, get(data, "grim_cone_literals", ""))
            push!(row, get(data, "grim_smol_literals", ""))
            push!(row, get(data, "grim_cone_variables", ""))
            push!(row, get(data, "grim_opb_size", ""))
            push!(row, get(data, "grim_pbp_size", ""))
            push!(row, get(data, "grim_total_size", ""))

            # Gclt stats
            push!(row, get(data, "gclt_trim_time", ""))
            push!(row, get(data, "gclt_opb_cone", ""))
            push!(row, get(data, "gclt_pbp_cone", ""))
            push!(row, get(data, "gclt_total_cone", ""))
            push!(row, get(data, "gclt_cone_literals", ""))
            push!(row, get(data, "gclt_smol_literals", ""))
            push!(row, get(data, "gclt_cone_variables", ""))

            # Gbfs stats
            push!(row, get(data, "gbfs_trim_time", ""))
            push!(row, get(data, "gbfs_opb_cone", ""))
            push!(row, get(data, "gbfs_pbp_cone", ""))
            push!(row, get(data, "gbfs_total_cone", ""))
            push!(row, get(data, "gbfs_cone_literals", ""))
            push!(row, get(data, "gbfs_smol_literals", ""))
            push!(row, get(data, "gbfs_cone_variables", ""))

            # Verification
            push!(row, get(data, "veri_smol_time", ""))
            push!(row, get(data, "veri_total_time", ""))
            push!(row, haskey(data, "veri_smol_verified") ? data["veri_smol_verified"] : "")
            veri_opb, veri_pbp, veri_total = get_verification_sizes(proofdir, instance)
            push!(row, veri_opb !== nothing ? veri_opb : "")
            push!(row, veri_pbp !== nothing ? veri_pbp : "")
            push!(row, veri_total !== nothing ? veri_total : "")

            # Solver stats
            push!(row, get(data, "pattern_vertices", ""))
            push!(row, get(data, "target_vertices", ""))
            push!(row, get(data, "runtime_ms", ""))
            status_val = get(data, "status", "")
            push!(row, status_val == "" ? "" : csv_quote(status_val))
            push!(row, get(data, "solver_nodes", ""))
            push!(row, get(data, "solver_propagations", ""))

            # UNSAT core statistics
            core_pat, core_tar, pat_total, tar_total = get_core_stats(proofdir, instance)
            push!(row, core_pat !== nothing ? core_pat : "")
            push!(row, core_tar !== nothing ? core_tar : "")
            push!(row, pat_total !== nothing ? pat_total : "")
            push!(row, tar_total !== nothing ? tar_total : "")

            # Instance classification
            is_sat = (status_val == "true")
            is_unsat = (status_val == "false")
            has_proof = haskey(data, "grim_total_time")
            push!(row, is_sat ? "true" : "false")
            push!(row, is_unsat ? "true" : "false")
            push!(row, has_proof ? "true" : "false")

            skip_reason = detect_skip_reason(err_file, has_proof, status_val)
            proof_truncated = startswith(skip_reason, "truncated")
            truncation_reason = proof_truncated ? skip_reason : ""
            push!(row, skip_reason == "" ? "" : csv_quote(skip_reason))
            push!(row, proof_truncated ? "true" : "false")
            push!(row, truncation_reason == "" ? "" : csv_quote(truncation_reason))

            # Error tracking
            push!(row, has_error ? "true" : "false")
            push!(row, has_error ? csv_quote(error_type) : "")
            push!(row, has_error && !isempty(error_details) ? csv_quote(error_details) : "")

            # Resolv iterations
            push!(row, resolv_iters)

            push!(row, format_array(iter_sizes_total))
            push!(row, format_array(iter_sizes_opb))
            push!(row, format_array(iter_sizes_pbp))
            push!(row, format_array(iter_nbeq))
            push!(row, format_array(iter_var))
            push!(row, format_array(iter_lit))

            # Step-type breakdown — cone and full
            push!(row, get(data, "grim_cone_rup", ""))
            push!(row, get(data, "grim_cone_pol", ""))
            push!(row, get(data, "grim_cone_red", ""))
            push!(row, get(data, "grim_cone_ia",  ""))
            push!(row, get(data, "grim_full_rup", ""))
            push!(row, get(data, "grim_full_pol", ""))
            push!(row, get(data, "grim_full_red", ""))
            push!(row, get(data, "grim_full_ia",  ""))

            # Cone depth
            push!(row, get(data, "grim_cone_depth_max",  ""))
            push!(row, get(data, "grim_cone_depth_mean", ""))
            # Full depth
            push!(row, get(data, "grim_full_depth_max",  ""))
            push!(row, get(data, "grim_full_depth_mean", ""))

            # Cone depth distribution
            push!(row, get(data, "grim_cone_depth_p50",        ""))
            push!(row, get(data, "grim_cone_depth_p90",        ""))
            push!(row, get(data, "grim_cone_depth_entropy",    ""))
            push!(row, get(data, "grim_cone_bottom_frac",      ""))
            push!(row, get(data, "grim_cone_bottleneck_depth", ""))
            push!(row, get(data, "grim_cone_width_max",        ""))
            push!(row, get(data, "grim_cone_width_cv",         ""))
            push!(row, get(data, "grim_cone_rup_depth_cv",     ""))
            push!(row, get(data, "grim_cone_pol_depth_mean",   ""))
            push!(row, get(data, "grim_cone_pol_depth_cv",     ""))
            push!(row, get(data, "grim_cone_pol_depth_frac_bot", ""))
            push!(row, get(data, "grim_cone_pol_depth_frac_top", ""))
            push!(row, get(data, "grim_cone_pol_ante_mean",    ""))
            push!(row, get(data, "grim_cone_pol_ante_max",     ""))
            push!(row, get(data, "grim_cone_pol_opb_frac",     ""))
            push!(row, get(data, "grim_cone_pol_before_rup_burst", ""))

            # Full depth distribution
            push!(row, get(data, "grim_full_depth_p50",        ""))
            push!(row, get(data, "grim_full_depth_p90",        ""))
            push!(row, get(data, "grim_full_depth_entropy",    ""))
            push!(row, get(data, "grim_full_bottom_frac",      ""))
            push!(row, get(data, "grim_full_width_max",        ""))
            push!(row, get(data, "grim_full_width_cv",         ""))
            push!(row, get(data, "grim_full_rup_depth_cv",     ""))
            push!(row, get(data, "grim_full_pol_depth_mean",   ""))
            push!(row, get(data, "grim_full_pol_depth_cv",     ""))
            push!(row, get(data, "grim_full_pol_ante_mean",    ""))
            push!(row, get(data, "grim_full_pol_ante_max",     ""))
            push!(row, get(data, "grim_full_pol_opb_frac",     ""))
            push!(row, get(data, "grim_full_pol_before_rup_burst", ""))

            # Step-type fractions — cone (derived, denominator = total cone)
            let tot = get(data, "grim_total_cone", nothing)
                function stepfrac(key)
                    v = get(data, key, nothing)
                    (v !== nothing && tot !== nothing && tot > 0) ? round(v / tot; digits=4) : ""
                end
                push!(row, stepfrac("grim_cone_rup"))
                push!(row, stepfrac("grim_cone_pol"))
                push!(row, stepfrac("grim_cone_ia"))
                push!(row, stepfrac("grim_cone_red"))
            end

            # Step-type fractions — full (derived, denominator = total nbeq)
            let tot_full = get(data, "inp_total_nbeq", nothing)
                function fullstepfrac(key)
                    v = get(data, key, nothing)
                    (v !== nothing && tot_full !== nothing && tot_full > 0) ? round(v / tot_full; digits=4) : ""
                end
                push!(row, fullstepfrac("grim_full_rup"))
                push!(row, fullstepfrac("grim_full_pol"))
                push!(row, fullstepfrac("grim_full_ia"))
                push!(row, fullstepfrac("grim_full_red"))
            end

            # Literal compression
            let cl = get(data, "grim_cone_literals", nothing),
                sl = get(data, "grim_smol_literals",  nothing)
                push!(row, (cl !== nothing && sl !== nothing && cl > 0) ?
                    round((cl - sl) / cl; digits=4) : "")
            end

            # Resolv shrinkage curve and stop reason
            iter_pat = get(data, "resolv_iter_pat", [])
            iter_tar = get(data, "resolv_iter_tar", [])
            push!(row, format_array(iter_pat))
            push!(row, format_array(iter_tar))
            stop = get(data, "resolv_stop_reason", "")
            push!(row, stop == "" ? "" : csv_quote(stop))

            # Resolv shrinkage totals (derived)
            let pat0 = get(data, "pattern_vertices", nothing),
                tar0 = get(data, "target_vertices",  nothing)
                push!(row, (pat0 !== nothing && pat0 > 0 && !isempty(iter_pat)) ?
                    round((pat0 - last(iter_pat)) / pat0; digits=4) : "")
                push!(row, (tar0 !== nothing && tar0 > 0 && !isempty(iter_tar)) ?
                    round((tar0 - last(iter_tar)) / tar0; digits=4) : "")
            end

            # Label counts — cone and full
            for lc in _LABEL_TAGS; push!(row, get(data, "grim_cone_$lc", "")); end
            push!(row, get(data, "grim_cone_unlabeled", ""))
            for lc in _LABEL_TAGS; push!(row, get(data, "grim_full_$lc", "")); end
            push!(row, get(data, "grim_full_unlabeled", ""))

            # Label fractions of total cone (derived)
            let tot_cone = get(data, "grim_total_cone", nothing)
                function labelfrac(key)
                    v = get(data, key, nothing)
                    (v !== nothing && tot_cone !== nothing && tot_cone > 0) ? round(v / tot_cone; digits=4) : ""
                end
                push!(row, labelfrac("grim_cone_inj"))
                push!(row, labelfrac("grim_cone_g0adj"))
                push!(row, labelfrac("grim_cone_g1adj"))
                push!(row, labelfrac("grim_cone_g2adj"))
                push!(row, labelfrac("grim_cone_g3adj"))
                push!(row, labelfrac("grim_cone_forb"))
                push!(row, labelfrac("grim_cone_noedge"))
                push!(row, labelfrac("grim_cone_elimdegpol"))
                push!(row, labelfrac("grim_cone_elimnds"))
                push!(row, labelfrac("grim_cone_elimdeg"))
                push!(row, labelfrac("grim_cone_hall"))
                push!(row, labelfrac("grim_cone_prop"))
                push!(row, labelfrac("grim_cone_guess"))
                push!(row, labelfrac("grim_cone_nogood"))
                push!(row, labelfrac("grim_cone_pathg1"))
                push!(row, labelfrac("grim_cone_pathg2"))
                push!(row, labelfrac("grim_cone_pathg3"))
                push!(row, labelfrac("grim_cone_pathg_other"))
                push!(row, labelfrac("grim_cone_d2g1"))
                push!(row, labelfrac("grim_cone_d2g2"))
                push!(row, labelfrac("grim_cone_d2g3"))
                push!(row, labelfrac("grim_cone_d2g_other"))
                push!(row, labelfrac("grim_cone_d3g1"))
                push!(row, labelfrac("grim_cone_d3g2"))
                push!(row, labelfrac("grim_cone_d3g3"))
                push!(row, labelfrac("grim_cone_d3g_other"))
            end

            # Variable order — cone and full
            push!(row, get(data, "grim_cone_uniq_pat", ""))
            push!(row, get(data, "grim_cone_uniq_tar", ""))
            push!(row, get(data, "grim_full_uniq_pat", ""))
            push!(row, get(data, "grim_full_uniq_tar", ""))

            # Write row
            if length(row) != length(CSV_COLUMNS)
                println(stderr, "WARNING: $instance has $(length(row)) fields, expected $(length(CSV_COLUMNS)) — skipping")
                continue
            end
            println(io, join(row, ","))
        end
    end

    println("Done! Results written to: $output_csv")
end

# Main
if length(ARGS) < 1
    println("Usage: julia aggregate_results.jl <proofs_directory> [output_csv]")
    println()
    println("Example: julia aggregate_results.jl /home/arthur_gla/veriPB/subgraphsolver/proofs/ results.csv")
    exit(1)
end

proofdir = ARGS[1]
output_csv = length(ARGS) >= 2 ? ARGS[2] : "results.csv"

aggregate_results(proofdir, output_csv)
