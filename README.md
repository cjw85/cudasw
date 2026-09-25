# CUDA Smith-Waterman learning project


## Build and run

On a Linux host with the CUDA Toolkit, NVIDIA driver, and a GPU:

```sh
make
make run
build/cudasw --help
build/cudasw vec-add
build/cudasw vec-add --operation multiply
build/cudasw sw-naive --n-targets 32 --target-length 1024 \
    --n-queries-per-target 32
```

Useful variants:

```sh
make BUILD_MODE=debug run  # -O0, host symbols, and CUDA device debug info
make help
make clean
```
