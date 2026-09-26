#include "common.h"
#include "cuda_utils.h"
#include "sw_diagonal_cpu.h"
#include "sw_tiled.h"
#include "sw_tiled_args.h"

#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

/*
 * The DP matrix is divided into tiles. A tile wave contains tiles with the
 * same row + column, so all blocks in one wave are independent:
 *
 *                 tile_column (target) ->
 *              0             1             2
 *            +--------------+--------------+--------------+
 * tile_row 0 | (0,0) wave 0 | (0,1) wave 1 | (0,2) wave 2 |
 * (query)    +--------------+-------------+--------------+
 *          1 | (1,0) wave 1 | (1,1) wave 2 | (1,2) wave 3 |
 *            +--------------+--------------+--------------+
 *
 * For a launch, blockIdx.x selects a row in the current wave:
 *
 *   tile_row    = first_tile_row + blockIdx.x
 *   tile_column = tile_wave - tile_row
 *   tile_id     = tile_row * tile_grid_columns + tile_column
 *
 * A tile's top and left boundaries come from the tile above and tile to the
 * left. The tile above-left supplies the corner value.
 */
__global__ void sw_tiled_kernel(
    const char *target_sequence, int target_length,
    const char *query_sequence, int query_length,
    int tile_size, int tile_grid_rows, int tile_grid_columns,
    int first_tile_row, int tile_wave,
    int *bottom_boundaries,
    int *right_boundaries,
    int *tile_scores)
{
    // One block computes one tile. Boundary pools use tile_size entries per tile.
    (void)tile_grid_rows;
    const int m_score = 8;
    const int d_score = -2;
    const int i_score = -2;
    const int e_score = 0;

    // the tile we are processing
    const int tile_row = first_tile_row + blockIdx.x;
    const int tile_column = tile_wave - tile_row;
    const size_t tile_id = (size_t)tile_row * tile_grid_columns + tile_column;

    // neighbouring tiles from which this tile will get its boundary values
    // above
    const size_t above_tile_id = tile_id - tile_grid_columns;
    const int *top_boundary = tile_row > 0
        ? &bottom_boundaries[above_tile_id * (size_t)tile_size]
        : NULL;

    // left
    const size_t left_tile_id = tile_id - 1;
    const int *left_boundary = tile_column > 0
        ? &right_boundaries[left_tile_id * (size_t)tile_size]
        : NULL;

    // above-left
    const size_t above_left_tile_id = tile_id - tile_grid_columns - 1;
    const int diagonal_boundary = tile_row > 0 && tile_column > 0
        ? tile_scores[above_left_tile_id]
        : e_score;

    // the start indices and dimensions of the tile
    const int query_start = tile_row * tile_size;
    const int target_start = tile_column * tile_size;
    const int tile_height = min(tile_size, query_length - query_start);
    const int tile_width = min(tile_size, target_length - target_start);

    // storage for the diagonals of the current tile, same as in sw_diagonal
    extern __shared__ int diagonal_storage[];
    const int max_diagonal_cells = min(tile_height, tile_width);
    int *previous_previous = diagonal_storage;
    int *previous = previous_previous + tile_size;
    int *current = previous + tile_size;
    for (int k = threadIdx.x; k < max_diagonal_cells; k += blockDim.x) {
        previous_previous[k] = e_score;
        previous[k] = e_score;
        current[k] = e_score;
    }
    __syncthreads();

    // off we go, this is all pretty much same as before, just our indices are relative
    //    to the tile and our boundary conditions come from neighbours
    const int n_diagonals = tile_height + tile_width - 1;
    for (int d = 0; d < n_diagonals; ++d) {
        const int i_min = max(0, d - tile_width + 1);
        const int i_max = min(d, tile_height - 1);
        const int n_cells = i_max - i_min + 1;
        const int previous_i_min = max(0, d - tile_width);
        const int previous_previous_i_min = max(0, d - tile_width - 1);

        for (int k = threadIdx.x; k < n_cells; k += blockDim.x) {
            const int i = i_min + k;
            const int j = d - i;
            const int query_index = query_start + i;
            const int target_index = target_start + j;
            const int match = target_sequence[target_index] == query_sequence[query_index]
                ? m_score
                : 0;
            const int deletion = i > 0
                ? previous[i - 1 - previous_i_min] + d_score
                : (top_boundary != NULL ? top_boundary[j] + d_score : e_score);
            const int insertion = j > 0
                ? previous[i - previous_i_min] + i_score
                : (left_boundary != NULL ? left_boundary[i] + i_score : e_score);

            int diagonal_value = e_score;
            if (i > 0 && j > 0) {
                diagonal_value = previous_previous[i - 1 - previous_previous_i_min];
            } else if (i == 0 && j == 0) {
                diagonal_value = diagonal_boundary;
            } else if (i == 0 && top_boundary != NULL) {
                diagonal_value = top_boundary[j - 1];
            } else if (j == 0 && left_boundary != NULL) {
                diagonal_value = left_boundary[i - 1];
            }

            const int value = max(diagonal_value + match,
                max(deletion, insertion));
            current[k] = value;
            if (i == tile_height - 1) {
                bottom_boundaries[tile_id * (size_t)tile_size + j] = value;
            }
            if (j == tile_width - 1) {
                right_boundaries[tile_id * (size_t)tile_size + i] = value;
            }
            if (i == tile_height - 1 && j == tile_width - 1) {
                tile_scores[tile_id] = value;
            }
        }

        __syncthreads();
        int *temporary = previous_previous;
        previous_previous = previous;
        previous = current;
        current = temporary;
        __syncthreads();
    }
}

