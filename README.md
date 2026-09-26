# CUDA Smith-Waterman learning project

This project contains various dynamic programming kernels for sequence alignment.
Nothing here is terribly novel, its just me refreshing my CUDA skills.

## Build and run

On a Linux host with the CUDA Toolkit, NVIDIA driver, and a GPU:

```sh
make
make run
make help
build/cudasw --help
build/cudasw sw-tiled \
    --target-length 8096 --query-length 8096
```

### Apple silicon

On macOS, the Makefile uses [mvcc](https://github.com/doximity/mvcc) as a CUDA-compatible compiler and runtime.
`make` will clone `mvcc` into `thirdparty/mvcc` and build its toolkit automatically.
There are some help macros in `src/common.h` that assist with using CUDA on macOS.

The CPU implementation uses sse2neon to allow use of the SSE4 version of the code.

## Experiments

Its a bit grand to call these experiments, given everything here is known and standard to anyone already in the game.

The presentation order below is simply the order I wrote the code.

> **The code is not intended to be used in production implementations**

### vec-add

Not dynamic programming.
This is just the first thing I wrote to get the build system going.
It adds (or multiplies, Hadamard product) two vectors, each thread calculating one item.

### sw-naive

This is naive parallelism of lots of SW jobs using a single thread.
There's a hard limit imposed on the target length as each thread owns a buffer for the current and previous row of the DP matrix.

Target sequences are generated randomly from the function `generate_sequence()` in `src/common.c`.
Query sequences are simulated by taking a target sequence and applying insertion, deletion, and substitution mutation rates.
Both use the seeded generator passed from the program, so `--seed` makes a run reproducible.
It is worth noting that `--query-length` is a capacity, rather than a guaranteed generated query length.
Deletions can make the query shorter, while insertions stop once that capacity is reached.

### sw-diagonal

This is a first go at intra-alignment parallelism.
The code uses the usual anti-diagonal formulation to allow threads to calculate independently one or more cells on the current diagonal using the previous two diagonals.

There is an equivalent CPU implementation in `sw_diagonal_cpu.c`.
The CPU implementation is faster for shorter targets and queries, though the GPU implementations starts to overtake with longer (10k+) sequences.
Until that is, we exhaust the block-local storage and the kernel fails.

The diagonal program uses semiglobal scoring.
A matching base scores `+8`, a mismatch scores `0`, and insertion and deletion score `-2`.
Leading and trailing gaps are free.
The reported score is therefore the best score ending on either the final target column or the final query row.

Cells on one anti-diagonal do not depend on one another.
The kernel therefore keeps three rotating diagonal buffers in shared memory: the current diagonal, the preceding diagonal, and the diagonal before that.
A block-wide synchronisation is required after each diagonal before the buffers can rotate.

The program runs the same recurrence through `sw_diagonal_cpu.c` after the CUDA kernel.
The CPU code includes SSE4 and AVX2 implementations.
The two printed scores should agree.
GPU timing uses CUDA events around the kernel; CPU timing uses a monotonic wall clock.

#### Shared-memory limit

The kernel has one block and uses three `int` buffers whose length is the shorter sequence length.
Its dynamic shared-memory request is therefore:

```text
3 * min(target length, query length) * sizeof(int)
```

So for a query of 8000 characters this is about 96 KiB.
That is more than the per-block shared-memory allowance on many GPUs, so CUDA rejects the launch with an `invalid argument` error.
Keeping the shorter sequence at 1024 uses 12 KiB and fits comfortably on typical devices.

### sw-tiled

`sw-tiled` is a tiled implementation where each thread block computes a tile of the DP matrix.
For each tile the kernel follows the same anti-diagonal scheme, albeit we have to handle passing the boundary conditions from one tile to the next.

Tiles on the same tile anti-diagonal can run in different CUDA blocks.
The program launches one kernel for each tile wave, using the end of a kernel launch as a global synchronisation point.

This works around the shared-memory limits and creates enough independent work for a GPU to be useful.
It enables 100k x 100k alignments to be computed in under a second, compared to 20 seconds on CPU (or around 11 seconds for the AVX2 version).

The `--no-cpu` to skip the reference CPU alignment and measure only the tiled GPU implementation.
(This isn't a fair test in some ways as the CPU implementation is not tiled and threaded).

The table below shows timings for median-of-seven run with `--del-rate 5 --ins-rate 5 --sub-rate 3` and different target and query legnths, on two different machine configurations.

+---------------+--------------+---------+---------------+---------------+
| target length | query length | machine | cpu time / ms | gpu time / ms |
+---------------+--------------+---------+---------------+---------------+
|         1,024 |        1,024 | macOS   |         0.289 |         3.089 |
|               |              | linux   |         0.295 |         1.764 |
+---------------+--------------+---------+---------------+- -------------+
|        10,000 |       10,000 | macOS   |        25.976 |         3.778 |
|               |              | linux   |        19.121 |        16.743 |
+---------------+--------------+---------+---------------+---------------+
|       100,000 |      100,000 | macOS   |     2,657.221 |         5.051 |
|               |              | linux   |     2,022.695 |       199.967 |
+---------------+--------------+---------+---------------+---------------+
|     1,000,000 |      100,000 | macOS   |    26,113.945 |        12.937 |
|               |              | linux   |    25,874.395 |     1,316.068 |
+---------------+--------------+---------+---------------+---------------+

The macOS machine is surprisingly capable; the way the kernel launches and waves are setup currently clearly don't lend themselves to the NVIDIA GPU on the linux host.
(Note: the AVX2 kernel benefits greatly from having the match loop vectorised, which is the gnarliest of the operations to vectorise).