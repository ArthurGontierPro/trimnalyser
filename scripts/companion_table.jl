#!/usr/bin/env julia
# ══════════════════════════════════════════════════════════════════════════════════════
# Aggregate scripts/companion_compare.sh's CSV into the appendix table and the four
# in-prose numbers of sec:compress.
#
#   julia scripts/companion_table.jl <compare.csv> [more.csv...] [--tex=out.tex]
#
# Statistic.  The companion reports a 1-SHIFTED GEOMETRIC MEAN, sgm(x) = exp(mean(ln(x+1)))-1,
# so every ratio here is one too — otherwise our headline is not comparable with the 6.85
# they publish.  Medians are printed beside it because the distributions are heavily
# right-skewed (sec:exp-run) and a reader should see both.
#
# Pairing.  Every ratio between two tools is computed PER INSTANCE and only on instances
# where BOTH tools produced a checked proof.  A tool that fails on the hard half would
# otherwise win on aggregate by not competing there, which is exactly the artefact the
# companion's own 6.85 turns out to be sensitive to (it moves to 8.5-14.6 depending on
# the exclusion set).  Every table therefore carries its own n, and the failures are
# reported as counts, never dropped silently.
#
# Size.  A certificate is its model plus its proof, as in tab:compression: the trimmed
# .opb and the trimmed ELABORATED .pbp together, against the original .opb plus the
# elaborated full .pbp.  Both trimmers are measured after elaboration because the VeriPB
# trimmers only ever emit elaborated proofs, while our .smol.pbp still carries `rup`.
# ══════════════════════════════════════════════════════════════════════════════════════

const FAMS = ["LV", "bio", "images", "meshes"]
const TOOLS = ["ta", "ft", "tb"]
const TOOLNAME = Dict("ta" => "TrimAnalyser", "ft" => "VeriPB trim (feature\\_trimmer)",
                      "tb" => "VeriPB trim (trimmer-base)")

sgm(v) = isempty(v) ? NaN : exp(sum(log.(v .+ 1)) / length(v)) - 1
med(v) = isempty(v) ? NaN : (s = sort(v); n = length(s);
                             isodd(n) ? s[(n+1)÷2] : (s[n÷2] + s[n÷2+1]) / 2)

num(s) = (s === nothing || isempty(s)) ? nothing : tryparse(Float64, s)
posnum(s) = (x = num(s); (x === nothing || x <= 0) ? nothing : x)

# ── reuse ────────────────────────────────────────────────────────────────────────────
# The baseline and the TrimAnalyser arm do not have to be recomputed: the grid pipeline
# already logs every quantity they produce, per instance, for the whole suite —
# `cake full ELAB SIZE` is the baseline certificate, `grim OPB/PBP SIZE` and
# `cake smol ELAB SIZE` are ours, and `grim TIME` is the trim time. Glasgow is
# deterministic for a fixed binary and flags, so the stock proof reproduces exactly and
# those numbers describe the same proof the VeriPB trimmers are reading now.
#
# "Deterministic" is an assumption, though, and assumptions of that shape have been wrong
# here before. So it is CHECKED PER ROW rather than taken globally: the comparison CSV
# records the .opb and .pbp byte sizes it actually saw, and a row whose sizes disagree with
# the grid's `inp_opb_size`/`inp_pbp_size` did not read the same proof — its reused columns
# are dropped and it is counted as a mismatch. A nonzero mismatch count is the signal that
# this whole shortcut is unsound; it is printed, never buried.
const REUSE_MAP = Dict(
    "base_status"      => ("veri_full_status",    s -> uppercase(s) == "VERIFIED" ? "ok" : "fail"),
    "base_bytes"       => ("cake_elab_size",      identity),
    # No base_s: the grid logs the full proof's verify time under a key the aggregator
    # does not surface as a column. Nothing computes with it — only base_status and
    # base_bytes are used — so it is left empty rather than guessed at.
    "ta_opb_bytes"     => ("grim_opb_size",       identity),
    "ta_pbp_bytes"     => ("grim_pbp_size",       identity),
    "ta_elab_bytes"    => ("cake_smol_elab_size", identity),
    # grim_total_time is parse+trim+write — the trimmer's whole job, which is what the
    # externally-timed ft/tb arms measure. grim_trim_time alone would flatter us.
    "ta_s"             => ("grim_total_time",     identity),
    "ta_status"        => ("grim_total_time",     s -> isempty(s) ? "" : "ok"),
    "ta_elab_status"   => ("veri_smol_status",    s -> uppercase(s) == "VERIFIED" ? "ok" : "fail"),
    "ta_check_status"  => ("veri_smol_status",    s -> uppercase(s) == "VERIFIED" ? "ok" : "fail"),
    "ta_elab_s"        => ("veri_smol_time",      identity),
    "ta_check_s"       => ("veri_smol_time",      identity),
)