int sw_tiled_score(
    const char *target_sequence, int target_length,
    const char *query_sequence, int query_length,
    int tile_size, int threads_per_block, float *gpu_milliseconds)
{
    if (target_length <= 0 || query_length <= 0 || tile_size <= 0
        || threads_per_block <= 0) {
        if (gpu_milliseconds != NULL) {
            *gpu_milliseconds = 0.0f;
        }
        return 0;
    }

    const int target_tiles = 1 + (target_length - 1) / tile_size;
    const int query_tiles = 1 + (query_length - 1) / tile_size;
    const int tile_diagonals = target_tiles + query_tiles - 1;
    const size_t tile_count = (size_t)target_tiles * query_tiles;
    const size_t boundary_cells = tile_count * tile_size;

    int *bottom_boundaries = NULL;
    int *right_boundaries = NULL;
    int *tile_scores = NULL;
    CHECK_CUDA(cudaMallocManaged(
        &bottom_boundaries, boundary_cells * sizeof(*bottom_boundaries)));
    CHECK_CUDA(cudaMallocManaged(
        &right_boundaries, boundary_cells * sizeof(*right_boundaries)));
    CHECK_CUDA(cudaMallocManaged(
        &tile_scores, tile_count * sizeof(*tile_scores)));

    const char *device_target_sequence = CUDA_DEVICE_POINTER(target_sequence);
    const char *device_query_sequence = CUDA_DEVICE_POINTER(query_sequence);
    int *device_bottom_boundaries = CUDA_DEVICE_POINTER(bottom_boundaries);
    int *device_right_boundaries = CUDA_DEVICE_POINTER(right_boundaries);
    int *device_tile_scores = CUDA_DEVICE_POINTER(tile_scores);

    cudaEvent_t gpu_start;
    cudaEvent_t gpu_end;
    CHECK_CUDA(cudaEventCreate(&gpu_start));
    CHECK_CUDA(cudaEventCreate(&gpu_end));
    CHECK_CUDA(cudaEventRecord(gpu_start));

    for (int wave = 0; wave < tile_diagonals; ++wave) {
        const int first_tile_row = max_int(0, wave - (target_tiles - 1));
        const int last_tile_row = min_int(wave, query_tiles - 1);
        const int blocks = last_tile_row - first_tile_row + 1;
        const size_t shared_bytes = 3 * (size_t)tile_size * sizeof(int);
        sw_tiled_kernel<<<blocks, threads_per_block, shared_bytes>>>(
            device_target_sequence, target_length,
            device_query_sequence, query_length,
            tile_size, query_tiles, target_tiles, first_tile_row, wave,
            device_bottom_boundaries, device_right_boundaries,
            device_tile_scores);
        CHECK_CUDA(cudaGetLastError());
    }

    CHECK_CUDA(cudaEventRecord(gpu_end));
    CHECK_CUDA(cudaEventSynchronize(gpu_end));
    if (gpu_milliseconds != NULL) {
        CHECK_CUDA(cudaEventElapsedTime(gpu_milliseconds, gpu_start, gpu_end));
    }

    // the best alignment reaches the end of either input sequence. Those candidate
    // cells are on the bottom edge of the final query tile row or the right edge
    // of the final target tile column.
    int score = 0;
    const int final_tile_row = query_tiles - 1;
    const int final_tile_height = min_int(
        tile_size, query_length - final_tile_row * tile_size);

    // scan the bottom edge of every tile in the final query row. Each tile's
    // bottom boundary stores one value for each target column in that tile.
    for (int tile_column = 0; tile_column < target_tiles; ++tile_column) {
        const size_t tile_id = (size_t)final_tile_row * target_tiles + tile_column;
        const int tile_width = min_int(
            tile_size, target_length - tile_column * tile_size);
        for (int j = 0; j < tile_width; ++j) {
            score = max_int(
                score, bottom_boundaries[tile_id * (size_t)tile_size + j]);
        }
    }

    // the bottom-right tile also contributes its right edge, which contains
    // the remaining cells in the final query rows. Together these scans cover
    // the complete bottom row and rightmost column of the DP matrix.
    const size_t final_tile_id = (size_t)final_tile_row * target_tiles + target_tiles - 1;
    for (int i = 0; i < final_tile_height; ++i) {
        score = max_int(
            score, right_boundaries[final_tile_id * (size_t)tile_size + i]);
    }

    CHECK_CUDA(cudaEventDestroy(gpu_end));
    CHECK_CUDA(cudaEventDestroy(gpu_start));
    CHECK_CUDA(CUDA_MANAGED_FREE(bottom_boundaries));
    CHECK_CUDA(CUDA_MANAGED_FREE(right_boundaries));
    CHECK_CUDA(CUDA_MANAGED_FREE(tile_scores));
    return score;
}

