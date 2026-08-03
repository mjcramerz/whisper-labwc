# Model catalog

`models.tsv` is the single source of truth for `make models` and `make download`.
Its 39 entries contain:

- every model accepted by whisper.cpp v1.9.1's `download-ggml-model.sh`;
- additional official English Q8 files present in the upstream model repository;
- official GGML Distil-Whisper checkpoints for small, medium, large-v2, large-v3,
  and large-v3.5.

The RAM and CPU columns are conservative desktop planning estimates, not upstream
minimum requirements. Actual memory and speed depend on CPU generation, memory
bandwidth, GPU offload, audio duration, thread count, model quantization, and other
concurrent workloads. Parameter counts are approximate.

Every Distil-Whisper checkpoint in this catalog is English-only. Some official
Distil repositories use historical architecture-based file names; the downloader
preserves the source URL in a `.meta` sidecar while saving a consistent local name.
All selected Distil files are already in the GGML format expected by whisper.cpp;
the wrapper never downloads PyTorch or safetensors weights under a GGML name.
