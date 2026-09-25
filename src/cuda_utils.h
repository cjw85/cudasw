#ifndef CUDA_UTILS_H
#define CUDA_UTILS_H

#include <stdio.h>
#include <stdlib.h>

#include <cuda_runtime.h>

static inline void cuda_check(cudaError_t status, const char* expression)
{
    if (status == cudaSuccess) {
        return;
    }

    fprintf(stderr, "CUDA error in %s: %s\n", expression, cudaGetErrorString(status));
    exit(EXIT_FAILURE);
}

#define CHECK_CUDA(expression) cuda_check((expression), #expression)

#endif
