import Foundation
import MimirCore

// Avaliador offline do Whisper: roda cada modelo sobre uma pasta de pares
// `nome.wav` (16 kHz mono) + `nome.txt` (texto correto) e imprime a taxa de
// erro por palavra (WER) e a velocidade. Uso:
//
//   swift run -c release MimirEval <pasta> --model <id> [--model <id> ...]
//       [--vocab <arquivo, um termo por linha>] [--language pt] [--no-prompt]

func normalizedWords(_ text: String) -> [String] {
    text.lowercased()
        .folding(options: .diacriticInsensitive, locale: nil)
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
}

/// Distância de edição em palavras (substituição, inserção e remoção custam 1).
func wordErrors(reference: [String], hypothesis: [String]) -> Int {
    var previous = Array(0...hypothesis.count)
    for (i, refWord) in reference.enumerated() {
        var current = [i + 1] + Array(repeating: 0, count: hypothesis.count)
        for (j, hypWord) in hypothesis.enumerated() {
            current[j + 1] = min(
                previous[j] + (refWord == hypWord ? 0 : 1),
                previous[j + 1] + 1,
                current[j] + 1
            )
        }
        previous = current
    }
    return previous[hypothesis.count]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(2)
}

var arguments = Array(CommandLine.arguments.dropFirst())

// Modo de limpeza: `MimirEval --polish <entrada.json> <saida.json> [--model <id>] [--vocab file]`.
// Entrada: [{"id": "...", "raw": "..."}]. Saída: [{"id", "output", "seconds"}].
// Não imprime texto de ditado, só o progresso.
if arguments.first == "--polish" {
    struct PolishInput: Decodable { let id: String; let raw: String }
    struct PolishOutput: Encodable { let id: String; let output: String; let seconds: Double }
    guard arguments.count >= 3 else { fail("usage: MimirEval --polish <in.json> <out.json> [--model id] [--vocab file]") }
    let inputPath = arguments[1], outputPath = arguments[2]
    var modelID = MLXPostProcessor.defaultModelID
    var polishVocabulary = ""
    var rest = Array(arguments.dropFirst(3))
    while !rest.isEmpty {
        let flag = rest.removeFirst()
        guard !rest.isEmpty else { fail("\(flag) needs a value") }
        let value = rest.removeFirst()
        switch flag {
        case "--model": modelID = value
        case "--vocab":
            guard let contents = try? String(contentsOfFile: value, encoding: .utf8) else { fail("cannot read \(value)") }
            polishVocabulary = contents
        default: fail("unknown flag \(flag)")
        }
    }
    guard let data = FileManager.default.contents(atPath: inputPath),
          let inputs = try? JSONDecoder().decode([PolishInput].self, from: data) else { fail("cannot read \(inputPath)") }
    let processor = MLXPostProcessor(modelID: modelID, style: .cleanDictation, customVocabulary: polishVocabulary)
    let loadStart = Date()
    await processor.preload()
    FileHandle.standardError.write("loaded \(modelID) in \(String(format: "%.1f", Date().timeIntervalSince(loadStart)))s\n".data(using: .utf8)!)
    var outputs = [PolishOutput]()
    for (index, input) in inputs.enumerated() {
        let prepared = DictationTextCleaner.stripMidTextFarewells(input.raw)
        let start = Date()
        let output = (try? await processor.polish(prepared, intent: .defaults)) ?? prepared
        outputs.append(PolishOutput(id: input.id, output: output, seconds: Date().timeIntervalSince(start)))
        if index % 20 == 0 { FileHandle.standardError.write("\(index)/\(inputs.count)\n".data(using: .utf8)!) }
    }
    let encoded = try JSONEncoder().encode(outputs)
    FileManager.default.createFile(atPath: outputPath, contents: encoded)
    exit(0)
}

var models = [String]()
var vocabulary = ""
var language: String?
var usesPrompt = true
var directory: String?

while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    switch argument {
    case "--model":
        guard !arguments.isEmpty else { fail("--model needs a value") }
        models.append(arguments.removeFirst())
    case "--vocab":
        guard !arguments.isEmpty else { fail("--vocab needs a file") }
        let path = arguments.removeFirst()
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { fail("cannot read \(path)") }
        vocabulary = contents
    case "--language":
        guard !arguments.isEmpty else { fail("--language needs a value") }
        language = arguments.removeFirst()
    case "--no-prompt":
        usesPrompt = false
    default:
        directory = argument
    }
}

guard let directory, !models.isEmpty else {
    fail("usage: MimirEval <dir> --model <id> [--model <id>] [--vocab file] [--language pt] [--no-prompt]")
}

let directoryURL = URL(fileURLWithPath: directory)
let audioFiles = ((try? FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)) ?? [])
    .filter { $0.pathExtension == "wav" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
guard !audioFiles.isEmpty else { fail("no .wav files in \(directory)") }

for model in models {
    let provider = WhisperKitProvider(modelName: model, strategy: .chunked, vocabulary: vocabulary, usesPrompt: usesPrompt)
    let loadStart = Date()
    await provider.preload()
    print("\n== \(model) (prompt=\(usesPrompt), load \(String(format: "%.1f", Date().timeIntervalSince(loadStart)))s)")

    var totalErrors = 0
    var totalWords = 0
    var totalSeconds = 0.0
    var totalAudio = 0.0
    for audioURL in audioFiles {
        let referenceURL = audioURL.deletingPathExtension().appendingPathExtension("txt")
        guard let referenceText = try? String(contentsOf: referenceURL, encoding: .utf8) else {
            print("  \(audioURL.lastPathComponent): no .txt, skipped")
            continue
        }
        await provider.resetSessionLanguage()
        let start = Date()
        let hypothesis: String
        var detected = "?"
        var audioSeconds = 0.0
        do {
            let transcription = try await provider.transcribe(audioFileURL: audioURL, languageHint: language)
            hypothesis = transcription.text
            detected = transcription.metrics?.languageHint ?? transcription.language ?? "?"
            audioSeconds = transcription.metrics?.inputAudioSeconds ?? 0
        } catch {
            hypothesis = ""
        }
        let elapsed = Date().timeIntervalSince(start)
        let reference = normalizedWords(referenceText)
        let errors = wordErrors(reference: reference, hypothesis: normalizedWords(hypothesis))
        totalErrors += errors
        totalWords += reference.count
        totalSeconds += elapsed
        totalAudio += audioSeconds
        let wer = reference.isEmpty ? 0 : Double(errors) / Double(reference.count) * 100
        print(String(format: "  %@ lang=%@ WER %.1f%% (%d/%d) %.2fs", audioURL.lastPathComponent, detected, wer, errors, reference.count, elapsed))
        print("    > \(hypothesis)")
    }
    let wer = totalWords == 0 ? 0 : Double(totalErrors) / Double(totalWords) * 100
    print(String(format: "  TOTAL WER %.1f%% (%d/%d words), %.1fs for %.0fs of audio", wer, totalErrors, totalWords, totalSeconds, totalAudio))
}