function readcsv(path)
    lines = readlines(path)
    isempty(lines) && return String[], Vector{Dict{String,String}}()
    hdr = split(lines[1], ',')
    rows = Dict{String,String}[]
    for l in lines[2:end]
        isempty(strip(l)) && continue
        f = split(l, ','; limit = length(hdr))
        length(f) < length(hdr) && append!(f, fill("", length(hdr) - length(f)))
        push!(rows, Dict(String(hdr[i]) => String(f[i]) for i in eachindex(hdr)))
    end
    return String.(hdr), rows
end

unq(x) = (y = strip(x); (length(y) >= 2 && y[1] == '"' && y[end] == '"') ? y[2:end-1] : y)

# Fill the base_* and ta_* columns of `rows` from a grid results CSV, for the rows where
# the stock proof provably matches. Returns (filled, mismatched, missing).
# A plain comment, not a docstring: this file is also partially evaluated (prefix up to the
# load section) by the reuse validation, and `@doc` at that boundary does not survive it.
function reuse!(rows, path, config)
    hdr, grid = readcsv(path)
    for c in ("instance", "config", "inp_opb_size", "inp_pbp_size")
        c in hdr || error("reuse file $path has no `$c` column")
    end
    by = Dict{String,Dict{String,String}}()
    for r in grid
        unq(get(r, "config", "")) == config || continue
        by[unq(r["instance"])] = r
    end
    println("reuse: $(length(by)) `$config` rows from $path")
    filled = mismatch = missng = 0
    for r in rows
        g = get(by, r["instance"], nothing)
        if g === nothing
            missng += 1; continue
        end
        # The guard. Both sizes, exactly; a proof that differs at all is a different proof.
        if unq(g["inp_opb_size"]) != strip(r["opb_bytes"]) ||
           unq(g["inp_pbp_size"]) != strip(r["pbp_bytes"])
            mismatch += 1
            r["rc_note"] = "reuse-mismatch"
            continue
        end
        for (dst, (src, f)) in REUSE_MAP
            haskey(g, src) || continue     # column absent in this grid CSV: leave it empty
            v = unq(g[src])
            r[dst] = isempty(v) ? "" : String(f(v))
        end
        filled += 1
    end
    return filled, mismatch, missng
end

# A row counts for a tool only if that tool produced a proof the SHARED checker accepted.
# `ok` on the trim alone is not enough: a trimmed proof the checker rejects is not a
# smaller certificate, it is a bug (see the note on trimming rescue in CLAUDE.md).
function certsize(r, tool)
    if tool == "ta"
        r["ta_status"] == "ok" || return nothing
        r["ta_elab_status"] == "ok" || return nothing
        r["ta_check_status"] == "ok" || return nothing
        o = posnum(r["ta_opb_bytes"]); p = posnum(r["ta_elab_bytes"])
        (o === nothing || p === nothing) && return nothing
        return o + p
    else
        r["$(tool)_status"] == "ok" || return nothing
        r["$(tool)_check_status"] == "ok" || return nothing
        p = posnum(r["$(tool)_pbp_bytes"]); p === nothing && return nothing
        # No reformulated model emitted -> the proof is still against the original .opb,
        # so that is what belongs in its certificate size.
        o = posnum(r["$(tool)_opb_bytes"])
        o === nothing && (o = posnum(r["opb_bytes"]))
        o === nothing && return nothing
        return o + p
    end
end

# Proof only, ignoring the model.  Two reasons this is reported beside the certificate:
# the companion's published 6.85 is sgm(elaborated/trimmed) over PROOFS, so it is the only
# framing directly comparable with it; and the VeriPB trimmer emits no reformulated model
# at all (its `output_formula` positional is never written on these proofs), so its
# certificate keeps the original .opb whole while ours is trimmed with the proof.  Quoting
# only the certificate ratio would credit us for a model reduction the companion does not
# attempt; quoting only the proof ratio would hide it.  Both, then.
function proofsize(r, tool)
    if tool == "ta"
        (r["ta_status"] == "ok" && r["ta_elab_status"] == "ok" && r["ta_check_status"] == "ok") || return nothing
        return posnum(r["ta_elab_bytes"])
    else
        (r["$(tool)_status"] == "ok" && r["$(tool)_check_status"] == "ok") || return nothing
        return posnum(r["$(tool)_pbp_bytes"])
    end
end
baseproof(r) = r["base_status"] == "ok" ? posnum(r["base_bytes"]) : nothing

baseline(r) = begin
    r["base_status"] == "ok" || return nothing
    o = posnum(r["opb_bytes"]); p = posnum(r["base_bytes"])
    (o === nothing || p === nothing) ? nothing : o + p
