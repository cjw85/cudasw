#include "common.h"

static int is_event(uint32_t* state, size_t rate)
{
    return (xorshift32(state) >> 24) < (rate * 256u) / 100u;
}

uint32_t xorshift32(uint32_t* state)
{
    uint32_t value = *state;
    if (value == 0) {
        value = 0xDEADBEEFu;
    }
    value ^= value << 13;
    value ^= value >> 17;
    value ^= value << 5;
    if (value == 0) {
        value = 0xDEADBEEFu;
    }
    *state = value;
    return value;
}

char random_base(uint32_t* state)
{
    static const char bases[] = "ACGT";
    return bases[xorshift32(state) >> 30];
}

size_t simulate_sequence(
    const char* target, size_t target_length, char* query, size_t max_length,
    size_t sub_rate, size_t ins_rate, size_t del_rate, uint32_t* state)
{
    size_t query_length = 0;

    for (size_t target_index = 0; target_index < target_length; ++target_index) {
        if (is_event(state, ins_rate) && query_length < max_length) {
            query[query_length++] = random_base(state);
        }

        if (is_event(state, del_rate)) {
            continue;
        }

        char base = target[target_index];
        if (is_event(state, sub_rate)) {
            do {
                base = random_base(state);
            } while (base == target[target_index]);
        }

        if (query_length < max_length) {
            query[query_length++] = base;
        }
    }

    return query_length;
}
