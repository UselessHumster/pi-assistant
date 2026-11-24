import Foundation

protocol RecognitionEngine {
    func transcribe(_ audio: URL, cancellation: ProcessCancellation?) throws -> String
}

extension RecognitionEngine {
    func transcribe(_ audio: URL) throws -> String { try transcribe(audio, cancellation: nil) }
}

struct CommandRecognizer: RecognitionEngine {
    let executable: String
    let arguments: (URL, URL) -> [String]

    func transcribe(_ audio: URL, cancellation: ProcessCancellation?) throws -> String {
        let directory = audio.deletingLastPathComponent()
        let output = directory.appendingPathComponent("transcript.txt")
        _ = try run(executable, arguments(audio, output), directory: directory, cancellation: cancellation)
        return try String(contentsOf: output, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

func makeRecognizer(engine: String, whisper: String, model: String, python: String, gigaamModel: String, cache: String, script: String) throws -> RecognitionEngine {
    switch engine.lowercased() {
    case "whisper":
        guard !whisper.isEmpty, model.hasPrefix("/") else { throw Failure.message("Configure whisper-cli and an absolute Whisper model path.") }
        return CommandRecognizer(executable: whisper) { audio, output in
            ["-m", model, "-f", audio.path, "-otxt", "-of", output.deletingPathExtension().path]
        }
    case "gigaam":
        guard !python.isEmpty, !gigaamModel.isEmpty, !script.isEmpty else { throw Failure.message("Configure GigaAM Python and model name; ensure the app contains its recognition script.") }
        guard cache.isEmpty || cache.hasPrefix("/") else { throw Failure.message("GigaAM cache directory must be an absolute path.") }
        return CommandRecognizer(executable: python) { audio, output in
            [script, "--model", gigaamModel, "--audio", audio.path, "--output", output.path] + (cache.isEmpty ? [] : ["--cache", cache])
        }
    default:
        throw Failure.message("Unknown recognition engine: \(engine). Choose whisper or gigaam.")
    }
}
