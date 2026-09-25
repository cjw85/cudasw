#ifndef SW_NAIVE_H
#define SW_NAIVE_H

#include <stdint.h>

int run_sw_naive(int argc, char** argv);

__global__ void sw_naive_kernel(
    const char* targets, const int* target_lengths,
    const char* queries, const int* query_lengths,
    uint32_t* scores,
    int n_targets, int n_generated_queries, int target_length);

#endif // SW_NAIVE_H
