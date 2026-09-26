.DEFAULT_GOAL := build

HOST_OS := $(shell uname -s)
ifeq ($(HOST_OS),Darwin)
# mvcc CUDA compiler for macOS
MVCC_REPOSITORY := https://github.com/doximity/mvcc.git
MVCC_DIR := thirdparty/mvcc
MVCC_TOOLKIT := $(MVCC_DIR)/toolkit
MVCC_NVCC := $(MVCC_TOOLKIT)/bin/nvcc
MVCC_STAMP := $(MVCC_DIR)/.toolkit-installed
# argp CLI header
ARGP_PREFIX := $(shell brew --prefix argp-standalone 2>/dev/null)
ifneq ($(ARGP_PREFIX),)
ARGP_CPPFLAGS := -I$(ARGP_PREFIX)/include
ARGP_LIBRARY := $(ARGP_PREFIX)/lib/libargp.a
endif
ifeq ($(origin NVCC),undefined)
NVCC := $(MVCC_NVCC)
CUDA_TOOLKIT_PREREQUISITE := $(MVCC_STAMP)
MVCC_CPPFLAGS := -DCUDASW_MVCC
endif
else
NVCC ?= nvcc
endif
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
# -Wpedantic together with -Werror makes NVCC fail on its generated source
WARNINGS := -Xcompiler -Wall,-Wextra,-Werror
C_WARNINGS := -Wall -Wextra -Wpedantic -Werror
CFLAGS := -std=c11
CPPFLAGS := -Isrc -Isrc/prog/vec_add -Isrc/prog/sw_naive
CPPFLAGS += -Isrc/prog/sw_diagonal -Isrc/prog/sw_tiled
CPPFLAGS += $(ARGP_CPPFLAGS) $(MVCC_CPPFLAGS)

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
HEADER_SOURCES := $(wildcard src/*.h src/*/*.h src/*/*/*.h)

.PHONY: build run test clean help print-config setup-mvcc \
	clang-format clang-format-staged clang-tidy install-hooks

build: $(BIN) ## Build the CUDA starter program (default)

$(BIN): $(OBJECTS) | $(CUDA_TOOLKIT_PREREQUISITE)
	@mkdir -p $(dir $@)
	$(NVCC) $(NVCCFLAGS) $^ $(ARGP_LIBRARY) -o $@

test: $(TEST_BIN) $(TILED_TEST_BIN) ## Build and run deterministic CUDA tests
	$(TEST_BIN)
	$(TILED_TEST_BIN)

$(TEST_BIN): $(TEST_OBJECT) $(TEST_SUPPORT_OBJECTS) | $(CUDA_TOOLKIT_PREREQUISITE)
	@mkdir -p $(dir $@)
	$(NVCC) $(NVCCFLAGS) $^ $(ARGP_LIBRARY) -o $@

$(TILED_TEST_BIN): $(TILED_TEST_OBJECT) \
		$(OBJ_DIR)/prog/sw_tiled/sw_tiled.o \
		$(OBJ_DIR)/prog/sw_tiled/sw_tiled_args.o \
		$(OBJ_DIR)/prog/sw_diagonal/sw_diagonal_cpu.o \
		$(OBJ_DIR)/common.o | $(CUDA_TOOLKIT_PREREQUISITE)
	@mkdir -p $(dir $@)
	$(NVCC) $(NVCCFLAGS) $^ $(ARGP_LIBRARY) -o $@

$(OBJ_DIR)/%.o: src/%.cu $(HEADER_SOURCES) | $(CUDA_TOOLKIT_PREREQUISITE)
	@mkdir -p $(dir $@) $(dir $(patsubst $(OBJ_DIR)/%.o,$(DEP_DIR)/%.d,$@))
	$(NVCC) $(CPPFLAGS) $(NVCCFLAGS) -MMD -MP -MF $(patsubst $(OBJ_DIR)/%.o,$(DEP_DIR)/%.d,$@) -c $< -o $@

