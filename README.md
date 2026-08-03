# whisper-labwc

Safety-focused Bash/CMake wrapper for building the configured
[`whisper.cpp`](https://github.com/ggml-org/whisper.cpp) release from source on
Linux/Debian hosts. The wrapper builds and stages `whisper-cli`; Labwc or other
desktop integration should invoke that staged executable rather than modify the
managed upstream source tree.

The default upstream ref is `v1.9.1`. The build is CPU-native by default and
can be configured for one GPU backend at a time.

## Prerequisites

The normal CPU build and the repository test suite require:

```sh
sudo apt install build-essential cmake git shellcheck
```

`ninja-build` is optional; the wrapper selects Ninja automatically when
available and otherwise uses Unix Makefiles. The checked-in host profile also
uses `sccache`; install it only when retaining that profile:

```sh
sudo apt install ninja-build sccache
```

Enable a GPU or optional acceleration backend only after its compiler and
development packages are installed. Run `make doctor` before building; it
checks the selected toolchain and enabled backend dependencies.

## Configure a build

Without a `.env` file, all managed paths stay under the repository:

```sh
make doctor
make build
```

To use the supplied host-native profile, copy and edit it first:

```sh
cp .env.example .env
```

`.env.example` intentionally uses `/pool/...` paths, enables
`ALLOW_EXTERNAL_DIRS=1`, and configures `sccache`. Change every directory to
locations you own and can write, or clear the `sccache` variables and set
`ENABLE_CCACHE` to the desired value. Do not source a `.env` file obtained
from an untrusted party: it is Bash configuration.

When invoking the wrapper through `make`, configuration precedence is:

1. `make` command-line assignments, such as
   `make build ENABLE_CUDA=1 CUDA_ARCHS=89`;
2. values in `.env`;
3. the safe repository-local defaults in `Makefile`.

The individual scripts load `.env` when invoked directly, so prefer the
documented `make` targets for consistent configuration resolution.

Useful configuration knobs:

| Variable | Purpose |
| --- | --- |
| `GGML_NATIVE=1` | Optimizes the output for the current CPU; the binary is not portable to older CPUs. |
| `CMAKE_C_FLAGS`, `CMAKE_CXX_FLAGS` | Base CMake compiler flags, such as `-march=native`. |
| `CMAKE_C_COMPILER_LAUNCHER=sccache` and `CMAKE_CXX_COMPILER_LAUNCHER=sccache` | Enables the explicit project-scoped `sccache` launchers. Both launchers and `SCCACHE_DIR` must be set together. |
| `ENABLE_CUDA`, `ENABLE_HIP`, `ENABLE_VULKAN`, `ENABLE_SYCL` | Select at most one primary GPU backend per build directory. |
| `ENABLE_BLAS`, `ENABLE_OPENVINO`, `ENABLE_FFMPEG` | Enable optional CPU or input-format features after installing their development dependencies. |

Inspect the resolved settings before creating or modifying managed trees:

```sh
make info
```

## Build, model download, and transcription

```sh
# Fetch the configured source ref, configure Release mode, build whisper-cli, stage it,
# and verify the staged executable and dynamic libraries.
make build

# Browse the curated GGML model table, then download one model.
make models
make download MODEL=base.en

# Transcribe a local audio file. Extra whisper-cli flags go through ARGS.
make run MODEL=base.en AUDIO=/path/to/audio.wav ARGS="--output-txt"
```

The staged executable is `OUTPUT_DIR/bin/whisper-cli`; metadata, including the
resolved source commit, compiler information, selected backend, flags, cache
choice, and binary SHA-256, is written to
`OUTPUT_DIR/metadata/build-info.txt`.

## Source and cleanup safety

- Source, build, output, model, and `sccache` directories are validated before
  writes and must not overlap in unsafe ways.
- Managed directories have marker files. Cleanup refuses non-empty, unmarked
  directories.
- `make clean` removes only the configured build tree and staged binary;
  downloaded models and source remain. `make distclean` also removes the
  managed source tree. `make purge CONFIRM=YES` additionally removes managed
  models.
- Tracked changes in the managed upstream checkout block resets and removal
  unless `FORCE_SOURCE_RESET=1` is explicitly set.
- `OFFLINE=1` forbids source fetching and new model downloads. With
  `SOURCE_UPDATE=0`, a stamped source commit is reused without network access.

## Testing

The test suite is hermetic: it uses a local fake upstream project and a fake
model transport; it does not download `whisper.cpp` or model weights.

```sh
make test
```

Tests run Bash syntax checks, ShellCheck, model-manifest validation,
model-download validation, explicit `sccache` CMake-argument validation, and
model selection/execution validation with a fake binary. They also run an
end-to-end wrapper build against a local fake CMake project. The latter
requires a working `cmake`, C/C++ compiler, `make`, and `git`.

## References

- Build and source references: [`docs/SOURCES.md`](docs/SOURCES.md)
- Curated model catalog notes: [`models/README.md`](models/README.md)
- Model metadata source of truth: [`models/models.tsv`](models/models.tsv)
- License: [`LICENSE`](LICENSE)
