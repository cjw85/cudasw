#ifndef CUDA_UTILS_H
#define CUDA_UTILS_H

#include <cuda_runtime.h>
#include <stdio.h>
#include <stdlib.h>

static inline void cuda_check(cudaError_t status, const char *expression)
{
    if (status == cudaSuccess) {
        return;
    }

    fprintf(stderr, "CUDA error in %s: %s\n", expression, cudaGetErrorString(status));
    exit(EXIT_FAILURE);
}

#define CHECK_CUDA(expression) cuda_check((expression), #expression)

/* CUDA device pointer utility
 *
 * This utility provides a mechanism to obtain the corresponding device pointer
 * for a given host pointer, when using managed memory with CUDA.
 * When compiled with CUDASW_MVCC, it uses cudaHostGetDevicePointer
 * to retrieve the device pointer. Otherwise, it simply returns the host pointer.
 *
 * Alternatively we could stop being n00bs and not use managed memory at all,
 * and directly work with device pointers.
 */

#ifdef __cplusplus
template <typename T>
static inline T *cuda_device_pointer(T *host_pointer)
{
#ifdef CUDASW_MVCC
    void *device_pointer = NULL;
    cuda_check(
        cudaHostGetDevicePointer(&device_pointer,
            const_cast<void *>(static_cast<const void *>(host_pointer)), 0),
        "cudaHostGetDevicePointer");
    return static_cast<T *>(device_pointer);
#else
    return host_pointer;
#endif
}
#endif

#define CUDA_DEVICE_POINTER(pointer) cuda_device_pointer(pointer)

#ifdef CUDASW_MVCC
#define CUDA_MANAGED_FREE(pointer) cudaFreeHost(pointer)
#else
#define CUDA_MANAGED_FREE(pointer) cudaFree(pointer)
#endif

#endif
