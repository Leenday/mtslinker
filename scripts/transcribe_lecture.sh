#!/usr/bin/env bash
# Paste an MTS-Link lecture URL in, get a transcript + slides out.
#
# Pipeline: mtslinker (--audio-only --slides-only) -> ffmpeg (m4a -> 16kHz
# mono wav) -> whisper.cpp with VAD (the plain no-speech-threshold heuristic
# mis-classifies long stretches of real speech as blank on multi-track mixed
# lecture audio; VAD measures actual speech energy instead and doesn't have
# that problem).
#
# Usage:
#   ./scripts/transcribe_lecture.sh '<mts-link-url>' [output_base_dir]
#
# Config via env vars (all optional):
#   MTSLINKER_IMAGE   default: mtslinker-fixed
#   WHISPER_IMAGE     default: ghcr.io/ggml-org/whisper.cpp:main
#   WHISPER_MODELS_DIR  default: ./whisper_models
#   WHISPER_MODEL     default: ggml-base.bin
#   VAD_MODEL         default: ggml-silero-v5.1.2.bin
#   WHISPER_LANG      default: en
#   WHISPER_THREADS   default: 4

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 '<mts-link-url>' [output_base_dir]" >&2
    exit 1
fi

URL="$1"
OUT_BASE="${2:-$PWD}"

docker_mkdir_p() {
    # mkdir -p that works even when the target lives on a filesystem that
    # denies directory creation to the invoking user (e.g. an external
    # drive mounted exFAT with a fixed uid) — creates it as root inside a
    # container instead. Finds the nearest existing ancestor and bind-mounts
    # *that* (never a not-yet-existing path — letting Docker auto-create a
    # bind-mount source triggers a chown that exFAT rejects outright, even
    # for root).
    local target="$1" parent
    parent="$target"
    while [ ! -d "$parent" ]; do
        parent="$(dirname "$parent")"
    done
    if [ "$parent" = "$target" ]; then
        return 0
    fi
    docker run --rm -v "$parent:/parent" --entrypoint mkdir "$MTSLINKER_IMAGE" \
        -p "/parent/${target#"$parent"/}"
}

MTSLINKER_IMAGE="${MTSLINKER_IMAGE:-mtslinker-fixed}"
WHISPER_IMAGE="${WHISPER_IMAGE:-ghcr.io/ggml-org/whisper.cpp:main}"
MODELS_DIR="${WHISPER_MODELS_DIR:-$OUT_BASE/whisper_models}"
WHISPER_MODEL="${WHISPER_MODEL:-ggml-base.bin}"
VAD_MODEL="${VAD_MODEL:-ggml-silero-v5.1.2.bin}"
LANG="${WHISPER_LANG:-en}"
THREADS="${WHISPER_THREADS:-4}"

docker_mkdir_p "$OUT_BASE"
docker_mkdir_p "$MODELS_DIR"

if [ ! -f "$MODELS_DIR/$WHISPER_MODEL" ]; then
    echo "Missing whisper model: $MODELS_DIR/$WHISPER_MODEL" >&2
    echo "Download one first, e.g.:" >&2
    echo "  curl -L -o '$MODELS_DIR/$WHISPER_MODEL' https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$WHISPER_MODEL" >&2
    exit 1
fi

echo "== Step 1/4: downloading audio + slides =="
BEFORE=$(ls -1 "$OUT_BASE" 2>/dev/null || true)
docker run --rm -v "$OUT_BASE:/app" "$MTSLINKER_IMAGE" "$URL" --audio-only --slides-only
AFTER=$(ls -1 "$OUT_BASE")
LECTURE_DIR=$(comm -13 <(printf '%s\n' "$BEFORE" | sort) <(printf '%s\n' "$AFTER" | sort) | head -1)

if [ -z "$LECTURE_DIR" ]; then
    echo "Could not auto-detect the new lecture directory under $OUT_BASE" >&2
    echo "(this happens if you re-run against a lecture you already downloaded)." >&2
    echo "Existing directories:" >&2
    ls -1 "$OUT_BASE" >&2
    echo "Re-run with the directory name appended, e.g.:" >&2
    echo "  LECTURE_DIR=<name> $0 '$URL' '$OUT_BASE'" >&2
    exit 1
fi
echo "Lecture directory: $LECTURE_DIR"

M4A_NAME=$(basename "$(find "$OUT_BASE/$LECTURE_DIR" -maxdepth 1 -name '*.m4a' | head -1)")
if [ -z "$M4A_NAME" ] || [ "$M4A_NAME" = "." ]; then
    echo "No .m4a found in $OUT_BASE/$LECTURE_DIR — audio step must have failed." >&2
    exit 1
fi
BASENAME="${M4A_NAME%.m4a}"
WAV_NAME="${BASENAME}.wav"

echo "== Step 2/4: converting to 16kHz mono wav =="
docker run --rm --entrypoint ffmpeg -v "$OUT_BASE:/app" -w /app "$MTSLINKER_IMAGE" \
    -y -i "$LECTURE_DIR/$M4A_NAME" -ar 16000 -ac 1 -c:a pcm_s16le \
    "$LECTURE_DIR/$WAV_NAME"

echo "== Step 3/4: ensuring VAD model is present =="
if [ ! -f "$MODELS_DIR/$VAD_MODEL" ]; then
    docker run --rm -v "$MODELS_DIR:/models" --entrypoint bash "$WHISPER_IMAGE" \
        -c "curl -L -o /models/$VAD_MODEL https://huggingface.co/ggml-org/whisper-vad/resolve/main/$VAD_MODEL"
fi

echo "== Step 4/4: transcribing (with VAD) =="
docker run --rm \
    -v "$MODELS_DIR:/models" \
    -v "$OUT_BASE/$LECTURE_DIR:/audio" \
    -v "$OUT_BASE/$LECTURE_DIR:/output" \
    "$WHISPER_IMAGE" \
    "whisper-cli \
        -m /models/$WHISPER_MODEL \
        -f /audio/$WAV_NAME \
        -l $LANG \
        -t $THREADS \
        --vad --vad-model /models/$VAD_MODEL \
        -otxt -osrt \
        -of /output/${BASENAME}_transcript"

SLIDES_PDF=$(find "$OUT_BASE/$LECTURE_DIR" -maxdepth 1 -name '*_slides.pdf' | head -1)

echo
echo "== Done =="
echo "Transcript:      $OUT_BASE/$LECTURE_DIR/${BASENAME}_transcript.txt"
echo "Subtitles:       $OUT_BASE/$LECTURE_DIR/${BASENAME}_transcript.srt"
if [ -n "$SLIDES_PDF" ]; then
    echo "Slides PDF:      $SLIDES_PDF"
    echo "Slides manifest: $OUT_BASE/$LECTURE_DIR/slides_manifest.json"
else
    echo "Slides:          none for this recording"
fi

# Machine-readable line for orchestration scripts (e.g. remote_transcribe.sh)
# — keep this the last line of output.
echo "RESULT_DIR=$OUT_BASE/$LECTURE_DIR"
