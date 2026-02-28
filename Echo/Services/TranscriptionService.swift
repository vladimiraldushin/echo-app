import Foundation
import FluidAudio

/// Обёртка над FluidAudio AsrManager
/// Отвечает за транскрипцию аудио с word-level timestamps
@MainActor
final class TranscriptionService: ObservableObject {

    enum TranscriptionError: LocalizedError {
        case modelsNotLoaded
        case transcriptionFailed(String)

        var errorDescription: String? {
            switch self {
            case .modelsNotLoaded:
                return "Модели не загружены. Сначала вызовите prepareModels()"
            case .transcriptionFailed(let m):
                return "Ошибка транскрипции: \(m)"
            }
        }
    }

    @Published var isLoadingModels = false
    @Published var modelsReady = false
    @Published var loadingProgress: Double = 0

    private var manager: AsrManager?

    // MARK: – Публичные методы

    /// Загрузить ML-модели (один раз при старте приложения)
    func prepareModels() async throws {
        guard !modelsReady else { return }
        isLoadingModels = true
        defer { isLoadingModels = false }

        let asrManager = AsrManager()
        let models = try await AsrModels.downloadAndLoad()
        try await asrManager.initialize(models: models)
        self.manager = asrManager
        self.modelsReady = true
    }

    /// Транскрибировать аудио и вернуть сырой ASRResult (с токенами и таймингами).
    /// Используется для diarization-driven сегментации.
    /// - Parameters:
    ///   - samples: Float32 16kHz mono PCM
    ///   - onProgress: коллбэк прогресса (0.0 – 1.0)
    /// - Returns: Сырой ASRResult с tokenTimings
    func transcribeRaw(
        samples: [Float],
        onProgress: @escaping (Double) -> Void = { _ in }
    ) async throws -> ASRResult {
        guard let manager else { throw TranscriptionError.modelsNotLoaded }
        do {
            // NOTE: FluidAudio SDK (Parakeet) не поддерживает параметр языка.
            let result = try await manager.transcribe(samples, source: .microphone)
            print("🔍 ASR Raw: токенов=\(result.tokenTimings?.count ?? 0), длина=\(String(format: "%.1f", result.duration))s, символов=\(result.text.count)")
            return result
        } catch {
            throw TranscriptionError.transcriptionFailed(error.localizedDescription)
        }
    }

    /// Транскрибировать аудио из массива Float32 сэмплов (16kHz mono).
    /// Устаревший метод — используйте transcribeRaw() для diarization-driven подхода.
    func transcribe(
        samples: [Float],
        language: String = "en-US",
        onProgress: @escaping (Double) -> Void = { _ in }
    ) async throws -> [RawSegment] {
        let result = try await transcribeRaw(samples: samples, onProgress: onProgress)
        return segmentsFrom(result: result)
    }

    // MARK: – Приватные методы

    /// Группируем токены с таймстемпами в текстовые сегменты.
    /// При паузе > 0.3 сек разрываем сегмент (было 0.8).
    private func segmentsFrom(result: ASRResult) -> [RawSegment] {
        print("🔍 DEBUG: tokenTimings count = \(result.tokenTimings?.count ?? 0)")
        print("🔍 DEBUG: result.duration = \(result.duration)s")
        print("🔍 DEBUG: result.text length = \(result.text.count) chars")
        
        guard let timings = result.tokenTimings, !timings.isEmpty else {
            print("⚠️  WARNING: No token timings available, creating single segment")
            // Если нет таймингов, пробуем разбить по длине (каждые 30 секунд)
            let chunkDuration: Double = 30.0
            let text = result.text.trimmingCharacters(in: .whitespaces)
            let words = text.components(separatedBy: " ")
            
            if result.duration > chunkDuration && words.count > 50 {
                // Разбиваем на куски по времени
                var segments: [RawSegment] = []
                let wordsPerChunk = max(50, words.count * Int(chunkDuration) / Int(result.duration))
                
                for i in stride(from: 0, to: words.count, by: wordsPerChunk) {
                    let endIdx = min(i + wordsPerChunk, words.count)
                    let chunkText = words[i..<endIdx].joined(separator: " ")
                    let startTime = result.duration * Double(i) / Double(words.count)
                    let endTime = result.duration * Double(endIdx) / Double(words.count)
                    
                    segments.append(RawSegment(
                        text: chunkText,
                        startTime: startTime,
                        endTime: endTime,
                        order: segments.count
                    ))
                }
                
                print("📊 Created \(segments.count) synthetic segments")
                return segments
            }
            
            return [RawSegment(
                text: text,
                startTime: 0,
                endTime: result.duration,
                order: 0
            )]
        }

        let pauseThreshold: TimeInterval = 0.3  // Уменьшено с 0.8
        var segments: [RawSegment] = []
        var currentTokens: [TokenTiming] = []

        for timing in timings {
            if let last = currentTokens.last, timing.startTime - last.endTime > pauseThreshold {
                if let seg = makeSegment(from: currentTokens, order: segments.count) {
                    segments.append(seg)
                }
                currentTokens = [timing]
            } else {
                currentTokens.append(timing)
            }
        }

        if let seg = makeSegment(from: currentTokens, order: segments.count) {
            segments.append(seg)
        }

        print("📊 Created \(segments.count) segments from \(timings.count) tokens")
        
        return segments.isEmpty
            ? [RawSegment(
                text: result.text.trimmingCharacters(in: .whitespaces),
                startTime: 0,
                endTime: result.duration,
                order: 0
              )]
            : segments
    }

    private func makeSegment(from timings: [TokenTiming], order: Int) -> RawSegment? {
        guard !timings.isEmpty else { return nil }
        let text = timings.map { $0.token }.joined()
            .replacingOccurrences(of: "▁", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return RawSegment(
            text: text,
            startTime: timings.first!.startTime,
            endTime: timings.last!.endTime,
            order: order
        )
    }
}

// MARK: – Промежуточная структура (до AlignmentService)

struct RawSegment {
    let text: String
    let startTime: Double
    let endTime: Double
    let order: Int
}
