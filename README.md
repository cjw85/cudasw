# CUDA Smith-Waterman learning project

This project contains various dynamic programming kernels for sequence alignment.
Nothing here is terribly novel, its just me refreshing my CUDA skills.

## Build and run

On a Linux host with the CUDA Toolkit, NVIDIA driver, and a GPU:

```sh
make
make run
build/cudasw --help
build/cudasw vec-add
build/cudasw vec-add --operation multiply
build/cudasw sw-naive --n-targets 32 --target-length 1024 \
    --n-queries-per-target 32
```

Useful variants:

```sh
make BUILD_MODE=debug run  # -O0, host symbols, and CUDA device debug info
make help
make clean
```

## Experiments

Its a bit grand to call these experiments, given everything here is known and standard to anyone already in the game.

The presentation order below is simply the order I wrote the code.

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
The two printed scores should agree.
GPU timing uses CUDA events around the kernel; CPU timing uses `clock()`.

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

This works around the shared-memory limits and offers enough independent work for a GPU to be useful.
It enables 100k x 100k alignments to be computed in under a second, compared to 20 seconds on CPU (or around 11 seconds for the AVX2 version).