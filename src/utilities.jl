# ══ Utilities ══════════════════════════════════════════════════════════════════════════

    # MemAvailable from /proc/meminfo includes reclaimable page cache, unlike Sys.free_memory() (MemFree only).
    # On a busy cluster reading large proof files, page cache can consume hundreds of GB, making MemFree
    # appear critically low while the system actually has plenty of usable memory.
function available_memory()
    if isfile("/proc/meminfo")
        for line in eachline("/proc/meminfo")
            startswith(line, "MemAvailable:") && return parse(Int, split(line)[2]) * 1024
        end
    end
    return Sys.free_memory() end # fallback for non-Linux

    # ── Admission gate ────────────────────────────────────────────────────────────────
    # Block until the node has `minmem=` free before launching a memory-hungry child.
    #
    # This is the ONLY whole-node protection there is. The OOM monitor is per-process: it
    # kills a child that individually exceeds `maxmem=`, which does nothing about ninety
    # well-behaved children adding up to more RAM than the node has. Every stage that
    # spawns a heavyweight process must pass through here — solve, verif, cake and trim —
    # or it is admitted regardless of what the other threads are already holding.
    #
    # Deliberately unbounded: waiting is always better than being OOM-killed by the kernel,
    # which picks its victim by its own heuristic and would just as happily take the
    # orchestrator as the child. `stage` and `ins` only feed the one-line notice, which is
    # printed once per wait rather than once per poll so a long queue stays readable.
function wait_for_memory(stage::AbstractString="", ins::AbstractString="")
    _cfg[].minfreemem <= 0 && return
    available_memory() >= _cfg[].minfreemem && return
    t0 = time()
    printstyled("  ", isempty(ins) ? "" : "$ins ", "waiting for memory",
                isempty(stage) ? "" : " ($stage)",
                ": ", round(available_memory() / 1024^3; digits=1), " GB free < ",
                _cfg[].minfreemem ÷ 1024^3, " GB\n"; color=:yellow)
    while available_memory() < _cfg[].minfreemem
        sleep(5)
    end
    printstyled("  ", isempty(ins) ? "" : "$ins ", "resumed after ",
                round(Int, time() - t0), "s\n"; color=:yellow)
    return end

    # Read the resident set size of a subprocess from /proc/PID/status (Linux only).
    # Returns GB; 0.0 if the process already exited or on non-Linux.
function process_rss_gb(pid::Int)
    try
        for line in eachline("/proc/$pid/status")
            startswith(line, "VmRSS:") && return parse(Int, split(line)[2]) / 1024^2
        end
    catch end
    return 0.0 end

onlyname(x) = splitext(basename(x))[1]
ext(x) = splitext(basename(x))[2]
noext(x) = splitext(x)[1]
inssize(file) = filesize(_cfg[].proofs*file*opb) + filesize(_cfg[].proofs*file*pbp)
function _shuffle!(v)
    for i in length(v):-1:2
        j = rand(1:i)
        v[i], v[j] = v[j], v[i]
    end
    return v end
tryrm(s) = if isfile(s) rm(s) end
remove(s,c) = replace(s,c=>"")
const tabhead = "\\begin{tabular}{|cc|cc|c|c|c|}\\hline sizes & & &  & times (s) & & Instance\\\\\\hline\nopb & pbp & smol o & smol p & grim time (parse trim write verif) & veri time & \\\\\\hline"
const tabfoot = "\\end{tabular}\\\\\n"