$(OBJ_DIR)/%.o: src/%.c $(HEADER_SOURCES)
	@mkdir -p $(dir $@) $(dir $(patsubst $(OBJ_DIR)/%.o,$(DEP_DIR)/%.d,$@))
	$(CC) $(CPPFLAGS) $(CFLAGS) $(C_MODE_FLAGS) $(C_WARNINGS) -MMD -MP \
		-MF $(patsubst $(OBJ_DIR)/%.o,$(DEP_DIR)/%.d,$@) -c $< -o $@

$(TEST_OBJECT): test/sw_naive_test.cu $(HEADER_SOURCES) | $(CUDA_TOOLKIT_PREREQUISITE)
	@mkdir -p $(dir $@) $(dir $(TEST_DEP))
	$(NVCC) $(CPPFLAGS) $(NVCCFLAGS) -MMD -MP -MF $(TEST_DEP) -c $< -o $@

$(TILED_TEST_OBJECT): test/sw_tiled_test.cu $(HEADER_SOURCES) | $(CUDA_TOOLKIT_PREREQUISITE)
	@mkdir -p $(dir $@) $(dir $(TILED_TEST_DEP))
	$(NVCC) $(CPPFLAGS) $(NVCCFLAGS) -MMD -MP -MF $(TILED_TEST_DEP) -c $< -o $@


ifeq ($(HOST_OS),Darwin)
$(MVCC_STAMP):
	@mkdir -p thirdparty
	@if [ -e "$(MVCC_DIR)" ] && [ ! -d "$(MVCC_DIR)/.git" ]; then \
		echo "$(MVCC_DIR) exists but is not an mvcc checkout" >&2; exit 1; \
	fi
	@if [ ! -d "$(MVCC_DIR)/.git" ]; then \
		echo "Cloning mvcc into $(MVCC_DIR)"; \
		git clone --depth 1 "$(MVCC_REPOSITORY)" "$(MVCC_DIR)"; \
	fi
	@echo "Building mvcc toolkit (requires Homebrew llvm, cmake, ninja, argp-standalone, and Rust)"
	@cd "$(MVCC_DIR)" && tools/install_toolkit.sh
	@touch "$@"

setup-mvcc: $(MVCC_STAMP)
else
setup-mvcc:
	@echo "mvcc setup is only needed on macOS"
endif

print-config: ## Print the selected compiler and build configuration
	@printf 'NVCC=%s\nCC=%s\nBUILD_MODE=%s\nBUILD_DIR=%s\n' '$(NVCC)' '$(CC)' '$(BUILD_MODE)' '$(BUILD_DIR)'

clang-format: ## Format first-party C, C++, and CUDA sources
	@command -v $(CLANG_FORMAT) >/dev/null 2>&1 || { echo "$(CLANG_FORMAT) not found"; exit 1; }
	$(CLANG_FORMAT) -i $(FORMAT_SOURCES)

clang-format-staged: ## Format staged first-party C, C++, and CUDA sources
	@staged_files="$$(git diff --cached --name-only --diff-filter=ACMR | \
		grep -E '^(src/.*\.(c|cu|h)|test/.*\.cu)$$' | tr '\n' ' ' || true)"; \
	if [ -n "$$staged_files" ]; then \
		$(MAKE) --no-print-directory clang-format FORMAT_SOURCES="$$staged_files"; \
		git add -- $$staged_files; \
	fi

clang-tidy: ## Run clang-tidy over first-party C sources
	@command -v $(CLANG_TIDY) >/dev/null 2>&1 || { echo "$(CLANG_TIDY) not found. Install clang-tidy"; exit 1; }
	@for source in $(C_SOURCES); do \
		$(CLANG_TIDY) --quiet --warnings-as-errors='*' \
			--header-filter='(^|.*/)src/.*' "$$source" -- \
			$(CPPFLAGS) $(CFLAGS) || exit $$?; \
	done

install-hooks: ## Install the repository's Git hooks
	@mkdir -p .githooks
	@chmod +x .githooks/pre-commit
	@git config --local core.hooksPath .githooks
	@echo "Installed Git hooks path: .githooks"

clean: ## Remove locally built artifacts
	rm -rf build

help: ## Show this help message
	@printf '\nBuild modes: BUILD_MODE=release (default), BUILD_MODE=debug\n\n'
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@printf '\n'

-include $(DEPS) $(TEST_DEP) $(TILED_TEST_DEP)
