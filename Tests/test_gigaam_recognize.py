import importlib.util
import sys
import tempfile
import types
import unittest
import wave
from pathlib import Path
from unittest.mock import Mock, patch


spec = importlib.util.spec_from_file_location(
    "gigaam_recognize", Path(__file__).resolve().parents[1] / "scripts/gigaam_recognize.py"
)
recognize = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recognize)


class RecognizerTests(unittest.TestCase):
    def test_default_uses_pinned_hf_and_cache(self):
        model = Mock()
        auto = Mock()
        auto.from_pretrained.return_value = model
        with patch.dict(sys.modules, {"transformers": types.SimpleNamespace(AutoModel=auto)}):
            self.assertIs(recognize.load_model("v3_e2e_rnnt", "/cache"), model.eval.return_value)
        auto.from_pretrained.assert_called_once_with(
            "ai-sage/GigaAM-v3", revision=recognize.HF_REVISION,
            code_revision=recognize.HF_REVISION, trust_remote_code=True, cache_dir="/cache"
        )
        self.assertEqual(recognize.HF_REVISION, "7655ad717f8122257385bb4b2f373db3697e8680")

    def test_default_without_cache_and_failure_does_not_fallback(self):
        auto = Mock()
        auto.from_pretrained.side_effect = RuntimeError("offline")
        upstream = Mock()
        with patch.dict(sys.modules, {"transformers": types.SimpleNamespace(AutoModel=auto), "gigaam": upstream}):
            with self.assertRaisesRegex(RuntimeError, "offline"):
                recognize.load_model("v3_e2e_rnnt", None)
        self.assertNotIn("cache_dir", auto.from_pretrained.call_args.kwargs)
        upstream.load_model.assert_not_called()

    def test_other_models_use_upstream(self):
        upstream = Mock()
        with patch.dict(sys.modules, {"gigaam": upstream}):
            recognize.load_model("v3_ctc", "/cache")
            recognize.load_model("e2e_rnnt", None)
        self.assertEqual(upstream.load_model.call_args_list[0].kwargs, {"download_root": "/cache"})
        upstream.load_model.assert_called_with("e2e_rnnt")

    def test_pcm_chunks_and_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            audio = str(Path(directory) / "audio.wav")
            rate = 1000
            # The only quiet window in the search range is at 21 seconds.
            data = b'\x01\x01' * (21 * rate) + b'\x00\x00' * 100 + b'\x01\x01' * (14 * rate - 100)
            with wave.open(audio, 'wb') as wav:
                wav.setparams((1, 2, rate, 0, 'NONE', 'not compressed'))
                wav.writeframes(data)
            chunks = []
            paths = []
            def infer(path):
                paths.append(Path(path))
                with wave.open(path, 'rb') as wav:
                    chunks.append(wav.readframes(wav.getnframes()))
                return types.SimpleNamespace(text=f' part{len(chunks)} ')
            model = Mock()
            model.transcribe.side_effect = infer
            self.assertEqual(recognize.transcribe(model, audio), 'part1 part2')
            self.assertEqual(len(chunks[0]) // 2, 21050)
            self.assertTrue(all(len(chunk) <= 24 * rate * 2 for chunk in chunks))
            self.assertEqual(b''.join(chunks), data)
            self.assertTrue(all(not path.exists() for path in paths))
            model.transcribe_longform.assert_not_called()
            def fail(path):
                paths.append(Path(path))
                raise RuntimeError('inference failed')
            model.transcribe.side_effect = fail
            with self.assertRaisesRegex(RuntimeError, 'inference failed'):
                recognize.transcribe(model, audio)
            self.assertFalse(paths[-1].exists())

    def test_cli_writes_only_text(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "transcript"
            argv = ["script", "--model", "v3_ctc", "--audio", "audio.wav", "--output", str(output)]
            model = Mock()
            model.transcribe.return_value = "Привет"
            with patch.object(sys, "argv", argv), patch.object(recognize, "load_model", return_value=model), patch.object(recognize.wave, "open") as wav:
                wav.return_value.__enter__.return_value.getnframes.return_value = 1
                wav.return_value.__enter__.return_value.getframerate.return_value = 16000
                recognize.main()
            self.assertEqual(output.read_text(encoding="utf-8"), "Привет")
            model.transcribe.assert_called_once_with("audio.wav")
            output.unlink()
            model.transcribe.return_value = ["not text"]
            with patch.object(sys, "argv", argv), patch.object(recognize, "load_model", return_value=model), patch.object(recognize.wave, "open") as wav:
                wav.return_value.__enter__.return_value.getnframes.return_value = 1
                wav.return_value.__enter__.return_value.getframerate.return_value = 16000
                with self.assertRaises(TypeError):
                    recognize.main()
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
