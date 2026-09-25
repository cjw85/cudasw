#ifndef VEC_ADD_ARGS_H
#define VEC_ADD_ARGS_H

typedef struct vec_add_arguments {
    const char* operation;
    float b_value;
    int threads_per_block;
    int vector_length; 
} vec_add_arguments_t;

#ifdef __cplusplus
extern "C" {
#endif

int vec_add_parse_arguments(int argc, char** argv, vec_add_arguments_t* arguments);

#ifdef __cplusplus
}
#endif

#endif
