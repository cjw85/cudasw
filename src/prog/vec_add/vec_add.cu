#include "cuda_utils.h"
#include "vec_add.h"
#include "vec_add_args.h"

__global__ void add_vectors(const float *a, const float *b, float *result, int length)
{
    const int index = blockIdx.x * blockDim.x + threadIdx.x;
    if (index < length) {
        result[index] = a[index] + b[index];
    }
}

__global__ void multiply_vectors(const float *a, const float *b, float *result, int length)
{
    const int index = blockIdx.x * blockDim.x + threadIdx.x;
    if (index < length) {
        result[index] = a[index] * b[index];
    }
}

int run_vec_add(int argc, char **argv)
{
    vec_add_arguments_t arguments;
    if (vec_add_parse_arguments(argc, argv, &arguments) != 0) {
        return EXIT_FAILURE;
    }

    float *a = NULL;
    float *b = NULL;
    float *result = NULL;
    const size_t bytes = arguments.vector_length * sizeof(*a);

    // Managed allocations are accessible from both the CPU and GPU.
    CHECK_CUDA(cudaMallocManaged(&a, bytes));
    CHECK_CUDA(cudaMallocManaged(&b, bytes));
    CHECK_CUDA(cudaMallocManaged(&result, bytes));

    for (int index = 0; index < arguments.vector_length; ++index) {
        a[index] = (float)index;
        b[index] = arguments.b_value;
    }

    const int blocks = (arguments.vector_length + arguments.threads_per_block - 1) / arguments.threads_per_block;
    if (strcmp(arguments.operation, "add") == 0) {
        add_vectors<<<blocks, arguments.threads_per_block>>>(a, b, result, arguments.vector_length);
    } else {
        multiply_vectors<<<blocks, arguments.threads_per_block>>>(a, b, result, arguments.vector_length);
    }
    CHECK_CUDA(cudaGetLastError());
    CHECK_CUDA(cudaDeviceSynchronize());

    printf("operation = %s\n", arguments.operation);
    for (int index = 0; index < arguments.vector_length; ++index) {
        printf("result[%d] = %.0f\n", index, result[index]);
    }

    CHECK_CUDA(cudaFree(result));
    CHECK_CUDA(cudaFree(b));
    CHECK_CUDA(cudaFree(a));
    return EXIT_SUCCESS;
}
