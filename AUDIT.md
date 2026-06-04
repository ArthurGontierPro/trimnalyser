# TrimAnalyser — Profiling Candidates

All prior bug fixes and performance work are in git history. The items below need
profiling on a large cluster instance before investing implementation time.

| Item | Location | Cost | Note |
|------|----------|------|------|
| `ruptrail` heap seeding | `trimmer.jl:284` | O(n log n) per RUP step — n individual `push!` into `BinaryMinHeap` | Replace with two `BitVector` fills + `findfirst` scan |
| `fixconelits` Set allocs | `trimmer.jl:73` | `Set{Int}` union/intersection per cone POL/IA step | Replace with sorted-array merge on reused scratch |
| `findfullassi` O(n²) loop | `parser.jl:374` | Quadratic unit propagation at parse time | Rare (`soli`/`solx` steps); BFS + temp inverse index if it shows up |
