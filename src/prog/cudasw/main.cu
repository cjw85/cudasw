#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "sw_naive.h"
#include "vec_add.h"

static void print_usage(const char* program)
{
    printf("Usage: %s <command> [options]\n\n"
           "Commands:\n"
           "    vec-add    Run the managed-memory vector operation.\n"
           "    sw-naive   Run the naive Smith-Waterman batch operation.\n",
           program);
}

int main(int argc, char** argv)
{
    if (argc < 2 || strcmp(argv[1], "--help") == 0 || strcmp(argv[1], "-h") == 0) {
        print_usage(argv[0]);
        return argc < 2 ? EXIT_FAILURE : EXIT_SUCCESS;
    }

    if (strcmp(argv[1], "vec-add") == 0) {
        return run_vec_add(argc - 1, argv + 1);
    }

    if (strcmp(argv[1], "sw-naive") == 0) {
        return run_sw_naive(argc - 1, argv + 1);
    }

    fprintf(stderr, "error: unknown command '%s'\n", argv[1]);
    print_usage(argv[0]);
    return EXIT_FAILURE;
}
