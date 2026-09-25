// Implementation of the Smith-Waterman batch operation.

#include "cuda_utils.h"

#include <stdio.h>
#include <stdint.h>

#include "sw_naive_args.h"
#include "sw_naive.h"


// dumb RNG
static inline uint32_t xorshift32(uint32_t *state)
{
    uint32_t x = *state;
    // we don't want to get to zero
    if (x == 0) {
        x = 0xDEADBEEF;
    }
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    if (x == 0) {
        x = 0xDEADBEEF;
    }
    *state = x;
    return x;
}


static char random_base(uint32_t *state)
{
    static const char bases[] = "ACGT";
    uint32_t value = xorshift32(state);
    return bases[value >> 30];  // top two bits: 0..3
}


__global__ void sw_naive_kernel(
    const char* targets, const char* queries, uint32_t* scores,
    int n_targets, int n_queries, int target_length)
{
    const int index = blockIdx.x * blockDim.x + threadIdx.x;
    if (index >= n_targets * n_queries) {
        return;
    }
    const int target_idx = index / n_queries;
    const int query_idx = index % n_queries;
    const char* target = &targets[target_idx * target_length];
    const char* query = &queries[query_idx * target_length];

    // Semiglobal alignment: leading and trailing end gaps are free. Each
    // thread is responsible for one target-query pair.
    int32_t m_score = 8;  // match score
    int32_t d_score = -2;  // deletion score
    int32_t i_score = -2;  // insertion score
    int32_t e_score = 0;  // free end-gap score

    // Each thread owns two fixed-size rows. Only the first target_length
    // entries are used, so shorter runtime sequences do less work
    // yes this is quite naive way of doing things, but we're learning
    int32_t prev_storage[SW_BATCH_MAX_SEQUENCE_LENGTH];
    int32_t curr_storage[SW_BATCH_MAX_SEQUENCE_LENGTH];
    int32_t* prev = prev_storage;
    int32_t* curr = curr_storage;
    for (int ti = 0; ti < target_length; ++ti) {
        prev[ti] = e_score;
        curr[ti] = e_score;
    }

    int32_t best_end_score = e_score;
    for (size_t qi = 0; qi < target_length; ++qi) {
        // The first column is a free leading gap in the target.
        curr[0] = e_score;
        for (size_t ti = 0; ti < target_length; ++ti) {
            int32_t match = (target[ti] == query[qi]) ? m_score : 0;
            int32_t diag = (ti > 0 ? prev[ti - 1] : e_score) + match;
            int32_t del = prev[ti] + d_score;
            int32_t ins = (ti > 0 ? curr[ti - 1] : e_score) + i_score;
            curr[ti] = max(diag, max(del, ins));
        }

        // The last target column is a free trailing gap in the target.
        best_end_score = max(best_end_score, curr[target_length - 1]);

        int32_t* temp = prev;
        prev = curr;
        curr = temp;
    }

    // The final query row is a free trailing gap in the query.
    for (int ti = 0; ti < target_length; ++ti) {
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
    size_t bytes = arguments.n_targets * arguments.target_length * sizeof(char);
    CHECK_CUDA(cudaMallocManaged(&targets, bytes));
    
    // fill target sequences with random bases
    uint32_t state = arguments.seed;
    for (size_t i = 0; i < arguments.n_targets; ++i) {
        for (size_t j = 0; j < arguments.target_length; ++j) {
            targets[i * arguments.target_length + j] = random_base(&state);
        }
    }
    
    // create query sequences
    char* queries = NULL;
    size_t n_generated_queries =
        arguments.n_targets * arguments.n_queries_per_target;
    size_t query_bytes = n_generated_queries * arguments.target_length * sizeof(char);
    CHECK_CUDA(cudaMallocManaged(&queries, query_bytes));

    // for each target sequence, create N query sequences
    for (size_t i = 0; i < arguments.n_targets; ++i) {
        for (size_t j = 0; j < arguments.n_queries_per_target; ++j) {
            // introduce substitution errors with a small probability based on sub_rate
            for (size_t k = 0; k < arguments.target_length; ++k) {
                char base = targets[i * arguments.target_length + k];
                uint32_t random_byte = xorshift32(&state) >> 24;
                if (random_byte < (arguments.sub_rate * 256u) / 100u) {
                    char new_base;
                    do {
                        new_base = random_base(&state);
                    } while (new_base == base);
                    base = new_base;
                }
                queries[(i * arguments.n_queries_per_target + j) * arguments.target_length + k] = base;
            }
            // introduce deletions errors with a small probability based on del_rate
            // this isn't realistic, we're fudging things here just to keep lengths the same for simplicity
            for (size_t k = 0; k < arguments.target_length; ++k) {
                int del = (xorshift32(&state) >> 24) < (arguments.del_rate * 256u) / 100u ? 1 : 0;
                if (del) {
                    // shift the remaining sequence to the left by one position
                    memmove(&queries[(i * arguments.n_queries_per_target + j) * arguments.target_length + k],
                            &queries[(i * arguments.n_queries_per_target + j) * arguments.target_length + k + 1],
                            arguments.target_length - k - 1);
                    // fill the last position with a random base
                    queries[(i * arguments.n_queries_per_target + j) * arguments.target_length + arguments.target_length - 1] = random_base(&state);
                }
            }
            // introduce insertion errors with a small probability based on ins_rate
            // again we fudge things be dropping a base
            for (size_t k = 0; k < arguments.target_length; ++k) {
                int ins = (xorshift32(&state) >> 24) < (arguments.ins_rate * 256u) / 100u ? 1 : 0;
                if (ins) {
                    // shift the remaining sequence to the right by one position
                    memmove(&queries[(i * arguments.n_queries_per_target + j) * arguments.target_length + k + 1],
                            &queries[(i * arguments.n_queries_per_target + j) * arguments.target_length + k],
                            arguments.target_length - k - 1);
                    // insert a random base at the current position
                    queries[(i * arguments.n_queries_per_target + j) * arguments.target_length + k] = random_base(&state);
                }
            }
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
    sw_naive_kernel<<<blocks, arguments.threads_per_block>>>(targets, queries, scores,
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
            "Best score for query %zu: %u (target %u, source target %zu)\n",
            q_index, best_score[q_index], best_target[q_index], source_target);
    }

    // free allocated memory
    CHECK_CUDA(cudaFree(targets));
    CHECK_CUDA(cudaFree(queries));
    CHECK_CUDA(cudaFree(scores));

    return EXIT_SUCCESS;
}
