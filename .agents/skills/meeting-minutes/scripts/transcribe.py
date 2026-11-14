#!/usr/bin/env python3
"""Run local whisper.cpp and write a timestamped transcript."""

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("media", type=Path, help="Audio or video file")
    parser.add_argument("--output", required=True, type=Path, help="New .srt file")
    parser.add_argument("--model", type=Path, default=os.getenv("WHISPER_MODEL") or "models/ggml-large-v3-turbo.bin")
    parser.add_argument("--language", choices=("zh", "en", "auto"), default="auto")
    parser.add_argument("--glossary", type=Path, help="UTF-8 text with names and terms")
    args = parser.parse_args()

    if not args.media.is_file():
        parser.error("The input file does not exist.")
    if args.model is None or not args.model.expanduser().is_file():
        parser.error("Specify a local multilingual model with --model or WHISPER_MODEL.")
    if args.output.suffix.lower() != ".srt" or args.output.exists():
        parser.error("--output must point to a new .srt file.")

    ffmpeg = shutil.which("ffmpeg")
    whisper = shutil.which("whisper-cli")
    if not ffmpeg or not whisper:
        parser.error("Install ffmpeg and whisper.cpp (whisper-cli). See the project README.")

    try:
        prompt = args.glossary.read_text(encoding="utf-8").strip() if args.glossary else ""
        with tempfile.TemporaryDirectory(prefix="meeting-minutes-") as work:
            wav = Path(work) / "input.wav"
            prefix = Path(work) / "transcript"
            subprocess.run(
                [ffmpeg, "-nostdin", "-hide_banner", "-loglevel", "error",
                 "-i", str(args.media.resolve()), "-map", "0:a:0",
                 "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", str(wav)],
                check=True,
            )
            command = [
                whisper, "-m", str(args.model.expanduser().resolve()),
                "-f", str(wav), "-l", args.language, "-osrt", "-of", str(prefix), "-np",
            ]
            if prompt:
                command.extend(["--prompt", prompt])
            subprocess.run(command, check=True)
            transcript = prefix.with_suffix(".srt").read_text(encoding="utf-8")
            if not transcript.strip():
                raise ValueError("Transcription produced no segments.")
            args.output.parent.mkdir(parents=True, exist_ok=True)
            with args.output.open("x", encoding="utf-8") as output:
                output.write(transcript)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Transcription failed: {error}", file=sys.stderr)
        return 1

    print(args.output.resolve())
    return 0


if __name__ == "__main__":
    sys.exit(main())
