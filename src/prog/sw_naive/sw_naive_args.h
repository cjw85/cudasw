#ifndef SW_BATCH_ARGS_H
#define SW_BATCH_ARGS_H

#include <stddef.h>

#define SW_BATCH_MAX_SEQUENCE_LENGTH 1024

typedef struct sw_naive_arguments {
    size_t n_targets;
    size_t target_length;
    size_t n_queries_per_target;
    size_t sub_rate;
    size_t del_rate;
    size_t ins_rate;
    size_t seed;
    size_t threads_per_block;
} sw_naive_arguments_t;

#ifdef __cplusplus
extern "C" {
#endif

int sw_naive_parse_arguments(int argc, char** argv, sw_naive_arguments_t* arguments);

#ifdef __cplusplus
}
#endif

#endif // SW_BATCH_ARGS_H
