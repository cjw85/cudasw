.DEFAULT_GOAL := build

NVCC ?= nvcc
CC ?= cc
BUILD_MODE ?= release

VALID_BUILD_MODES := release debug
ifeq ($(filter $(BUILD_MODE),$(VALID_BUILD_MODES)),)
$(error Invalid BUILD_MODE '$(BUILD_MODE)'; valid modes: $(VALID_BUILD_MODES))
endif

# Keep release artifacts at build/ and let debugging builds coexist at build/debug/.
BUILD_DIR ?= build$(if $(filter release,$(BUILD_MODE)),,/$(BUILD_MODE))
OBJ_DIR := $(BUILD_DIR)/obj
DEP_DIR := $(BUILD_DIR)/deps
BIN := $(BUILD_DIR)/cudasw
TEST_BIN := $(BUILD_DIR)/test/sw_naive_test
TILED_TEST_BIN := $(BUILD_DIR)/test/sw_tiled_test

# CUDA 12.0 emits GNU-style #line directives itself, so forwarding
# -Wpedantic together with -Werror makes NVCC fail on its generated source.
WARNINGS := -Xcompiler -Wall,-Wextra,-Werror
C_WARNINGS := -Wall -Wextra -Wpedantic -Werror
CFLAGS := -std=c11
CPPFLAGS := -Isrc -Isrc/prog/vec_add -Isrc/prog/sw_naive
CPPFLAGS += -Isrc/prog/sw_diagonal -Isrc/prog/sw_tiled

ifeq ($(BUILD_MODE),release)
MODE_FLAGS := -O3
C_MODE_FLAGS := -O3
else ifeq ($(BUILD_MODE),debug)
MODE_FLAGS := -O0 -g -G
C_MODE_FLAGS := -O0 -g
endif

NVCCFLAGS := $(MODE_FLAGS) $(WARNINGS)
CUDA_SOURCES := \
	src/prog/cudasw/main.cu \
	src/prog/vec_add/vec_add.cu \
	src/prog/sw_naive/sw_naive.cu \
	src/prog/sw_diagonal/sw_diagonal.cu \
	src/prog/sw_tiled/sw_tiled.cu
C_SOURCES := \
	src/common.c \
	src/prog/vec_add/vec_add_args.c \
	src/prog/sw_naive/sw_naive_args.c \
	src/prog/sw_diagonal/sw_diagonal_args.c \
	src/prog/sw_diagonal/sw_diagonal_cpu.c \
	src/prog/sw_tiled/sw_tiled_args.c
CUDA_OBJECTS := $(patsubst src/%.cu,$(OBJ_DIR)/%.o,$(CUDA_SOURCES))
C_OBJECTS := $(patsubst src/%.c,$(OBJ_DIR)/%.o,$(C_SOURCES))
OBJECTS := $(CUDA_OBJECTS) $(C_OBJECTS)
DEPS := $(patsubst $(OBJ_DIR)/%.o,$(DEP_DIR)/%.d,$(OBJECTS))
TEST_OBJECT := $(BUILD_DIR)/test/sw_naive_test.o
TEST_SUPPORT_OBJECTS := \
	$(OBJ_DIR)/prog/sw_naive/sw_naive.o \
	$(OBJ_DIR)/common.o \
	$(OBJ_DIR)/prog/sw_naive/sw_naive_args.o
TEST_DEP := $(DEP_DIR)/test/sw_naive_test.d
TILED_TEST_OBJECT := $(BUILD_DIR)/test/sw_tiled_test.o
TILED_TEST_DEP := $(DEP_DIR)/test/sw_tiled_test.d

CLANG_FORMAT ?= clang-format
CLANG_TIDY ?= clang-tidy
FORMAT_SOURCES := $(CUDA_SOURCES) $(C_SOURCES) \
	$(wildcard src/*.h src/*/*.h src/*/*/*.h)

.PHONY: build run test clean help print-config \
	clang_format clang_tidy

build: $(BIN) ## Build the CUDA starter program (default)

