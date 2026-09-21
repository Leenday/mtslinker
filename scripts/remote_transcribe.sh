#!/usr/bin/env bash
# Run transcribe_lecture.sh on a remote machine over SSH, then pull the
# finished transcript + slides back to this machine. Run this ONE script
# from your local Mac; the download/mix/transcribe work happens entirely
# on the remote host.
#
# Usage:
#   ./scripts/remote_transcribe.sh '<mts-link-url>' <ssh-host> \
#       <remote-repo-dir> <remote-output-base-dir> [local-dest-dir]
#
# Example:
#   ./scripts/remote_transcribe.sh \
#       'https://my.mts-link.ru/.../record-file/2072931683' \
#       pgs \
#       ~/programs/mtslinker \
#       /mnt/external_drive/lectures/output_2072931683 \
#       ~/Desktop/lectures/received
#
# <ssh-host> must already work as a plain `ssh <ssh-host>` from this
# machine (an entry in ~/.ssh/config, or user@host / user@ip directly).
#
# Only the finished artifacts are copied back — transcript, subtitles,
# slide images/PDF, manifest. The raw downloaded video chunks and
# intermediate audio (.mp4/.m4a/.wav) stay on the remote machine.
#
# Any of transcribe_lecture.sh's own config env vars (MTSLINKER_IMAGE,
# WHISPER_IMAGE, WHISPER_MODELS_DIR, WHISPER_MODEL, VAD_MODEL, WHISPER_LANG,
# WHISPER_THREADS, LECTURE_DIR) can be set in THIS script's environment and
# are forwarded to the remote run, e.g. to point at whisper models you
# already have on the remote machine instead of downloading fresh ones:
#   WHISPER_MODELS_DIR=/mnt/external_drive/lectures/whisper/models \
#       ./scripts/remote_transcribe.sh ...

set -euo pipefail

REMOTE_ENV=""
for var in MTSLINKER_IMAGE WHISPER_IMAGE WHISPER_MODELS_DIR WHISPER_MODEL \
           VAD_MODEL WHISPER_LANG WHISPER_THREADS LECTURE_DIR; do
    if [ -n "${!var:-}" ]; then
        REMOTE_ENV="$REMOTE_ENV $var='${!var}'"
    fi
done

if [ $# -lt 4 ]; then
    echo "Usage: $0 '<mts-link-url>' <ssh-host> <remote-repo-dir> <remote-output-base-dir> [local-dest-dir]" >&2
    exit 1
fi

URL="$1"
SSH_HOST="$2"
REMOTE_REPO_DIR="$3"
REMOTE_OUT_BASE="$4"
LOCAL_DEST="${5:-$PWD/received}"

mkdir -p "$LOCAL_DEST"

echo "== Running pipeline on $SSH_HOST (this can take a while for a multi-hour lecture) =="
# REMOTE_REPO_DIR is deliberately left unquoted in the remote command below
# so the remote shell expands a leading '~' itself — quoting it would send
# a literal tilde character and cd would fail with "no such file".
OUTPUT=$(ssh "$SSH_HOST" "cd $REMOTE_REPO_DIR &&$REMOTE_ENV ./scripts/transcribe_lecture.sh '$URL' '$REMOTE_OUT_BASE'")
echo "$OUTPUT"

RESULT_DIR=$(printf '%s\n' "$OUTPUT" | grep '^RESULT_DIR=' | tail -1 | cut -d= -f2-)
if [ -z "$RESULT_DIR" ]; then
    echo "Could not find RESULT_DIR in remote output — something failed remotely, see log above." >&2
    exit 1
fi

echo
echo "== Pulling finished artifacts back to $LOCAL_DEST =="
rsync -avz -e ssh \
    --include='*/' \
    --include='*_transcript.txt' \
    --include='*_transcript.srt' \
    --include='*_slides.pdf' \
    --include='slides_manifest.json' \
    --include='slides/*' \
    --exclude='*' \
    "$SSH_HOST:$RESULT_DIR/" "$LOCAL_DEST/"

echo
echo "== Done =="
echo "Results in: $LOCAL_DEST"
ls -la "$LOCAL_DEST"
