# Primary sources

Verified on 2026-08-03. The build wrapper is pinned to whisper.cpp `v1.9.1` by
default, so version-specific links are used wherever possible.

## whisper.cpp source and build interface

- Release/tag: https://github.com/ggml-org/whisper.cpp/tree/v1.9.1
- Top-level CMake options: https://github.com/ggml-org/whisper.cpp/blob/v1.9.1/CMakeLists.txt
- GGML CMake options: https://github.com/ggml-org/whisper.cpp/blob/v1.9.1/ggml/CMakeLists.txt
- CUDA backend CMake: https://github.com/ggml-org/whisper.cpp/blob/v1.9.1/ggml/src/ggml-cuda/CMakeLists.txt
- HIP backend CMake: https://github.com/ggml-org/whisper.cpp/blob/v1.9.1/ggml/src/ggml-hip/CMakeLists.txt
- Build and accelerator documentation: https://github.com/ggml-org/whisper.cpp/blob/v1.9.1/README.md
- Upstream GGML downloader: https://github.com/ggml-org/whisper.cpp/blob/v1.9.1/models/download-ggml-model.sh
- Upstream model documentation/checksums: https://github.com/ggml-org/whisper.cpp/blob/v1.9.1/models/README.md
- Pre-converted upstream GGML files: https://huggingface.co/ggerganov/whisper.cpp

## Whisper and Distil-Whisper model metadata

- OpenAI Whisper model sizes/capabilities: https://github.com/openai/whisper/blob/main/README.md
- OpenAI Whisper model card: https://github.com/openai/whisper/blob/main/model-card.md
- Distil-Whisper project: https://github.com/huggingface/distil-whisper
- Distil Small English GGML: https://huggingface.co/distil-whisper/distil-small.en
- Distil Medium English GGML: https://huggingface.co/distil-whisper/distil-medium.en
- Distil Large v2 GGML: https://huggingface.co/distil-whisper/distil-large-v2
- Distil Large v3 GGML: https://huggingface.co/distil-whisper/distil-large-v3-ggml
- Distil Large v3.5 GGML: https://huggingface.co/distil-whisper/distil-large-v3.5-ggml

The RAM and CPU recommendations in `models/models.tsv` are engineering estimates
for personal computers, not requirements asserted by the upstream projects.
Parameter counts are approximate where upstream documents use rounded values.
