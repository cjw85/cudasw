#ifndef SW_TILED_H
#define SW_TILED_H

#ifdef __cplusplus
extern "C" {
#endif

int run_sw_tiled(int argc, char **argv);
int sw_tiled_score(
    const char *target_sequence, int target_length,
    const char *query_sequence, int query_length,
    int tile_size, int threads_per_block, float *gpu_milliseconds);

#ifdef __cplusplus
}
#endif

#ifdef __CUDACC__
__global__ void sw_tiled_kernel(
    const char *target_sequence, int target_length,
    const char *query_sequence, int query_length,
    int tile_size, int tile_grid_rows, int tile_grid_columns,
    int first_tile_row, int tile_wave,
    int *bottom_boundaries, int *right_boundaries, int *tile_scores);
#endif

#endif
