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
tryrm(s) = if isfile(s) rm(s) end
remove(s,c) = replace(s,c=>"")
const tabhead = "\\begin{tabular}{|cc|cc|c|c|c|}\\hline sizes & & &  & times (s) & & Instance\\\\\\hline\nopb & pbp & smol o & smol p & grim time (parse trim write verif) & veri time & \\\\\\hline"
const tabfoot = "\\end{tabular}\\\\\n"
