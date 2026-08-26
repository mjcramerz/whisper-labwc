# whisper-labwc

Safety-focused Bash/CMake wrapper for downloading the configured
[`whisper.cpp`](https://github.com/ggml-org/whisper.cpp) release and compiling
`whisper-cli` plus `whisper-server` from source on Linux/Debian hosts.

The default upstream ref is `v1.9.1`. Two first-class build profiles are
provided:

- `make build-ram`: CPU-native build intended to run models from system RAM.
- `make build-cuda`: CUDA build targeted at an NVIDIA Quadro P520 with compute
  capability 6.1 (`sm_61`) and model layers primarily offloaded to VRAM.

Each profile has an independent build directory, output directory, sccache
directory, and compressed binary artifact.

## Prerequisites

The CPU/RAM build and repository test suite require:

```sh
sudo apt install build-essential bubblewrap cmake git ninja-build perl sccache shellcheck tar gzip
```

Ninja is selected automatically when installed; otherwise the wrapper uses Unix
Makefiles.

The CUDA profile additionally requires:

- an NVIDIA driver that supports the installed Quadro P520;
- a CUDA toolkit that provides `nvcc` and still supports offline compilation for
  `sm_61`;
- the CUDA runtime libraries needed by the resulting executable.

Run `make doctor-cuda` before a CUDA build. It compiles a small CUDA translation
unit with `-arch=sm_61`, so an incompatible toolkit fails before the full build.

## Configuration and precedence

`.env` is tracked and is the source of truth for the build profiles.
`.env.example` is an exact tracked mirror. Do not put credentials in either
file. Put credentials or machine-only overrides in ignored `.env.local`, for
example:

```sh
HF_TOKEN=hf_example
WHISPER_CUDA_BUILD_JOBS=4
```

Both files must remain valid as a Make include and as Bash assignments. Avoid
unquoted whitespace and shell metacharacters.

Configuration precedence is:

1. `make` command-line assignments;
2. ignored `.env.local` overrides;
3. tracked `.env` defaults;
4. safe repository-local fallbacks in `Makefile` if `.env` is removed.

The individual scripts load `.env` followed by `.env.local` when invoked
directly. Prefer the documented `make` targets so profile selection and
precedence remain consistent.

## Managed `/pool` layout

The tracked defaults use a new `whisper-labwc` namespace. The wrapper does not
adopt or reuse an unrelated checkout.

| Purpose | RAM profile | CUDA profile |
| --- | --- | --- |
| Managed upstream source | `/pool/cache/whisper-labwc/source` | `/pool/cache/whisper-labwc/source` |
| Model cache | `/pool/cache/whisper-labwc/models` | `/pool/cache/whisper-labwc/models` |
| Build tree | `/pool/build/whisper-labwc/ram` | `/pool/build/whisper-labwc/cuda` |
| Staged output | `/pool/build/whisper-labwc/output/ram` | `/pool/build/whisper-labwc/output/cuda` |
| sccache | `/pool/cache/whisper-labwc/sccache/ram` | `/pool/cache/whisper-labwc/sccache/cuda` |
| sccache server | `.../sccache/ram/server.sock` | `.../sccache/cuda/server.sock` |
| Tarball | `/pool/build/whisper-labwc/artifacts/whisper-ram.tar.gz` | `/pool/build/whisper-labwc/artifacts/whisper-cuda.tar.gz` |

`ALLOW_EXTERNAL_DIRS=1` authorizes those managed paths. Change the corresponding
`WHISPER_RAM_*` or `WHISPER_CUDA_*` variables if `/pool` is mounted elsewhere,
but keep source, build, output, model, and cache paths non-overlapping.

## Profile flags

Both profiles expose their complete path/toolchain/backend configuration in
`.env`. The Makefile maps those names to the validated generic CMake wrapper
variables only for the selected target.

### RAM profile

| Variable | Default | Effect |
| --- | --- | --- |
| `WHISPER_RAM_BUILD_CLI` / `WHISPER_RAM_BUILD_SERVER` | `1` / `1` | Builds both executables. |
| `WHISPER_RAM_GGML_NATIVE` | `1` | Enables host-native ggml CPU kernels. |
| `WHISPER_RAM_CMAKE_C_FLAGS` / `WHISPER_RAM_CMAKE_CXX_FLAGS` | `-march=native` | Uses the current CPU instruction set. |
| `WHISPER_RAM_ENABLE_OPENMP` | `1` | Enables multithreaded CPU execution. |
| `WHISPER_RAM_ENABLE_CPU_REPACK` | `1` | Enables ggml repacked CPU kernels. |
| `WHISPER_RAM_ENABLE_LTO` | `1` | Enables link-time optimization. |
| `WHISPER_RAM_SCCACHE_SERVER_UDS` | `/pool/cache/whisper-labwc/sccache/ram/server.sock` | Isolates the RAM cache daemon from other profiles. |
| `WHISPER_RAM_ENABLE_BLAS` | `0` | Optional OpenBLAS acceleration; enable only after installing its development package. |
| `WHISPER_RAM_ENABLE_CUDA/HIP/VULKAN/SYCL` | `0` | Keeps this profile CPU/RAM-only. |

### Quadro P520 CUDA profile

| Variable | Default | Effect |
| --- | --- | --- |
| `WHISPER_CUDA_ENABLE_CUDA` | `1` | Enables the ggml CUDA backend. |
| `WHISPER_CUDA_CUDA_ARCHS` | `61` | Passes `CMAKE_CUDA_ARCHITECTURES=61` (`sm_61`). |
| `WHISPER_CUDA_CMAKE_CUDA_COMPILER` | `/usr/local/cuda-12.8/bin/nvcc` | Selects this host's CUDA 12.8 compiler explicitly without relying on login-shell `PATH`. |
| `WHISPER_CUDA_CMAKE_CUDA_HOST_COMPILER` | `/usr/bin/g++-14` | Uses a CUDA 12.8-supported GNU host compiler instead of Debian forky's default GCC 15. |
| `WHISPER_CUDA_ENABLE_CUDA_GLIBC_COMPAT` | `1` | Enables a private Bubblewrap header overlay for CUDA 12.8 on glibc 2.43. |
| `WHISPER_CUDA_CUDA_GLIBC_HEADER` | `/usr/local/cuda-12.8/targets/x86_64-linux/include/crt/math_functions.h` | Identifies the installed header that remains read-only. |
| `WHISPER_CUDA_CUDA_GLIBC_COMPAT_DIR` | `/pool/cache/whisper-labwc/cuda-compat/12.8` | Stores a generated private copy with the six corrected `noexcept(true)` declarations. |
| `WHISPER_CUDA_CMAKE_C_COMPILER_LAUNCHER` / `WHISPER_CUDA_CMAKE_CXX_COMPILER_LAUNCHER` | `sccache` | Caches host C and C++ compilation in the CUDA profile cache. |
| `WHISPER_CUDA_SCCACHE_SERVER_UDS` | `/pool/cache/whisper-labwc/sccache/cuda/server.sock` | Gives the CUDA profile its own daemon and cache root. |
| `WHISPER_CUDA_CMAKE_CUDA_COMPILER_LAUNCHER` | empty | Runs each CUDA translation unit directly through the Bubblewrap compatibility compiler. A persistent `sccache` daemon cannot inherit that per-process private header mount. |
| `WHISPER_CUDA_ENABLE_CUDA_FA` | `1` | Compiles ggml CUDA Flash Attention kernels. |
| `WHISPER_CUDA_ENABLE_CUDA_FA_ALL_QUANTS` | `0` | Avoids unnecessary all-quant kernel expansion and build size. |
| `WHISPER_CUDA_CUDA_FORCE_MMQ` / `WHISPER_CUDA_CUDA_FORCE_CUBLAS` | `0` / `0` | Lets ggml choose the appropriate kernel path at runtime. |
| `WHISPER_CUDA_CUDA_NO_PEER_COPY` | `1` | Disables peer-copy code for the single-GPU P520 profile. |
| `WHISPER_CUDA_ENABLE_CUDA_NCCL` | `0` | Avoids the multi-GPU NCCL dependency. |
| `WHISPER_CUDA_CUDA_NO_VMM` | `0` | Retains the upstream CUDA VMM behavior. |
| `WHISPER_CUDA_ENABLE_CUDA_GRAPHS` | `0` | Leaves the llama.cpp-only graph optimization disabled. |
| `WHISPER_CUDA_ENABLE_HIP/VULKAN/SYCL` | `0` | Prevents conflicting primary GPU backends. |

Inspect every resolved value before building:

```sh
make info-ram
make info-cuda
```

## Build and artifacts

Build the CPU/RAM profile:

```sh
make doctor-ram
make build-ram
```

Build the Quadro P520 CUDA profile:

```sh
make doctor-cuda
make build-cuda
```

Each build performs this sequence:

```text
doctor -> fetch/reuse stamped v1.9.1 source -> configure Release
       -> build whisper-cli + whisper-server -> stage -> verify -> package
```

The tarballs contain binaries, checksums, the pinned-source/build metadata, the
CMake command, and the upstream license. Models are intentionally excluded.

```text
whisper-ram/                       whisper-cuda/
|-- bin/                           |-- bin/
|   |-- whisper-cli                |   |-- whisper-cli
|   `-- whisper-server             |   `-- whisper-server
`-- metadata/                      `-- metadata/
    |-- SHA256SUMS                     |-- SHA256SUMS
    |-- build-info.txt                 |-- build-info.txt
    |-- cmake-command.txt              |-- cmake-command.txt
    `-- WHISPER_CPP_LICENSE            `-- WHISPER_CPP_LICENSE
```

The staged output directories also contain convenient `whisper-cli` and
`whisper-server` symlinks. The generic `make build` target remains available for
custom one-off configurations but does not create a tarball automatically.

## Model download and execution

```sh
make models
make download MODEL=base.en
```

To run the RAM CLI output through the existing wrapper:

```sh
make run \
  OUTPUT_DIR=/pool/build/whisper-labwc/output/ram \
  MODEL_DIR=/pool/cache/whisper-labwc/models \
  MODEL=base.en \
  AUDIO=/path/to/audio.wav \
  ARGS="--output-txt"
```

The server executable is staged at:

```text
/pool/build/whisper-labwc/output/ram/bin/whisper-server
/pool/build/whisper-labwc/output/cuda/bin/whisper-server
```

Pass server runtime arguments directly to the selected executable. Keep network
binding and authentication appropriate for the host; compiling the server does
not make it safe to expose publicly.

## Source and cleanup safety

- The wrapper initializes and stamps `/pool/cache/whisper-labwc/source`, fetches
  the configured ref with Git, and refuses to modify an unmarked checkout.
- CUDA builds generate a private patched header under `/pool/cache` and use a
  Bubblewrap bind mount for each `nvcc` process. The installed CUDA toolkit
  under `/usr/local/cuda-12.8` is never modified. Host C/C++ objects remain
  cached with `sccache`; CUDA objects deliberately bypass it so `nvcc` stays in
  the private mount namespace.
- Source, build, output, model, archive, and sccache paths are validated before
  writes and must not overlap unsafely.
- Managed directories use marker files. Cleanup refuses non-empty, unmarked
  directories.
- `make clean-ram` and `make clean-cuda` remove only the corresponding CMake and
  staged output trees. Source, models, and the last successful tarball remain.
- `make distclean` and `make purge CONFIRM=YES` operate on the generic paths;
  inspect `make info` before using them.
- Tracked changes in the managed upstream checkout block resets and removal
  unless `FORCE_SOURCE_RESET=1` is explicit.
- `OFFLINE=1` forbids source fetching and new model downloads. With
  `SOURCE_UPDATE=0`, an exact stamped source commit is reused without network
  access.

## Testing

The suite is hermetic: it builds local fake whisper.cpp projects, uses a fake
CUDA compiler for the `sm_61` probe, and uses a fake model transport. It does
not download upstream source or model weights.

```sh
make test
```

Tests cover Bash syntax, ShellCheck, manifest/model validation, source safety,
tracked profile configuration, explicit sccache CMake arguments, separate
RAM/CUDA paths, CMake CUDA architecture propagation, both executable targets,
checksum verification, and both tarball layouts.

## References

- Build and source references: [`docs/SOURCES.md`](docs/SOURCES.md)
- Curated model catalog notes: [`models/README.md`](models/README.md)
- Model metadata source of truth: [`models/models.tsv`](models/models.tsv)
- License: [`LICENSE`](LICENSE)
