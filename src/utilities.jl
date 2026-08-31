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

    # ── Disk, and the admission gate that goes with it ────────────────────────────────
    # Free bytes on the filesystem holding the proofs directory. Uses `df -P` rather than
    # statvfs because Julia exposes no portable statvfs; -P forces the one-line POSIX
    # format so a long device name cannot wrap and shift the columns.
function available_disk(path::AbstractString = _cfg[].proofs)
    try
        out = read(`df -Pk $path`, String)
        lines = split(chomp(out), '\n')
        length(lines) >= 2 || return typemax(Int)
        return parse(Int, split(lines[2])[4]) * 1024
    catch
        return typemax(Int)   # never block on an unreadable df
    end end

    # Block until the node has `mindisk=` free before launching a proof-producing child.
    #
    # Exactly the wait_for_memory argument, one resource over: the OOM monitor is
    # per-process and there is no equivalent for disk at all. A single Glasgow proof is
    # normally megabytes, so this never fires on the Glasgow grid; LAD proofs carry no
    # deletions and grow with search length, and ninety threads each writing one can take
    # /scratch from comfortable to full inside a single instance's solve.
    #
    # Waiting is right for the same reason it is right for memory: the alternative is
    # ENOSPC mid-write, which yields a truncated proof indistinguishable from a solver
    # memout and silently corrupts the run's accounting. Unbounded, because the other
    # threads are draining proofs as they certify them, so the wait does end.
function wait_for_disk(stage::AbstractString="", ins::AbstractString="")
    _cfg[].mindiskfree <= 0 && return
    available_disk() >= _cfg[].mindiskfree && return
    t0 = time()
    printstyled("  ", isempty(ins) ? "" : "$ins ", "waiting for disk",
                isempty(stage) ? "" : " ($stage)",
                ": ", round(available_disk() / 1024^3; digits=1), " GB free < ",
                _cfg[].mindiskfree ÷ 1024^3, " GB\n"; color=:yellow)
    while available_disk() < _cfg[].mindiskfree
        sleep(5)
    end
    printstyled("  ", isempty(ins) ? "" : "$ins ", "resumed after ",
                round(Int, time() - t0), "s (disk)\n"; color=:yellow)
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
