#include <argp.h>
#include <stdlib.h>

#include "sw_diagonal_args.h"

static const char doc[] =
    "Sketch the anti-diagonal Smith-Waterman execution layout.";
static const char args_doc[] = "";

static const struct argp_option options[] = {
    { "query-length", 'q', "QUERY_LENGTH", 0,
        "Length of the query sequence.", 0 },
    { "target-length", 't', "TARGET_LENGTH", 0,
        "Length of the target sequence.", 0 },
    { "threads-per-block", 'b', "THREADS_PER_BLOCK", 0,
        "Number of CUDA threads assigned to each diagonal group.", 0 },
    { "sub-rate", 's', "SUB_RATE", 0,
        "Substitution error rate (0-100).", 0 },
    { "del-rate", 'd', "DEL_RATE", 0,
        "Deletion error rate (0-100).", 0 },
    { "ins-rate", 'i', "INS_RATE", 0,
        "Insertion error rate (0-100).", 0 },
    { "seed", 'r', "SEED", 0,
        "Random seed for sequence generation.", 0 },
    { 0 }
};

static error_t parse_opt(int key, char* arg, struct argp_state* state)
{
    sw_diagonal_arguments_t* arguments = state->input;

    switch (key) {
    case 'q':
        arguments->query_length = strtoul(arg, NULL, 10);
        break;
    case 't':
        arguments->target_length = strtoul(arg, NULL, 10);
        break;
    case 'b':
        arguments->threads_per_block = strtoul(arg, NULL, 10);
        break;
    case 's':
        arguments->sub_rate = strtoul(arg, NULL, 10);
        break;
    case 'd':
        arguments->del_rate = strtoul(arg, NULL, 10);
        break;
    case 'i':
        arguments->ins_rate = strtoul(arg, NULL, 10);
        break;
    case 'r':
        arguments->random_seed = strtoul(arg, NULL, 10);
        break;
    case ARGP_KEY_ARG:
        argp_error(state, "unexpected positional argument: '%s'", arg);
        break;
    case ARGP_KEY_END:
        if (arguments->query_length == 0 || arguments->target_length == 0) {
            argp_error(state, "sequence lengths must be greater than zero");
        }
        if (arguments->threads_per_block == 0) {
            argp_error(state, "threads per block must be greater than zero");
        }
        break;
    default:
        return ARGP_ERR_UNKNOWN;
    }
    return 0;
}

static const struct argp argp = { options, parse_opt, args_doc, doc, 0, 0, 0 };

int sw_diagonal_parse_arguments(
    int argc, char** argv, sw_diagonal_arguments_t* arguments)
{
    arguments->query_length = 1024;
    arguments->target_length = 1024;
    arguments->threads_per_block = 1024;
    arguments->sub_rate = 1;
    arguments->del_rate = 1;
    arguments->ins_rate = 1;
    arguments->random_seed = 0;
    return argp_parse(&argp, argc, argv, 0, 0, arguments);
}
