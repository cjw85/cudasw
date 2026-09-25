#include "cuda_utils.h"
#include "sw_diagonal_cpu.h"
#include "sw_tiled.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int run_case(const char *name, int pattern)
{
    const int length = 1024;
    const int tile_size = 256;
    char target[length];
    char query[length];
    for (int i = 0; i < length; ++i) {
        if (pattern == 0) {
            target[i] = 'A';
            query[i] = 'A';
        } else if (pattern == 1) {
            target[i] = (i & 1) == 0 ? 'A' : 'T';
            query[i] = target[i];
        } else {
            target[i] = (i & 1) == 0 ? 'A' : 'T';
            query[i] = (i & 1) == 0 ? 'T' : 'A';
        }
    }
    int expected;
    if (pattern == 0) {
        expected = length * 8;
    } else if (pattern == 1) {
        expected = length * 8;
    } else {
        expected = (length - 1) * 8; // we lose one match
    }

    const int cpu_score = sw_diagonal_cpu_score(target, length, query, length);
    if (cpu_score != expected) {
        fprintf(stderr, "%s: expected %d, got %d\n", name, expected, cpu_score);
        return EXIT_FAILURE;
    }

    char *device_target = NULL;
    char *device_query = NULL;
    CHECK_CUDA(cudaMallocManaged(&device_target, length * sizeof(*device_target)));
    CHECK_CUDA(cudaMallocManaged(&device_query, length * sizeof(*device_query)));
    memcpy(device_target, target, length * sizeof(*device_target));
    memcpy(device_query, query, length * sizeof(*device_query));
    const int gpu_score = sw_tiled_score(
        device_target, length, device_query, length, tile_size, tile_size, NULL);
    CHECK_CUDA(cudaFree(device_target));
    CHECK_CUDA(cudaFree(device_query));
    if (gpu_score != expected) {
        fprintf(stderr, "%s: expected %d, got %d\n", name, expected, gpu_score);
        return EXIT_FAILURE;
    }

    return EXIT_SUCCESS;
}

int main(void)
{
    int failures = 0;
    failures += run_case("all matches", 0);
    failures += run_case("alternating AT", 1);
    failures += run_case("opposite alternating AT", 2);
    if (failures != 0) {
        fprintf(stderr, "sw-tiled tests failed with %d failures\n", failures);
        return EXIT_FAILURE;
    }
    printf("sw-tiled tests passed\n");
    return EXIT_SUCCESS;
}