$(BIN): $(OBJECTS)
	@mkdir -p $(dir $@)
	$(NVCC) $(NVCCFLAGS) $^ -o $@

test: $(TEST_BIN) $(TILED_TEST_BIN) ## Build and run deterministic CUDA tests
	$(TEST_BIN)
	$(TILED_TEST_BIN)

$(TEST_BIN): $(TEST_OBJECT) $(TEST_SUPPORT_OBJECTS)
	@mkdir -p $(dir $@)
	$(NVCC) $(NVCCFLAGS) $^ -o $@

$(TILED_TEST_BIN): $(TILED_TEST_OBJECT) \
		$(OBJ_DIR)/prog/sw_tiled/sw_tiled.o \
		$(OBJ_DIR)/prog/sw_tiled/sw_tiled_args.o \
		$(OBJ_DIR)/prog/sw_diagonal/sw_diagonal_cpu.o \
		$(OBJ_DIR)/common.o
	@mkdir -p $(dir $@)
	$(NVCC) $(NVCCFLAGS) $^ -o $@

$(OBJ_DIR)/%.o: src/%.cu
	@mkdir -p $(dir $@) $(dir $(patsubst $(OBJ_DIR)/%.o,$(DEP_DIR)/%.d,$@))
	$(NVCC) $(CPPFLAGS) $(NVCCFLAGS) -MMD -MP -MF $(patsubst $(OBJ_DIR)/%.o,$(DEP_DIR)/%.d,$@) -c $< -o $@

$(OBJ_DIR)/%.o: src/%.c
	@mkdir -p $(dir $@) $(dir $(patsubst $(OBJ_DIR)/%.o,$(DEP_DIR)/%.d,$@))
	$(CC) $(CPPFLAGS) $(CFLAGS) $(C_MODE_FLAGS) $(C_WARNINGS) -MMD -MP \
		-MF $(patsubst $(OBJ_DIR)/%.o,$(DEP_DIR)/%.d,$@) -c $< -o $@

$(TEST_OBJECT): test/sw_naive_test.cu
	@mkdir -p $(dir $@) $(dir $(TEST_DEP))
	$(NVCC) $(CPPFLAGS) $(NVCCFLAGS) -MMD -MP -MF $(TEST_DEP) -c $< -o $@

$(TILED_TEST_OBJECT): test/sw_tiled_test.cu
	@mkdir -p $(dir $@) $(dir $(TILED_TEST_DEP))
	$(NVCC) $(CPPFLAGS) $(NVCCFLAGS) -MMD -MP -MF $(TILED_TEST_DEP) -c $< -o $@

run: $(BIN) ## Build and run the vec-add subcommand
	$(BIN) vec-add

print-config: ## Print the selected compiler and build configuration
	@printf 'NVCC=%s\nCC=%s\nBUILD_MODE=%s\nBUILD_DIR=%s\n' '$(NVCC)' '$(CC)' '$(BUILD_MODE)' '$(BUILD_DIR)'

clang_format: ## Format first-party C, C++, and CUDA sources
	@command -v $(CLANG_FORMAT) >/dev/null 2>&1 || { echo "$(CLANG_FORMAT) not found"; exit 1; }
	$(CLANG_FORMAT) -i $(FORMAT_SOURCES)

clang_tidy: ## Run clang-tidy over first-party C sources
	@command -v $(CLANG_TIDY) >/dev/null 2>&1 || { echo "$(CLANG_TIDY) not found. Install clang-tidy"; exit 1; }
	@for source in $(C_SOURCES); do \
		$(CLANG_TIDY) --quiet --warnings-as-errors='*' \
			--header-filter='(^|.*/)src/.*' "$$source" -- \
			$(CPPFLAGS) $(CFLAGS) || exit $$?; \
	done

clean: ## Remove locally built artifacts
	rm -rf build

help: ## Show this help message
	@printf '\nBuild modes: BUILD_MODE=release (default), BUILD_MODE=debug\n\n'
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@printf '\n'

-include $(DEPS) $(TEST_DEP) $(TILED_TEST_DEP)
