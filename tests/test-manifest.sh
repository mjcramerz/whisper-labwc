#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
manifest="$ROOT_DIR/models/models.tsv"
[[ -s "$manifest" ]]

awk -F'\t' '
BEGIN { errors=0; records=0 }
/^#/ || $1 == "id" || NF == 0 { next }
NF != 14 { printf "line %d: expected 14 fields, got %d\n", NR, NF > "/dev/stderr"; errors=1; next }
{
    records++
    id=$1; family=$2; params=$3; file_mib=$4; min_ram=$5; rec_ram=$6; cores=$7
    language=$8; precision=$9; local_name=$10; algo=$11; checksum=$12; url=$13; notes=$14

    if (seen_id[id]++) { printf "duplicate id: %s\n", id > "/dev/stderr"; errors=1 }
    if (seen_file[local_name]++) { printf "duplicate local filename: %s\n", local_name > "/dev/stderr"; errors=1 }
    if (family == "") { printf "empty family for %s\n", id > "/dev/stderr"; errors=1 }
    if (params !~ /^[1-9][0-9]*$/) { printf "bad parameter count for %s\n", id > "/dev/stderr"; errors=1 }
    if (file_mib !~ /^[1-9][0-9]*$/) { printf "bad file size for %s\n", id > "/dev/stderr"; errors=1 }
    if (min_ram !~ /^[1-9][0-9]*$/ || rec_ram !~ /^[1-9][0-9]*$/ || rec_ram+0 < min_ram+0) {
        printf "bad RAM estimate for %s\n", id > "/dev/stderr"; errors=1
    }
    if (cores !~ /^[1-9][0-9]*(-[1-9][0-9]*)?$/) { printf "bad CPU recommendation for %s\n", id > "/dev/stderr"; errors=1 }
    if (language != "en" && language != "multi") { printf "bad language for %s\n", id > "/dev/stderr"; errors=1 }
    if (precision == "") { printf "empty precision for %s\n", id > "/dev/stderr"; errors=1 }
    if (local_name !~ /^ggml-.*\.bin$/) { printf "bad local filename for %s: %s\n", id, local_name > "/dev/stderr"; errors=1 }
    if (url !~ /^https:\/\//) { printf "non-HTTPS URL for %s\n", id > "/dev/stderr"; errors=1 }
    if (notes == "") { printf "empty notes for %s\n", id > "/dev/stderr"; errors=1 }

    if (algo != "-" && algo != "sha1" && algo != "sha256") { printf "bad checksum algorithm for %s\n", id > "/dev/stderr"; errors=1 }
    if (algo == "-" && checksum != "-") { printf "checksum without algorithm for %s\n", id > "/dev/stderr"; errors=1 }
    if (algo == "sha1" && (length(checksum) != 40 || checksum !~ /^[0-9a-f]+$/)) { printf "bad sha1 for %s\n", id > "/dev/stderr"; errors=1 }
    if (algo == "sha256" && (length(checksum) != 64 || checksum !~ /^[0-9a-f]+$/)) { printf "bad sha256 for %s\n", id > "/dev/stderr"; errors=1 }

    if (id ~ /^distil-/) {
        if (language != "en") { printf "Distil model is not marked English-only: %s\n", id > "/dev/stderr"; errors=1 }
        if (url !~ /^https:\/\/huggingface\.co\/distil-whisper\//) { printf "unexpected Distil source for %s\n", id > "/dev/stderr"; errors=1 }
    }
}
END {
    if (records != 39) { printf "expected 39 model records, got %d\n", records > "/dev/stderr"; errors=1 }
    exit errors
}
' "$manifest"

required_models=(
    tiny tiny.en tiny-q5_1 tiny.en-q5_1 tiny-q8_0 tiny.en-q8_0
    base base.en base-q5_1 base.en-q5_1 base-q8_0 base.en-q8_0
    small small.en small.en-tdrz small-q5_1 small.en-q5_1 small-q8_0 small.en-q8_0
    medium medium.en medium-q5_0 medium.en-q5_0 medium-q8_0 medium.en-q8_0
    large-v1 large-v2 large-v2-q5_0 large-v2-q8_0
    large-v3 large-v3-q5_0 large-v3-turbo large-v3-turbo-q5_0 large-v3-turbo-q8_0
    distil-small.en distil-medium.en distil-large-v2 distil-large-v3 distil-large-v3.5
)
for model in "${required_models[@]}"; do
    awk -F'\t' -v model="$model" '$1 == model { found=1 } END { exit !found }' "$manifest" \
        || { printf 'required model is missing: %s\n' "$model" >&2; exit 1; }
done
