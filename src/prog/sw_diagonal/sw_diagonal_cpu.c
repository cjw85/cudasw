#include <stddef.h>
#include <stdlib.h>

#include "sw_diagonal_cpu.h"

static int min_int(int first, int second)
{
    return first < second ? first : second;
}

static int max_int(int first, int second)
{
    return first > second ? first : second;
}

int sw_diagonal_cpu_score(
    const char* target_sequence, int target_length,
    const char* query_sequence, int query_length)
{
    const int m_score = 8;
    const int d_score = -2;
    const int i_score = -2;
    const int e_score = 0;
    const int max_diagonal_cells = min_int(target_length, query_length);
    if (query_length == 0) {
        return e_score;
    }

    int* diagonal_storage = (int*)malloc(
        (size_t)3 * max_diagonal_cells * sizeof(*diagonal_storage));
    if (diagonal_storage == NULL) {
        return -1;
    }

    int* previous_previous = diagonal_storage;
    int* previous = previous_previous + max_diagonal_cells;
    int* current = previous + max_diagonal_cells;
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
            const int diagonal = (i > 0 && j > 0
                ? previous_previous[i - 1 - previous_previous_i_min]
                : e_score) + match;

            current[k] = max_int(diagonal, max_int(deletion, insertion));
            if (i == query_length - 1 || j == target_length - 1) {
                best_score = max_int(best_score, current[k]);
            }
        }

        int* temporary = previous_previous;
        previous_previous = previous;
        previous = current;
        current = temporary;
    }

    free(diagonal_storage);
    return best_score;
}
