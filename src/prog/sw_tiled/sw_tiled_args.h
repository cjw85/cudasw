#ifndef SW_TILED_ARGS_H
#define SW_TILED_ARGS_H

#include <stddef.h>

typedef struct sw_tiled_arguments {
    size_t query_length;
    size_t target_length;
    size_t tile_size;
    size_t threads_per_block;
    size_t sub_rate;
    size_t del_rate;
    size_t ins_rate;
    size_t random_seed;
    int run_cpu;
} sw_tiled_arguments_t;

#ifdef __cplusplus
extern "C" {
#endif

int sw_tiled_parse_arguments(
    int argc, char **argv, sw_tiled_arguments_t *arguments);

#ifdef __cplusplus
}
#endif

#endif
