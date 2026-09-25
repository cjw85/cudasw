// Implementation of the Smith-Waterman batch operation.

#include "cuda_utils.h"
#include "common.h"

#include <stdio.h>
#include <stdint.h>
#include <inttypes.h>

#include "sw_naive_args.h"
#include "sw_naive.h"


__global__ void sw_naive_kernel(
    const char* targets, const int* target_lengths,
    const char* queries, const int* query_lengths,
    uint32_t* scores,
    int n_targets, int n_generated_queries, int target_length)
{
    const int index = blockIdx.x * blockDim.x + threadIdx.x;
    if (index >= n_targets * n_generated_queries) {
        return;
    }
    const int target_idx = index / n_generated_queries;
    const int query_idx = index % n_generated_queries;
    const char* target = &targets[target_idx * target_length];
    const char* query = &queries[query_idx * target_length];
    const int actual_target_length = target_lengths[target_idx];
    const int query_length = query_lengths[query_idx];

    // Semiglobal alignment: leading and trailing end gaps are free. Each
    // thread is responsible for one target-query pair.
    int32_t m_score = 8;  // match score
    int32_t d_score = -2;  // deletion score
    int32_t i_score = -2;  // insertion score
    int32_t e_score = 0;  // free end-gap score

    // Each thread owns two fixed-size rows. Only the first actual_target_length
    // entries are used, so shorter runtime targets do less work
    // yes this is quite naive way of doing things, but we're learning
    int32_t prev_storage[SW_NAIVE_MAX_TARGET_LENGTH];
    int32_t curr_storage[SW_NAIVE_MAX_TARGET_LENGTH];
    int32_t* prev = prev_storage;
    int32_t* curr = curr_storage;
    for (int ti = 0; ti < actual_target_length; ++ti) {
        prev[ti] = e_score;
        curr[ti] = e_score;
    }

    int32_t best_end_score = e_score;
    for (int qi = 0; qi < query_length; ++qi) {
        // The first column is a free leading gap in the target.
        curr[0] = e_score;
        for (size_t ti = 0; ti < actual_target_length; ++ti) {
            int32_t match = (target[ti] == query[qi]) ? m_score : 0;
            int32_t diag = (ti > 0 ? prev[ti - 1] : e_score) + match;
            int32_t del = prev[ti] + d_score;
            int32_t ins = (ti > 0 ? curr[ti - 1] : e_score) + i_score;
            curr[ti] = max(diag, max(del, ins));
        }

        // The last target column is a free trailing gap in the target.
        best_end_score = max(best_end_score, curr[actual_target_length - 1]);

        int32_t* temp = prev;
        prev = curr;
        curr = temp;
    }

    // The final query row is a free trailing gap in the query.
    for (int ti = 0; ti < actual_target_length; ++ti) {
        best_end_score = max(best_end_score, prev[ti]);
    }

    scores[index] = best_end_score;
}


int run_sw_naive(int argc, char** argv)
{
    sw_naive_arguments_t arguments;
    if (sw_naive_parse_arguments(argc, argv, &arguments) != 0) {
        return EXIT_FAILURE;
    }

    // create target sequences
    char* targets = NULL;
    int* target_lengths = NULL;
    size_t bytes = arguments.n_targets * arguments.target_length * sizeof(char);
    CHECK_CUDA(cudaMallocManaged(&targets, bytes));
    CHECK_CUDA(cudaMallocManaged(&target_lengths,
                                 arguments.n_targets * sizeof(int)));
    
    // fill target sequences with random bases
    uint32_t state = arguments.seed;
    size_t min_target_length = (arguments.target_length * 80) / 100;
    if (min_target_length == 0) {
        min_target_length = 1;
    }
    size_t target_length_span = arguments.target_length - min_target_length + 1;
    for (size_t i = 0; i < arguments.n_targets; ++i) {
        size_t target_length = min_target_length;
        if (target_length_span > 1) {
            target_length += xorshift32(&state) % target_length_span;
        }
        target_lengths[i] = (int)target_length;
        for (size_t j = 0; j < arguments.target_length; ++j) {
            targets[i * arguments.target_length + j] = 'N';
        }
        for (size_t j = 0; j < target_length; ++j) {
            targets[i * arguments.target_length + j] = random_base(&state);
        }
    }
    
    // create query sequences
    char* queries = NULL;
    int* query_lengths = NULL;
    size_t n_generated_queries =
        arguments.n_targets * arguments.n_queries_per_target;
    size_t query_bytes = n_generated_queries * arguments.target_length * sizeof(char);
    CHECK_CUDA(cudaMallocManaged(&queries, query_bytes));
    CHECK_CUDA(cudaMallocManaged(&query_lengths, n_generated_queries * sizeof(int)));

    // For each target sequence, create N fixed-capacity query buffers.
    for (size_t i = 0; i < arguments.n_targets; ++i) {
        for (size_t j = 0; j < arguments.n_queries_per_target; ++j) {
            char* query = &queries[(i * arguments.n_queries_per_target + j) *
                                   arguments.target_length];
            for (size_t k = 0; k < arguments.target_length; ++k) {
                query[k] = 'N';
            }
            size_t query_length = simulate_sequence(
                &targets[i * arguments.target_length], target_lengths[i],
                query, arguments.target_length, arguments.sub_rate,
                arguments.ins_rate, arguments.del_rate, &state);
            query_lengths[i * arguments.n_queries_per_target + j] = (int)query_length;
        }
    }

    // each cuda thread will handle one sequence pair (target, query)
    size_t n_alignments = n_generated_queries * arguments.n_targets;
    size_t blocks =
        (n_alignments + arguments.threads_per_block - 1) /
        arguments.threads_per_block;
    uint32_t* scores;
    CHECK_CUDA(cudaMallocManaged(&scores, n_alignments * sizeof(uint32_t)));
    // launch the CUDA kernel to compute Smith-Waterman scores
    sw_naive_kernel<<<blocks, arguments.threads_per_block>>>(
        targets, target_lengths, queries,
        query_lengths, scores,
        arguments.n_targets, n_generated_queries, arguments.target_length);
    CHECK_CUDA(cudaGetLastError());
    CHECK_CUDA(cudaDeviceSynchronize());

    // get best score for each query and associate it with its target
    // given how we generated the sequences, this should come out in
    // blocks of queries corresponding to each target sequence
    uint32_t best_score[n_generated_queries] = {0};
    uint32_t best_target[n_generated_queries] = {0};
    for (size_t t_index = 0; t_index < arguments.n_targets; ++t_index) {
        for (size_t q_index = 0; q_index < n_generated_queries; ++q_index) {
            size_t index = t_index * n_generated_queries + q_index;
            if (scores[index] > best_score[q_index]) {
                best_score[q_index] = scores[index];
                best_target[q_index] = t_index;
            }
        }
    }
    for (size_t q_index = 0; q_index < n_generated_queries; ++q_index) {
        size_t source_target = q_index / arguments.n_queries_per_target;
        printf(
            "Query %zu (length %d); Target %" PRIu32 "; Correct target %zu (length %d)\n",
            q_index, query_lengths[q_index], best_target[q_index], source_target,
            target_lengths[source_target]);
    }

    // free allocated memory
    CHECK_CUDA(cudaFree(targets));
    CHECK_CUDA(cudaFree(target_lengths));
    CHECK_CUDA(cudaFree(queries));
    CHECK_CUDA(cudaFree(query_lengths));
    CHECK_CUDA(cudaFree(scores));

    return EXIT_SUCCESS;
}