end
trimtime(r, tool) = num(r["$(tool)_s"])

function famof(r)
    f = r["family"]
    f in FAMS ? f : "other"
end

# ── load ─────────────────────────────────────────────────────────────────────────────
args = copy(ARGS)
texout = nothing
reusefile = nothing; reuseconfig = "gss-lazy"
let i = findfirst(a -> startswith(a, "--tex="), args)
    if i !== nothing
        texout = args[i][7:end]; deleteat!(args, i)
    end
end
let i = findfirst(a -> startswith(a, "--reuse="), args)
    if i !== nothing
        reusefile = args[i][9:end]; deleteat!(args, i)
    end
end
let i = findfirst(a -> startswith(a, "--reuse-config="), args)
    if i !== nothing
        reuseconfig = args[i][16:end]; deleteat!(args, i)
    end
end
isempty(args) && (println("usage: julia scripts/companion_table.jl <compare.csv>... [--tex=out.tex]"); exit(1))
rows = Dict{String,String}[]
for p in args
    _, rr = readcsv(p); append!(rows, rr)
    println("read $(length(rr)) rows from $p")
end
if reusefile !== nothing
    for r in rows, c in keys(REUSE_MAP)
        haskey(r, c) || (r[c] = "")
    end
    f, m, x = reuse!(rows, reusefile, reuseconfig)
    println("reuse: filled $f row(s), $m proof MISMATCH, $x not in the grid run")
    if m > 0
        println("  !! $m row(s) read a different stock proof than the grid did.")
        println("     Their reused columns were dropped. If this is more than a handful,")
        println("     the solver is not reproducing and base/ta must be measured, not reused.")
    end
end
present = [t for t in TOOLS if any(r -> get(r, "$(t)_status", "") != "", rows)]
println("tools present: ", join(present, ", "))

# ── per-family, per-tool summary ─────────────────────────────────────────────────────
println()
println(rpad("family", 9), rpad("tool", 14), rpad("n", 6), rpad("sgm(cert)", 12),
        rpad("sgm(proof)", 12), rpad("sgm(trim s)", 13), rpad("med(chk s)", 12), "failed")
println("-"^84)
summary = Dict{Tuple{String,String},Any}()
for fam in [FAMS; "ALL"], tool in present
    sel = fam == "ALL" ? rows : filter(r -> famof(r) == fam, rows)
    isempty(sel) && continue
    compr = Float64[]; pcompr = Float64[]; tt = Float64[]; ck = Float64[]; nfail = 0
    for r in sel
        b = baseline(r); c = certsize(r, tool)
        if b === nothing
            continue                      # no denominator: the row cannot judge any tool
        elseif c === nothing
            nfail += 1
        else
            push!(compr, b / c)
            pb = baseproof(r); pc = proofsize(r, tool)
            (pb !== nothing && pc !== nothing) && push!(pcompr, pb / pc)
            t = trimtime(r, tool); t !== nothing && push!(tt, t)
            cs = num(r["$(tool)_check_s"]); cs !== nothing && push!(ck, cs)
        end
    end
    summary[(fam, tool)] = (n = length(compr), sgm = sgm(compr), med = med(compr),
                            psgm = sgm(pcompr), tsgm = sgm(tt), tmed = med(tt),
                            cmed = med(ck), fail = nfail)
    s = summary[(fam, tool)]
    println(rpad(fam, 9), rpad(tool, 14), rpad(s.n, 6),
            rpad(round(s.sgm; digits = 2), 12), rpad(round(s.psgm; digits = 2), 12),
            rpad(round(s.tsgm; digits = 2), 13), rpad(round(s.cmed; digits = 2), 12), s.fail)
end

# ── head-to-head, paired ─────────────────────────────────────────────────────────────
# X = how many times smaller OUR certificate is than theirs, on instances both handled.
# Y = how many times longer we take to produce it.  Both sgm, both paired.
function headtohead(sel, other)
    sz = Float64[]; pz = Float64[]; ti = Float64[]
    for r in sel
        a = certsize(r, "ta"); b = certsize(r, other)
        (a === nothing || b === nothing) && continue
        push!(sz, b / a)
        pa = proofsize(r, "ta"); pb = proofsize(r, other)
        (pa !== nothing && pb !== nothing) && push!(pz, pb / pa)
        ta = trimtime(r, "ta"); tb = trimtime(r, other)
        (ta === nothing || tb === nothing || tb <= 0) && continue
        push!(ti, ta / tb)
    end
    return sz, pz, ti
