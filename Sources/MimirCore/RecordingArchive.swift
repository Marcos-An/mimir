import Foundation

/// Guarda as últimas gravações (WAV + texto cru do Whisper) para diagnóstico.
/// Só é usado com `AppSettings.keepsRecentRecordings` ligado; fora isso o
/// áudio de um ditado morre junto com a sessão. Cada `nome.wav` vem com um
/// `nome.txt`, que é o formato de entrada do `MimirEval`.
public enum RecordingArchive {
    public static let maxRecordings = 40

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mimir/Recordings", isDirectory: true)
    }

    public static func keep(
        audioAt audioURL: URL,
        rawText: String,
        in directory: URL = defaultDirectory,
        now: Date = Date(),
        limit: Int = maxRecordings
    ) {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
            let base = directory.appendingPathComponent(formatter.string(from: now))
            try fileManager.copyItem(at: audioURL, to: base.appendingPathExtension("wav"))
            try rawText.write(to: base.appendingPathExtension("txt"), atomically: true, encoding: .utf8)
            prune(directory: directory, limit: limit)
        } catch {
            // Diagnóstico nunca pode derrubar um ditado.
        }
    }

    /// Mantém só as `limit` gravações mais recentes (o nome ordena por data).
    static func prune(directory: URL, limit: Int) {
        let fileManager = FileManager.default
        let recordings = ((try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for stale in recordings.dropLast(max(limit, 0)) {
            try? fileManager.removeItem(at: stale)
            try? fileManager.removeItem(at: stale.deletingPathExtension().appendingPathExtension("txt"))
        }
    }
}