int run_sw_tiled(int argc, char **argv)
{
    sw_tiled_arguments_t arguments;
    if (sw_tiled_parse_arguments(argc, argv, &arguments) != 0) {
        return EXIT_FAILURE;
    }
    if (arguments.target_length > INT_MAX || arguments.query_length > INT_MAX || arguments.tile_size > INT_MAX) {
        fprintf(stderr, "sequence lengths and tile size must not exceed %d\n", INT_MAX);
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
    CHECK_CUDA(cudaMallocManaged(
        &target_sequence, (size_t)target_length * sizeof(*target_sequence)));
    CHECK_CUDA(cudaMallocManaged(
        &query_sequence, (size_t)max_query_length * sizeof(*query_sequence)));

    uint32_t state = arguments.random_seed;
    generate_sequence(target_sequence, target_length, &state);
    const int query_length = (int)simulate_sequence(
        target_sequence, target_length, query_sequence, max_query_length,
        arguments.sub_rate, arguments.ins_rate, arguments.del_rate, &state);

    const int tile_size = (int)arguments.tile_size;
    const int target_tiles = 1 + (target_length - 1) / tile_size;
    const int query_tiles = 1 + (query_length - 1) / tile_size;
    const int tile_diagonals = target_tiles + query_tiles - 1;

    printf("target length: %d\n", target_length);
    printf("query length: %d\n", query_length);
    printf("tile size: %d x %d\n", tile_size, tile_size);
    printf("tile grid: %d x %d\n", query_tiles, target_tiles);
    printf("tile anti-diagonals: %d\n", tile_diagonals);

    if (arguments.run_cpu) {
        struct timespec cpu_start;
        struct timespec cpu_end;
        clock_gettime(CLOCK_MONOTONIC, &cpu_start);
        const int cpu_score = sw_diagonal_cpu_score(
            target_sequence, target_length, query_sequence, query_length);
        clock_gettime(CLOCK_MONOTONIC, &cpu_end);
        const double cpu_milliseconds = 1000.0 * (double)(cpu_end.tv_sec - cpu_start.tv_sec)
            + (double)(cpu_end.tv_nsec - cpu_start.tv_nsec) / 1.0e6;
        printf("cpu score: %d (%.3f ms)\n",
            cpu_score, cpu_milliseconds);
    }

    float gpu_milliseconds = 0.0f;
    const int tiled_score = sw_tiled_score(
        target_sequence, target_length, query_sequence, query_length,
        tile_size, (int)arguments.threads_per_block, &gpu_milliseconds);
    printf("tiled GPU time: %.3f ms\n", gpu_milliseconds);
    printf("tiled score: %d\n", tiled_score);

    CHECK_CUDA(CUDA_MANAGED_FREE(target_sequence));
    CHECK_CUDA(CUDA_MANAGED_FREE(query_sequence));
    return EXIT_SUCCESS;
}
