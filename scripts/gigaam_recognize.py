#!/usr/bin/env python3
"""Run GigaAM locally; keep diagnostics separate from the transcript file."""
import argparse
import struct
import tempfile
import wave
from pathlib import Path


HF_REPOSITORY = "ai-sage/GigaAM-v3"
HF_REVISION = "7655ad717f8122257385bb4b2f373db3697e8680"


def load_model(name, cache):
    if name == "v3_e2e_rnnt":
        # This official model requires its repository's Python code. Pin both
        # code and weights to the reviewed revision; never fall back silently.
        from transformers import AutoModel

        options = {"cache_dir": cache} if cache else {}
        return AutoModel.from_pretrained(
            HF_REPOSITORY, revision=HF_REVISION, code_revision=HF_REVISION,
            trust_remote_code=True, **options
        ).eval()

    import gigaam

    options = {"download_root": cache} if cache else {}
    return gigaam.load_model(name, **options)


def _text(result):
    text = result if isinstance(result, str) else getattr(result, "text", None)
    if not isinstance(text, str):
        raise TypeError("GigaAM returned a non-text transcript")
    return text


def transcribe(model, audio):
    # The recorder produces 16-bit mono PCM. Keep short recordings unchanged.
    with wave.open(audio, "rb") as wav:
        rate, total = wav.getframerate(), wav.getnframes()
        if total <= 24 * rate:
            return _text(model.transcribe(audio))
        if wav.getnchannels() != 1 or wav.getsampwidth() != 2 or wav.getcomptype() != "NONE":
            raise ValueError("Long recordings must be 16-bit mono PCM WAV")
        params = wav.getparams()
        window = max(1, rate // 10)  # 100 ms energy windows
        texts = []
        with tempfile.TemporaryDirectory(prefix="pi-voice-chunks-") as directory:
            path = str(Path(directory) / "chunk.wav")
            start = 0
            while start < total:
                end = min(start + 24 * rate, total)
                if end < total:
                    # Search the final four seconds for the quietest window;
                    # prefer the latest window when energies are equal.
                    search = start + 20 * rate
                    wav.setpos(search)
                    quietest = None
                    while search + window <= end:
                        data = wav.readframes(window)
                        if len(data) != window * 2:
                            raise ValueError("Truncated WAV audio")
                        samples = struct.unpack(f"<{window}h", data)
                        energy = sum(sample * sample for sample in samples)
                        if quietest is None or energy <= quietest[0]:
                            quietest = (energy, search + window // 2)
                        search += window
                    if quietest is not None:
                        end = quietest[1]
                wav.setpos(start)
                data = wav.readframes(end - start)
                if len(data) != (end - start) * 2:
                    raise ValueError("Truncated WAV audio")
                with wave.open(path, "wb") as chunk:
                    chunk.setparams(params)
                    chunk.writeframes(data)
                text = _text(model.transcribe(path)).strip()
                if text:
                    texts.append(text)
                start = end
        return " ".join(texts)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--audio", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--cache")
    args = parser.parse_args()

    model = load_model(args.model, args.cache)
    text = transcribe(model, args.audio)
    Path(args.output).write_text(text, encoding="utf-8")


if __name__ == "__main__":
    main()
