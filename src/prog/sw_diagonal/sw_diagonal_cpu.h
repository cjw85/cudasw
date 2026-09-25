#ifndef CUDA_SW_DIAGONAL_CPU_H
#define CUDA_SW_DIAGONAL_CPU_H

int sw_diagonal_cpu_score(
    const char* target_sequence, int target_length,
    const char* query_sequence, int query_length);

#endif
