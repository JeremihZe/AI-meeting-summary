#!/usr/bin/env python3
"""Transcribe a completed two-track capture with local SenseVoiceSmall."""

import argparse
import json
import math
from pathlib import Path
import subprocess
import tempfile

MODEL = "iic/SenseVoiceSmall"
VAD = "fsmn-vad"
TRACKS = {"remote": "会议音频", "microphone": "本机麦克风"}


def load_capture(folder):
    capture = json.loads((folder / "capture.json").read_text(encoding="utf-8"))
    if capture.get("complete") is not True:
        raise ValueError("The capture is incomplete.")
    offsets = {}
    for track in TRACKS:
        metadata = capture["tracks"][track]
        if metadata["timestampDiscontinuities"]:
            raise ValueError(f"{track} has timestamp discontinuities. Review the track manually.")
        offset = metadata["startOffsetSeconds"]
        if not math.isfinite(offset) or offset < 0:
            raise ValueError(f"{track} has an invalid start offset.")
        if not (folder / f"{track}.caf").is_file():
            raise ValueError(f"{track}.caf is missing.")
        offsets[track] = round(offset * 1000)
    return offsets


def recognize(model, source, wav, language, clean_text):
    subprocess.run(
        ["ffmpeg", "-nostdin", "-loglevel", "error", "-y",
         "-i", str(source.resolve()), "-ac", "1", "-ar", "16000",
         "-c:a", "pcm_s16le", str(wav)],
        check=True,
    )
    result, = model.generate(
        input=str(wav), language=language, use_itn=True,
        sentence_timestamp=True, merge_vad=False,
    )
    sentences = result.get("sentence_info", [])
    if clean_text(result.get("text", "")).strip() and not sentences:
        raise ValueError(f"{source.name} has recognized text but no timestamped segments.")
    return sentences


def align(sentences, track, offset, clean_text):
    segments = []
    for sentence in sentences:
        text = clean_text(sentence["text"]).strip()
        if not text:
            continue
        start = round(sentence["start"])
        end = round(sentence["end"])
        if start < 0 or end <= start:
            raise ValueError(f"{track} returned an invalid segment interval.")
        segments.append({
            "track": track,
            "source": TRACKS[track],
            "start_ms": start + offset,
            "end_ms": end + offset,
            "text": text,
        })
    return segments


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path, help="Folder containing capture.json and both CAF tracks")
    parser.add_argument("--language", choices=("auto", "zh", "en"), default="auto")
    args = parser.parse_args()
    folder = args.capture
    output = folder / "transcript.sensevoice.json"
    try:
        if output.exists():
            raise ValueError(f"{output.name} already exists. Keep or rename it before rerunning.")
        offsets = load_capture(folder)
        from funasr import AutoModel
        from funasr.utils.postprocess_utils import rich_transcription_postprocess

        model = AutoModel(model=MODEL, vad_model=VAD, device="cpu", disable_update=True)
        segments = []
        with tempfile.TemporaryDirectory(prefix=".sensevoice-", dir=folder) as temp:
            work = Path(temp)
            for track, offset in offsets.items():
                sentences = recognize(
                    model, folder / f"{track}.caf", work / f"{track}.wav",
                    args.language, rich_transcription_postprocess,
                )
                segments.extend(align(sentences, track, offset, rich_transcription_postprocess))
            if not segments:
                raise ValueError("Neither track produced timestamped speech.")
            payload = {
                "model": MODEL, "vad_model": VAD, "language": args.language,
                "segments": sorted(segments, key=lambda segment: segment["start_ms"]),
            }
            staging = work / output.name
            staging.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            output.hardlink_to(staging)
    except (ImportError, KeyError, OSError, TypeError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Transcription failed: {error}\n")
    print(output.resolve())


if __name__ == "__main__":
    main()
