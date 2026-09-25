#include "sw_diagonal_cpu.h"

#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>

#if defined(__x86_64__) || defined(__i386__)
#include <immintrin.h>
#endif

static int min_int(int first, int second)
{
    return first < second ? first : second;
}

static int max_int(int first, int second)
{
    return first > second ? first : second;
}

static int sw_diagonal_cpu_score_scalar(
    const char *target_sequence, int target_length,
    const char *query_sequence, int query_length)
{
    const int m_score = 8;
    const int d_score = -2;
    const int i_score = -2;
    const int e_score = 0;
    const int max_diagonal_cells = min_int(target_length, query_length);
    if (query_length == 0) {
        return e_score;
    }

    int *diagonal_storage = (int *)malloc(
        (size_t)3 * max_diagonal_cells * sizeof(*diagonal_storage));
    if (diagonal_storage == NULL) {
        return -1;
    }

    int *previous_previous = diagonal_storage;
    int *previous = previous_previous + max_diagonal_cells;
    int *current = previous + max_diagonal_cells;
    for (int k = 0; k < max_diagonal_cells; ++k) {
        previous_previous[k] = e_score;
        previous[k] = e_score;
        current[k] = e_score;
    }

    int best_score = e_score;
    const int n_diagonals = target_length + query_length - 1;
    for (int d = 0; d < n_diagonals; ++d) {
        const int i_min = max_int(0, d - target_length + 1);
        const int i_max = min_int(d, query_length - 1);
        const int n_cells = i_max - i_min + 1;
        const int previous_i_min = max_int(0, d - target_length);
        const int previous_previous_i_min = max_int(0, d - target_length - 1);

        for (int k = 0; k < n_cells; ++k) {
            const int i = i_min + k;
            const int j = d - i;
            const int match = target_sequence[j] == query_sequence[i] ? m_score : 0;
            const int deletion = i > 0
                ? previous[i - 1 - previous_i_min] + d_score
                : e_score;
            const int insertion = j > 0
                ? previous[i - previous_i_min] + i_score
                : e_score;
            const int diagonal = i > 0 && j > 0
                ? match + previous_previous[i - 1 - previous_previous_i_min]
                : match + e_score;

            current[k] = max_int(diagonal, max_int(deletion, insertion));
            if (i == query_length - 1 || j == target_length - 1) {
                best_score = max_int(best_score, current[k]);
            }
        }

        int *temporary = previous_previous;
        previous_previous = previous;
        previous = current;
        current = temporary;
    }

    free(diagonal_storage);
    return best_score;
}

#if defined(__x86_64__) || defined(__i386__)

/*
 * The vector loop below evaluates eight independent interior cells at once.
 * Boundary cells are kept scalar for simplicity.
 */
static inline int score_cell(
    const char *target_sequence, const char *query_sequence,
    int i, int j, int previous_i_min, int previous_previous_i_min,
    int *previous, int *previous_previous,
    int m_score, int d_score, int i_score, int e_score)
{
    const int match = target_sequence[j] == query_sequence[i] ? m_score : e_score;
    const int deletion = i > 0
        ? previous[i - 1 - previous_i_min] + d_score
        : e_score;
    const int insertion = j > 0
        ? previous[i - previous_i_min] + i_score
        : e_score;
    const int diagonal = i > 0 && j > 0
        ? previous_previous[i - 1 - previous_previous_i_min] + match
        : match;
    return max_int(diagonal, max_int(deletion, insertion));
}

