#include "sw_naive_args.h"

#include <argp.h>
#include <stdlib.h>
#include <string.h>

static const char doc[] = "Run a bunch of Smith-Waterman alignments.";
static const char args_doc[] = "";

static const struct argp_option options[] = {
    { "n-targets", 'n', "N_TARGETS", 0,
        "Number of target sequences.", 0 },
    { "target-length", 'l', "TARGET_LENGTH", 0,
        "Length of each target sequence.", 0 },
    { "n-queries-per-target", 'q', "N_QUERIES_PER_TARGET", 0,
        "Number of query sequences generated for each target.", 0 },
    { "sub-rate", 'r', "SUB_RATE", 0,
        "Substitution error rate (0-100).", 0 },
    { "del-rate", 'd', "DEL_RATE", 0,
        "Deletion error rate (0-100).", 0 },
    { "ins-rate", 'i', "INS_RATE", 0,
        "Insertion error rate (0-100).", 0 },
    { "seed", 's', "SEED", 0,
        "Random seed for sequence generation.", 0 },
    { "threads-per-block", 't', "THREADS_PER_BLOCK", 0,
        "Number of CUDA threads per block.", 0 },
    { 0 }
};
static error_t parse_opt(int key, char *arg, struct argp_state *state)
{
    sw_naive_arguments_t *arguments = state->input;

    switch (key) {
    case 'n':
        arguments->n_targets = atoi(arg);
        break;
    case 'l':
        arguments->target_length = atoi(arg);
        break;
    case 'q':
        arguments->n_queries_per_target = atoi(arg);
        break;
    case 't':
        arguments->threads_per_block = atoi(arg);
        break;
    case ARGP_KEY_ARG:
        argp_error(state, "unexpected positional argument: '%s'", arg);
        break;
    case ARGP_KEY_END:
        if (arguments->target_length == 0 || arguments->target_length > SW_NAIVE_MAX_TARGET_LENGTH) {
            argp_error(state,
                "target length must be between 1 and %d",
                SW_NAIVE_MAX_TARGET_LENGTH);
        }
        break;
    case 'r':
        arguments->sub_rate = atoi(arg);
        break;
    case 'd':
        arguments->del_rate = atoi(arg);
        break;
    case 'i':
        arguments->ins_rate = atoi(arg);
        break;
    case 's':
        arguments->seed = atoi(arg);
        break;
    default:
        return ARGP_ERR_UNKNOWN;
    }
    return 0;
}

static const struct argp argp = { options, parse_opt, args_doc, doc, 0, 0, 0 };

int sw_naive_parse_arguments(int argc, char **argv, sw_naive_arguments_t *arguments)
{
    arguments->n_targets = 16;
    arguments->target_length = 1024;
    arguments->n_queries_per_target = 32;
    arguments->sub_rate = 1;
    arguments->del_rate = 1;
    arguments->ins_rate = 1;
    arguments->seed = 0;
    arguments->threads_per_block = 256;
    return argp_parse(&argp, argc, argv, 0, 0, arguments);
}
