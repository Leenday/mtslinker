#!/usr/bin/env bash
# Thin wrapper around remote_transcribe.sh that only takes a URL —
# everything else (SSH host, remote/local paths, whisper config) comes
# from scripts/lecture.config, a local file you create once from
# scripts/lecture.config.example. That config file is gitignored and
# never gets committed, so your host/IP/paths never touch GitHub.
#
# Setup (once):
#   cp scripts/lecture.config.example scripts/lecture.config
#   # edit scripts/lecture.config with your real values
#
# Usage (every time after that):
#   ./scripts/lecture.sh '<mts-link-url>'

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/lecture.config"

if [ $# -lt 1 ]; then
    echo "Usage: $0 '<mts-link-url>'" >&2
    exit 1
fi
URL="$1"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Missing $CONFIG_FILE" >&2
    echo "Set it up once with:" >&2
    echo "  cp scripts/lecture.config.example scripts/lecture.config" >&2
    echo "  # then edit scripts/lecture.config with your real SSH host and paths" >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG_FILE"

for var in SSH_HOST REMOTE_REPO_DIR REMOTE_OUT_BASE LOCAL_DEST; do
    if [ -z "${!var:-}" ]; then
        echo "scripts/lecture.config is missing a value for $var" >&2
        exit 1
    fi
done

env \
    ${WHISPER_MODELS_DIR:+WHISPER_MODELS_DIR="$WHISPER_MODELS_DIR"} \
    ${WHISPER_MODEL:+WHISPER_MODEL="$WHISPER_MODEL"} \
    ${VAD_MODEL:+VAD_MODEL="$VAD_MODEL"} \
    ${WHISPER_LANG:+WHISPER_LANG="$WHISPER_LANG"} \
    ${WHISPER_THREADS:+WHISPER_THREADS="$WHISPER_THREADS"} \
    ${MTSLINKER_IMAGE:+MTSLINKER_IMAGE="$MTSLINKER_IMAGE"} \
    ${WHISPER_IMAGE:+WHISPER_IMAGE="$WHISPER_IMAGE"} \
    ${LECTURE_DIR:+LECTURE_DIR="$LECTURE_DIR"} \
    "$SCRIPT_DIR/remote_transcribe.sh" \
    "$URL" \
    "$SSH_HOST" \
    "$REMOTE_REPO_DIR" \
    "$REMOTE_OUT_BASE" \
    "$LOCAL_DEST"
