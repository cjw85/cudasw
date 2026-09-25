#ifndef CUDA_SW_COMMON_H
#define CUDA_SW_COMMON_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

uint32_t xorshift32(uint32_t* state);
char random_base(uint32_t* state);

/* Returns the generated length; query has capacity for max_length characters. */
size_t simulate_sequence(const char* target, size_t target_length,
                                char* query, size_t max_length,
                                size_t sub_rate, size_t ins_rate,
                                size_t del_rate, uint32_t* state);

#ifdef __cplusplus
}
#endif

#endif
