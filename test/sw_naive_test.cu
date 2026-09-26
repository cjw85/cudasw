#include "cuda_utils.h"
#include "sw_naive.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(void)
{
    const int n_targets = 2;
    const int n_queries = 3;
    const int capacity = 4;

    const char target_data[] = "ACGTAAAA";
    const char query_data[] = "ACGTCGNNNNNNNN";
    const int target_lengths[] = { 4, 4 };
    const int query_lengths[] = { 4, 2, 0 };
    const uint32_t expected[] = { 32, 16, 0, 8, 0, 0 };

    char *targets = NULL;
    int *device_target_lengths = NULL;
    char *queries = NULL;
    int *device_query_lengths = NULL;
    uint32_t *scores = NULL;
    CHECK_CUDA(cudaMallocManaged(&targets, n_targets * capacity));
    CHECK_CUDA(cudaMallocManaged(&device_target_lengths, n_targets * sizeof(int)));
    CHECK_CUDA(cudaMallocManaged(&queries, n_queries * capacity));
    CHECK_CUDA(cudaMallocManaged(&device_query_lengths, n_queries * sizeof(int)));
    CHECK_CUDA(cudaMallocManaged(&scores, n_targets * n_queries * sizeof(uint32_t)));

    memcpy(targets, target_data, n_targets * capacity);
    memcpy(device_target_lengths, target_lengths, n_targets * sizeof(int));
    memcpy(queries, query_data, n_queries * capacity);
    memcpy(device_query_lengths, query_lengths, n_queries * sizeof(int));

    char *device_targets = CUDA_DEVICE_POINTER(targets);
    int *device_target_lengths = CUDA_DEVICE_POINTER(device_target_lengths);
    char *device_queries = CUDA_DEVICE_POINTER(queries);
    int *device_query_lengths = CUDA_DEVICE_POINTER(device_query_lengths);
    uint32_t *device_scores = CUDA_DEVICE_POINTER(scores);
    sw_naive_kernel<<<1, n_targets * n_queries>>>(
        device_targets, device_target_lengths, device_queries,
        device_query_lengths, device_scores, n_targets, n_queries, capacity);
    CHECK_CUDA(cudaGetLastError());
    CHECK_CUDA(cudaDeviceSynchronize());

    int failures = 0;
    for (int i = 0; i < n_targets * n_queries; ++i) {
        if (scores[i] != expected[i]) {
            fprintf(stderr, "score[%d]: expected %u, got %u\n", i, expected[i], scores[i]);
            failures++;
        }
    }

    CHECK_CUDA(CUDA_MANAGED_FREE(targets));
    CHECK_CUDA(CUDA_MANAGED_FREE(device_target_lengths));
    CHECK_CUDA(CUDA_MANAGED_FREE(queries));
    CHECK_CUDA(CUDA_MANAGED_FREE(device_query_lengths));
    CHECK_CUDA(CUDA_MANAGED_FREE(scores));

    if (failures != 0) {
        printf("sw-naive deterministic test failed with %d failures\n", failures);
        return EXIT_FAILURE;
    }
    printf("sw-naive tests passed\n");
    return EXIT_SUCCESS;
}
