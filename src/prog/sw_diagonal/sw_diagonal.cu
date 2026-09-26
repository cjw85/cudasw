#include "common.h"
#include "cuda_utils.h"
#include "sw_diagonal.h"
#include "sw_diagonal_args.h"
#include "sw_diagonal_cpu.h"

#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

// This is a simple one block design for processing all anti-diagonals of the matrix,
// it allows us to process each anti-diagonal in parallel and sync the threads within
// the block when the whole anti-diagonal is processed.
// The kernel starts to beat CPU for longer target sequences, but ultimately fails
// when we hit per-block shared memory limits: 3 x diag cells x 4 bytes
__global__ void sw_diagonal_kernel(
    const char *target_sequence, int target_length,
    const char *query_sequence, int query_length,
    int *score)
{

    const int32_t m_score = 8;
    const int32_t d_score = -2;
    const int32_t i_score = -2;
    const int32_t e_score = 0;
    __shared__ int best_score;
    int thread_best_score = e_score;

    // Initialise all three rotating diagonal buffers. Every thread must
    // reach every barrier below.
    extern __shared__ int diagonal_storage[];
    const int max_diagonal_cells = min(target_length, query_length);
    int *previous_previous = diagonal_storage;
    int *previous = previous_previous + max_diagonal_cells;
    int *current = previous + max_diagonal_cells;

    if (threadIdx.x == 0) {
        best_score = e_score;
    }
    for (int k = threadIdx.x; k < max_diagonal_cells; k += blockDim.x) {
        previous_previous[k] = 0;
        previous[k] = 0;
        current[k] = 0;
    }
    __syncthreads();

    const int n_diagonals = target_length + query_length - 1;
    for (int d = 0; d < n_diagonals; ++d) {
        // i - query row
        // j - target column.
        // Every cell on this anti-diagonal has i + j == d.
        const int i_min = max(0, d - target_length + 1);
        const int i_max = min(d, query_length - 1);
        const int n_cells = i_max - i_min + 1;

        // Threads cooperatively cover the diagonal. If it is longer than the
        // block, each thread processes multiple positions with this stride.
        for (int k = threadIdx.x; k < n_cells; k += blockDim.x) {
            const int i = i_min + k;
            const int j = d - i;
            const int previous_i_min = max(0, d - target_length);
            const int previous_previous_i_min = max(0, d - target_length - 1);
            const int match = target_sequence[j] == query_sequence[i] ? m_score : 0;
            const int deletion = i > 0
                ? previous[i - 1 - previous_i_min] + d_score
                : e_score;
            const int insertion = j > 0
                ? previous[i - previous_i_min] + i_score
                : e_score;
            const int diagonal = i > 0 && j > 0
                ? match + previous_previous[i - 1 - previous_previous_i_min]
                : match + e_score;

            current[k] = max(diagonal, max(deletion, insertion));
            if (i == query_length - 1 || j == target_length - 1) {
                thread_best_score = max(thread_best_score, current[k]);
            }
        }

        // All current diagonal values must be written before they become a
        // previous diagonal for the next iteration.
        __syncthreads();

        int *temporary = previous_previous;
        previous_previous = previous;
        previous = current;
        current = temporary;

        // All threads must observe the rotated pointers before the next
        // diagonal starts writing into the reused buffer.
        __syncthreads();
    }

    atomicMax(&best_score, thread_best_score);
    __syncthreads();
    if (threadIdx.x == 0) {
        *score = best_score;
    }
}

int run_sw_diagonal(int argc, char **argv)
{
    sw_diagonal_arguments_t arguments;
    if (sw_diagonal_parse_arguments(argc, argv, &arguments) != 0) {
        return EXIT_FAILURE;
    }
    if (arguments.target_length > INT_MAX || arguments.query_length > INT_MAX) {
        fprintf(stderr, "sequence lengths must not exceed %d\n", INT_MAX);
        return EXIT_FAILURE;
    }

    const int target_length = (int)arguments.target_length;
    const int max_query_length = (int)arguments.query_length;
    if (target_length > INT_MAX - max_query_length + 1) {
        fprintf(stderr, "combined sequence length is too large\n");
        return EXIT_FAILURE;
    }

    char *target_sequence = NULL;
    char *query_sequence = NULL;
    int *score = NULL;
    uint32_t state = arguments.random_seed;
    CHECK_CUDA(cudaMallocManaged(&target_sequence, target_length * sizeof(char)));
    CHECK_CUDA(cudaMallocManaged(&query_sequence, max_query_length * sizeof(char)));
    CHECK_CUDA(cudaMallocManaged(&score, sizeof(*score)));

    generate_sequence(target_sequence, target_length, &state);
    printf("target length: %d\n", target_length);
    // printf("target: %.*s\n", target_length, target_sequence);

    const int query_length = (int)simulate_sequence(
        target_sequence, target_length,
        query_sequence, max_query_length,
        arguments.sub_rate, arguments.ins_rate, arguments.del_rate, &state);

    printf("query length: %d\n", query_length);
    // printf("query: %.*s\n", query_length, query_sequence);

    const int n_diagonals = query_length + target_length - 1;
    const int max_cells_per_diagonal = min_int(query_length, target_length);

    printf("anti-diagonals: %d\n", n_diagonals);
    printf("maximum cells on one anti-diagonal: %d\n", max_cells_per_diagonal);
    printf("threads per diagonal group: %zu\n", arguments.threads_per_block);
    printf("blocks per anti-diagonal: 1\n");

    size_t shared_bytes = 3 * (size_t)max_cells_per_diagonal * sizeof(int);
    cudaEvent_t gpu_start;
    cudaEvent_t gpu_end;
    CHECK_CUDA(cudaEventCreate(&gpu_start));
    CHECK_CUDA(cudaEventCreate(&gpu_end));
    CHECK_CUDA(cudaEventRecord(gpu_start));
    const char *device_target_sequence = CUDA_DEVICE_POINTER(target_sequence);
    const char *device_query_sequence = CUDA_DEVICE_POINTER(query_sequence);
    int *device_score = CUDA_DEVICE_POINTER(score);
    sw_diagonal_kernel<<<1, arguments.threads_per_block, shared_bytes>>>(
        device_target_sequence, target_length,
        device_query_sequence, query_length, device_score);

    CHECK_CUDA(cudaGetLastError());
    CHECK_CUDA(cudaEventRecord(gpu_end));
    CHECK_CUDA(cudaEventSynchronize(gpu_end));
    float gpu_milliseconds = 0.0f;
    CHECK_CUDA(cudaEventElapsedTime(&gpu_milliseconds, gpu_start, gpu_end));
    printf("score: %d (%.3f ms)\n", *score, gpu_milliseconds);

    const clock_t cpu_start = clock();
    const int cpu_score = sw_diagonal_cpu_score(
        target_sequence, target_length, query_sequence, query_length);
    const double cpu_milliseconds = 1000.0 * (double)(clock() - cpu_start) / CLOCKS_PER_SEC;
    printf("cpu score: %d (%.3f ms)\n", cpu_score, cpu_milliseconds);

    CHECK_CUDA(cudaEventDestroy(gpu_end));
    CHECK_CUDA(cudaEventDestroy(gpu_start));
    CHECK_CUDA(CUDA_MANAGED_FREE(score));
    CHECK_CUDA(CUDA_MANAGED_FREE(target_sequence));
    CHECK_CUDA(CUDA_MANAGED_FREE(query_sequence));

    return EXIT_SUCCESS;
}