__attribute__((target("avx2"))) static int sw_diagonal_cpu_score_avx2(
    const char *target_sequence, int target_length,
    const char *query_sequence, int query_length)
{
    printf("Starting AVX2 Smith-Waterman computation\n");
    const int m_score = 8;
    const int d_score = -2;
    const int i_score = -2;
    const int e_score = 0;
    const int max_diagonal_cells = min_int(target_length, query_length);
    if (query_length == 0) {
        return 0;
    }

    int *diagonal_storage = (int *)malloc(
        (size_t)3 * max_diagonal_cells * sizeof(*diagonal_storage));
    if (diagonal_storage == NULL) {
        return -1;
    }

    int *previous_previous = diagonal_storage;
    int *previous = previous_previous + max_diagonal_cells;
    int *current = previous + max_diagonal_cells;
    for (int k = 0; k < max_diagonal_cells; ++k) {
        previous_previous[k] = 0;
        previous[k] = 0;
        current[k] = 0;
    }

    int best_score = 0;
    const int n_diagonals = target_length + query_length - 1;
    for (int d = 0; d < n_diagonals; ++d) {
        const int i_min = max_int(0, d - target_length + 1);
        const int i_max = min_int(d, query_length - 1);
        const int n_cells = i_max - i_min + 1;
        const int previous_i_min = max_int(0, d - target_length);
        const int previous_previous_i_min = max_int(0, d - target_length - 1);

        int vector_start = 0;
        if (i_min == 0 || d - i_min == target_length - 1) {
            vector_start = 1;
        }
        int vector_end = n_cells;
        if (i_max == query_length - 1 || d - i_max == 0) {
            --vector_end;
        }
        const int vector_count = vector_end - vector_start;
        const int aligned_vector_end = vector_start + (vector_count / 8) * 8;

        for (int k = 0; k < vector_start; ++k) {
            const int i = i_min + k;
            const int j = d - i;
            current[k] = score_cell(
                target_sequence, query_sequence, i, j,
                previous_i_min, previous_previous_i_min,
                previous, previous_previous,
                m_score, d_score, i_score, e_score);
            if (i == query_length - 1 || j == target_length - 1) {
                best_score = max_int(best_score, current[k]);
            }
        }

        for (int k = vector_start; k < aligned_vector_end; k += 8) {
            // TODO: vectorize this with __mm_cmpeq_epi8
            int matches[8];
            for (int lane = 0; lane < 8; ++lane) {
                const int i = i_min + k + lane;
                const int j = d - i;
                matches[lane] = target_sequence[j] == query_sequence[i]
                    ? m_score
                    : e_score;
            }
            // load the above to AVX2
            const __m256i match = _mm256_loadu_si256((const __m256i *)matches);

            // deletion = previous[k + deletion_offset].
            const int deletion_offset = i_min - 1 - previous_i_min;
            const __m256i deletion_values = _mm256_loadu_si256(
                (const __m256i *)(previous + k + deletion_offset));
            // deletion += d_score.
            const __m256i deletion = _mm256_add_epi32(
                deletion_values, _mm256_set1_epi32(d_score));

            // insertion = previous[k + insertion_offset].
            const int insertion_offset = i_min - previous_i_min;
            const __m256i insertion_values = _mm256_loadu_si256(
                (const __m256i *)(previous + k + insertion_offset));
            // insertion += i_score
            const __m256i insertion = _mm256_add_epi32(
                insertion_values, _mm256_set1_epi32(i_score));

            // diagonal =
            // previous_previous[k + diagonal_offset] + match.
            const int diagonal_offset = i_min - 1 - previous_previous_i_min;
            const __m256i diagonal_values = _mm256_loadu_si256(
                (const __m256i *)(previous_previous + k + diagonal_offset));
            const __m256i diagonal = _mm256_add_epi32(diagonal_values, match);

            // max(deletion, insertion, diagonal)
            const __m256i pair_max = _mm256_max_epi32(deletion, insertion);
            const __m256i value = _mm256_max_epi32(diagonal, pair_max);

            // current[k + lane] = value_lane for lane 0..7.
            _mm256_storeu_si256((__m256i *)(current + k), value);
        }

        for (int k = aligned_vector_end; k < n_cells; ++k) {
            const int i = i_min + k;
            const int j = d - i;
            current[k] = score_cell(
                target_sequence, query_sequence, i, j,
                previous_i_min, previous_previous_i_min,
                previous, previous_previous,
                m_score, d_score, i_score, e_score);
            if (i == query_length - 1 || j == target_length - 1) {
                best_score = max_int(best_score, current[k]);
            }
        }

        int *temporary = previous_previous;
        previous_previous = previous;
        previous = current;
        current = temporary;
    }

    free(diagonal_storage);
    return best_score;
}

#endif

int sw_diagonal_cpu_score(
    const char *target_sequence, int target_length,
    const char *query_sequence, int query_length)
{
#if defined(__x86_64__) || defined(__i386__)
    if (__builtin_cpu_supports("avx2")) {
        return sw_diagonal_cpu_score_avx2(
            target_sequence, target_length, query_sequence, query_length);
    }
#endif
    return sw_diagonal_cpu_score_scalar(
        target_sequence, target_length, query_sequence, query_length);
}
