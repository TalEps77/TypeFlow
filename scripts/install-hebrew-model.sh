#!/usr/bin/env bash
# install-hebrew-model.sh — fetch the ivrit.ai Hebrew Whisper model for TypeFlow
#
# TypeFlow can run a Hebrew fine-tune of Whisper Large v3 Turbo, converted to
# CoreML for WhisperKit. The app treats it as side-loaded: it never downloads or
# deletes it itself, and shows the entry as "Not Installed" until the files are
# in place. This script puts them there.
#
# Source: https://huggingface.co/eranshir/ivrit-ai-whisper-large-v3-turbo-coreml
#         (MIT) — CoreML conversion by Eran Shir of
#         https://huggingface.co/ivrit-ai/whisper-large-v3-turbo (Apache-2.0)
#
# Usage:
#   ./scripts/install-hebrew-model.sh            # download (~1.5 GB) into place
#   ./scripts/install-hebrew-model.sh --dry-run  # list what would be fetched
#
# Only curl is required. Downloads resume if interrupted; re-running is safe.
set -euo pipefail

REPO="eranshir/ivrit-ai-whisper-large-v3-turbo-coreml"
MODEL_DIR_NAME="ivrit-ai_whisper-large-v3-turbo"
DEST="${TYPEFLOW_MODEL_DEST:-$HOME/Library/Application Support/VocaMac/models/models/argmaxinc/whisperkit-coreml/$MODEL_DIR_NAME}"
DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

command -v curl >/dev/null || { echo "curl is required." >&2; exit 1; }

echo "TypeFlow — Hebrew model installer"
echo "  source : https://huggingface.co/$REPO"
echo "  target : $DEST"
echo

# Ask Hugging Face for the file list rather than hardcoding it, so an updated
# conversion with extra files still installs completely.
LISTING="$(curl -fsSL --retry 3 "https://huggingface.co/api/models/$REPO")" \
    || { echo "Could not reach huggingface.co to list the model files." >&2; exit 1; }
FILES="$(printf '%s' "$LISTING" | grep -o '"rfilename":"[^"]*"' | sed 's/"rfilename":"\(.*\)"/\1/' | grep -v '^\.gitattributes$')"
COUNT="$(printf '%s\n' "$FILES" | grep -c .)"
[ "$COUNT" -gt 0 ] || { echo "Hugging Face returned an empty file list — aborting." >&2; exit 1; }

if $DRY_RUN; then
    echo "Would download $COUNT files:"
    printf '%s\n' "$FILES" | sed 's/^/  /'
    exit 0
fi

mkdir -p "$DEST"
i=0
while IFS= read -r f; do
    i=$((i+1))
    printf '[%2d/%d] %s\n' "$i" "$COUNT" "$f"
    mkdir -p "$DEST/$(dirname "$f")"
    # -C - resumes a partial file; --fail turns HTTP errors into a non-zero exit.
    curl -fL --retry 3 -C - --progress-bar \
        -o "$DEST/$f" "https://huggingface.co/$REPO/resolve/main/$f"
done <<< "$FILES"

# The app checks for the model components AND the tokenizer files; without the
# latter a copy reports as installed and then fails to load.
for required in AudioEncoder.mlmodelc TextDecoder.mlmodelc MelSpectrogram.mlmodelc tokenizer.json config.json; do
    [ -e "$DEST/$required" ] || { echo "Missing $required after download — aborting." >&2; exit 1; }
done

echo
echo "Done. $(du -sh "$DEST" | cut -f1) installed."
echo "In TypeFlow open Settings → Models and select \"ivrit.ai Hebrew (Large v3 Turbo)\"."
echo "If TypeFlow is already running, quit and relaunch it so it re-scans the models folder."
