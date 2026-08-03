SHELL := /bin/bash
.DEFAULT_GOAL := help

ROOT_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

# Local configuration. Command-line assignments still take precedence:
#   make build ENABLE_CUDA=1 CUDA_ARCHS=89
-include $(ROOT_DIR)/.env

WHISPER_CPP_REPO ?= https://github.com/ggml-org/whisper.cpp.git
WHISPER_CPP_REF ?= v1.9.1
SOURCE_DIR ?= .cache/whisper.cpp
BUILD_DIR ?= .build/native
OUTPUT_DIR ?= output
MODEL_DIR ?= output/models
CMAKE_GENERATOR ?= auto
BUILD_JOBS ?= auto
CMAKE_C_COMPILER ?=
CMAKE_CXX_COMPILER ?=
GGML_NATIVE ?= 1
ENABLE_LTO ?= 1
ENABLE_CCACHE ?= 1
ENABLE_OPENMP ?= 1
ENABLE_CPU_REPACK ?= 1
ENABLE_FAST_MATH ?= 0
ENABLE_BLAS ?= 0
BLAS_VENDOR ?= OpenBLAS
ENABLE_CUDA ?= 0
CUDA_ARCHS ?= auto
ENABLE_CUDA_FA ?= 1
CUDA_FORCE_MMQ ?= 0
CUDA_FORCE_CUBLAS ?= 0
ENABLE_HIP ?= 0
AMDGPU_TARGETS ?= auto
ENABLE_VULKAN ?= 0
ENABLE_SYCL ?= 0
ENABLE_SYCL_F16 ?= 0
SYCL_TARGET ?= INTEL
SYCL_DEVICE_ARCH ?=
ENABLE_OPENVINO ?= 0
ENABLE_FFMPEG ?= 0
STRIP_BINARY ?= 1
OFFLINE ?= 0
SOURCE_UPDATE ?= 0
FORCE_SOURCE_RESET ?= 0
HF_TOKEN ?=
STRICT_RESOURCES ?= 0
FORCE_DOWNLOAD ?= 0
ALLOW_EXTERNAL_DIRS ?= 0
RUNTIME_THREADS ?= auto
EXTRA_CMAKE_ARGS ?=
EXTRA_C_FLAGS ?=
EXTRA_CXX_FLAGS ?=

MODEL ?=
AUDIO ?=
ARGS ?=
CONFIRM ?=

export ROOT_DIR WHISPER_CPP_REPO WHISPER_CPP_REF SOURCE_DIR BUILD_DIR OUTPUT_DIR MODEL_DIR
export CMAKE_GENERATOR BUILD_JOBS CMAKE_C_COMPILER CMAKE_CXX_COMPILER GGML_NATIVE
export ENABLE_LTO ENABLE_CCACHE ENABLE_OPENMP ENABLE_CPU_REPACK ENABLE_FAST_MATH
export ENABLE_BLAS BLAS_VENDOR ENABLE_CUDA CUDA_ARCHS ENABLE_CUDA_FA CUDA_FORCE_MMQ CUDA_FORCE_CUBLAS
export ENABLE_HIP AMDGPU_TARGETS ENABLE_VULKAN ENABLE_SYCL ENABLE_SYCL_F16 SYCL_TARGET SYCL_DEVICE_ARCH
export ENABLE_OPENVINO ENABLE_FFMPEG STRIP_BINARY OFFLINE SOURCE_UPDATE FORCE_SOURCE_RESET
export STRICT_RESOURCES FORCE_DOWNLOAD ALLOW_EXTERNAL_DIRS RUNTIME_THREADS EXTRA_CMAKE_ARGS EXTRA_C_FLAGS EXTRA_CXX_FLAGS

.PHONY: help doctor source update-source configure build rebuild verify info print-config
.PHONY: models download run test clean distclean purge

