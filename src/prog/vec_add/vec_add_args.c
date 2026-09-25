#include "vec_add_args.h"

#include <argp.h>
#include <stdlib.h>
#include <string.h>

static const char doc[] = "Run a vector operation.";
static const char args_doc[] = "";

static const struct argp_option options[] = {
    { "operation", 'o', "OPERATION", 0,
        "Element-wise operation: add or multiply (default: add).", 0 },
    { "b-value", 'b', "B_VALUE", 0,
        "Value to assign to vector b (default: 2.0).", 0 },
    { "threads-per-block", 't', "THREADS_PER_BLOCK", 0,
        "Number of threads per block (default: 256).", 0 },
    { "vector-length", 'l', "VECTOR_LENGTH", 0,
        "Length of the vectors (default: 16).", 0 },
    { 0 }
};

static error_t parse_opt(int key, char *arg, struct argp_state *state)
{
    vec_add_arguments_t *arguments = state->input;

    switch (key) {
    case 'o':
        arguments->operation = arg;
        break;
    case 'b':
        arguments->b_value = atof(arg);
        break;
    case 't':
        arguments->threads_per_block = atoi(arg);
        break;
    case 'l':
        arguments->vector_length = atoi(arg);
        break;
    case ARGP_KEY_ARG:
        argp_error(state, "unexpected positional argument: '%s'", arg);
        break;
    case ARGP_KEY_END:
        if (strcmp(arguments->operation, "add") != 0 && strcmp(arguments->operation, "multiply") != 0) {
            argp_error(state,
                "unsupported operation '%s' (expected add or multiply)",
                arguments->operation);
        }
        break;
    default:
        return ARGP_ERR_UNKNOWN;
    }
    return 0;
}

static const struct argp argp = { options, parse_opt, args_doc, doc, 0, 0, 0 };

int vec_add_parse_arguments(int argc, char **argv, vec_add_arguments_t *arguments)
{
    arguments->operation = "add";
    arguments->b_value = 2.0F;
    arguments->threads_per_block = 256;
    arguments->vector_length = 16;
    return argp_parse(&argp, argc, argv, 0, 0, arguments);
}