end
println()
for other in filter(!=("ta"), present)
    println("=== TrimAnalyser vs $(TOOLNAME[other]) ===")
    for fam in [FAMS; "ALL"; "companionLV"]
        sel = fam == "ALL" ? rows :
              fam == "companionLV" ?
                  filter(r -> r["instance"] in
                         ["LVg19g36","LVg2g3","LVg34g51","LVg5g24","LVg7g25"], rows) :
                  filter(r -> famof(r) == fam, rows)
        sz, pz, ti = headtohead(sel, other)
        isempty(sz) && continue
        println(rpad(fam, 13), "n=", rpad(length(sz), 6),
                "  cert smaller by sgm ", round(sgm(sz); digits = 2),
                "  proof smaller by sgm ", round(sgm(pz); digits = 2),
                "  slower by sgm ", round(sgm(ti); digits = 2),
                " (median ", round(med(ti); digits = 2), ")")
    end
    # The four \ph macros, spelled out so they can be pasted without re-deriving them.
    szA, pzA, tiA = headtohead(rows, other)
    szL, pzL, tiL = headtohead(filter(r -> r["instance"] in
                     ["LVg19g36","LVg2g3","LVg34g51","LVg5g24","LVg7g25"], rows), other)
    println()
    println("  sec:compress placeholders (vs $other):")
    println("    \\ph{X}   = ", round(sgm(szA); digits = 2), "   certificate, n=", length(szA),
            "   [proof only: ", round(sgm(pzA); digits = 2), "]")
    println("    \\ph{Y}   = ", round(sgm(tiA); digits = 2), "   n=", length(tiA))
    println("    \\ph{XLV} = ", round(sgm(szL); digits = 2), "   certificate, n=", length(szL),
            "   [proof only: ", round(sgm(pzL); digits = 2), "]")
    println("    \\ph{YLV} = ", round(sgm(tiL); digits = 2), "   n=", length(tiL))
    println()
    # Why a trimmer refused a proof VeriPB itself accepted. These go upstream, so they are
    # printed in full rather than counted.
    notes = Dict{String,Int}()
    for r in rows
        nt = strip(get(r, "$(other)_note", ""))
        isempty(nt) && continue
        notes[nt] = get(notes, nt, 0) + 1
    end
    if !isempty(notes)
        println("  $other refused ", sum(values(notes)), " proof(s):")
        for (k, v) in sort(collect(notes); by = x -> -x[2])
            println("    [", v, "]  ", k)
        end
        println()
    end
end

# ── LaTeX ────────────────────────────────────────────────────────────────────────────
function tex(io)
    f2(x) = isnan(x) ? "--" : "\$" * string(round(x; digits = 2)) * "\$"
    println(io, "% generated by scripts/companion_table.jl -- do not edit by hand")
    println(io, "\\begin{table}[tbp]")
    println(io, "\\centering\\small")
    println(io, "\\begin{tabular}{ll", "r"^6, "}")
    println(io, "\\toprule")
    println(io, "Family & Trimmer & \$n\$ & failed & \\multicolumn{2}{c}{Compression (sgm)} & Trim (s) & Check (s) \\\\")
    println(io, "& & & & certificate & proof & sgm & median \\\\")
    println(io, "\\midrule")
    for fam in [FAMS; "ALL"]
        first = true
        for tool in present
            haskey(summary, (fam, tool)) || continue
            s = summary[(fam, tool)]
            println(io, (first ? (fam == "ALL" ? "\\midrule\nAll" : fam) : ""), " & ",
                    TOOLNAME[tool], " & \$", s.n, "\$ & \$", s.fail, "\$ & ",
                    f2(s.sgm), " & ", f2(s.psgm), " & ", f2(s.tsgm), " & ", f2(s.cmed), " \\\\")
            first = false
        end
    end
    println(io, "\\bottomrule")
    println(io, "\\end{tabular}")
    println(io, "\\caption{TrimAnalyser against the VeriPB trimmer, on one and the same ",
            "stock proof per instance. \\emph{Compression} is the untrimmed certificate ",
            "over the trimmed one, both counted as model plus \\emph{elaborated} proof: ",
            "the VeriPB trimmer emits only elaborated proofs, so ours is elaborated too ",
            "before it is measured. A row counts for a trimmer only where the shared ",
            "checker accepted that trimmer's output; \\emph{failed} counts the instances ",
            "where it did not, on rows whose untrimmed baseline did check. ",
            "\\emph{sgm} is the \$1\$-shifted geometric mean, as the companion ",
            "reports~\\cite{TrimmingPBproofs}. Two compression columns because the ",
            "VeriPB trimmer emits no reformulated model: its certificate keeps the ",
            "original \\texttt{.opb} whole, while ours is trimmed alongside the proof. ",
            "\\emph{proof} is the \\texttt{.pbp} alone, the framing the companion's own ",
            "figure uses.}")
    println(io, "\\label{tab:configs-companion}")
    println(io, "\\end{table}")
end
tex(stdout)
if texout !== nothing
    open(io -> tex(io), texout, "w"); println("\nwrote $texout")
end