help: ## Show available targets
	@awk 'BEGIN {FS = ":.*## "; printf "whisper.cpp native builder\n\nUsage:\n  make <target> [VARIABLE=value ...]\n\nTargets:\n"} /^[a-zA-Z0-9_.-]+:.*## / {printf "  %-16s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@printf '\nExamples:\n  make build\n  make download\n  make download MODEL=base.en\n  make run MODEL=base.en AUDIO=/path/to/audio.wav ARGS="--output-txt"\n  make build ENABLE_CUDA=1 CUDA_ARCHS=auto\n'

doctor: ## Check compilers, CMake, and enabled accelerator dependencies
	@CONFIG_FROM_MAKE=1 "$(ROOT_DIR)/scripts/doctor.sh"

source: ## Fetch the configured whisper.cpp source ref without installing it
	@CONFIG_FROM_MAKE=1 "$(ROOT_DIR)/scripts/source.sh"

update-source: ## Force-refresh the configured source ref
	@CONFIG_FROM_MAKE=1 SOURCE_UPDATE=1 "$(ROOT_DIR)/scripts/source.sh"

configure: ## Run checks, fetch source, and generate the native Release build
	@CONFIG_FROM_MAKE=1 "$(ROOT_DIR)/scripts/doctor.sh"
	@CONFIG_FROM_MAKE=1 "$(ROOT_DIR)/scripts/source.sh"
	@CONFIG_FROM_MAKE=1 "$(ROOT_DIR)/scripts/configure.sh"

build: ## Compile only whisper-cli and stage it under OUTPUT_DIR
	@CONFIG_FROM_MAKE=1 "$(ROOT_DIR)/scripts/doctor.sh"
	@CONFIG_FROM_MAKE=1 "$(ROOT_DIR)/scripts/source.sh"
	@CONFIG_FROM_MAKE=1 "$(ROOT_DIR)/scripts/configure.sh"
	@CONFIG_FROM_MAKE=1 "$(ROOT_DIR)/scripts/build.sh"
	@CONFIG_FROM_MAKE=1 "$(ROOT_DIR)/scripts/verify.sh"

rebuild: ## Remove build products, then rebuild from scratch
	@$(MAKE) --no-print-directory clean
	@$(MAKE) --no-print-directory build

verify: ## Verify the staged whisper-cli and dynamic dependencies
	@CONFIG_FROM_MAKE=1 "$(ROOT_DIR)/scripts/verify.sh"

info: ## Print the effective build configuration
	@CONFIG_FROM_MAKE=1 "$(ROOT_DIR)/scripts/print-config.sh"

print-config: info ## Alias for make info

models: ## Print the complete curated GGML model table
	@CONFIG_FROM_MAKE=1 "$(ROOT_DIR)/scripts/download-model.sh" --list

download: ## Interactively select a model, or use MODEL=<name>
	@CONFIG_FROM_MAKE=1 MODEL="$(MODEL)" HF_TOKEN="$(HF_TOKEN)" "$(ROOT_DIR)/scripts/download-model.sh"

run: ## Run staged whisper-cli; requires AUDIO=..., MODEL defaults to base.en
	@CONFIG_FROM_MAKE=1 MODEL="$(MODEL)" AUDIO="$(AUDIO)" RUN_ARGS="$(ARGS)" "$(ROOT_DIR)/scripts/run.sh"

test: ## Run syntax, manifest, and end-to-end wrapper tests
	@"$(ROOT_DIR)/tests/run.sh"

clean: ## Remove CMake build and staged binary; preserve models and source
	@CONFIG_FROM_MAKE=1 "$(ROOT_DIR)/scripts/clean.sh" build

distclean: ## Also remove the managed whisper.cpp source; preserve models
	@CONFIG_FROM_MAKE=1 "$(ROOT_DIR)/scripts/clean.sh" distclean

purge: ## Remove build, source, binary, and downloaded models; requires CONFIRM=YES
	@CONFIG_FROM_MAKE=1 CONFIRM="$(CONFIRM)" "$(ROOT_DIR)/scripts/clean.sh" purge
