#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scripts="$root/.agents/skills/meeting-minutes/scripts"
capture="${1:?Pass the completed recording directory.}"
python="$root/build/funasr-venv/bin/python"
transcript="$capture/transcript.sensevoice.json"

: "${OPENAI_API_KEY:?Set OPENAI_API_KEY before enabling cloud minutes.}"
: "${NOTION_TOKEN:?Set NOTION_TOKEN before enabling Notion sync.}"
: "${NOTION_PARENT_PAGE_ID:?Set NOTION_PARENT_PAGE_ID before enabling Notion sync.}"

if [ ! -f "$transcript" ]; then
  "$python" "$scripts/transcribe_capture.py" "$capture" >&2
fi
"$python" "$scripts/publish_minutes.py" "$transcript" --sync
