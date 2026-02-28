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

    /// Транскрибировать аудио из массива Float32 сэмплов (16kHz mono)
    /// - Parameters:
    ///   - samples: Float32 16kHz mono PCM
    ///   - onProgress: коллбэк прогресса (0.0 – 1.0)
    /// - Returns: Массив сегментов с таймстемпами
    func transcribe(
        samples: [Float],
        onProgress: @escaping (Double) -> Void = { _ in }
    ) async throws -> [RawSegment] {
        guard let manager else { throw TranscriptionError.modelsNotLoaded }

        do {
            let result = try await manager.transcribe(samples, source: .microphone)
            return segmentsFrom(result: result)
        } catch {
            throw TranscriptionError.transcriptionFailed(error.localizedDescription)
        }
    }

    // MARK: – Приватные методы

    /// Группируем токены с таймстемпами в текстовые сегменты.
    /// При паузе > 0.8 сек разрываем сегмент.
    private func segmentsFrom(result: ASRResult) -> [RawSegment] {
        guard let timings = result.tokenTimings, !timings.isEmpty else {
            return [RawSegment(
                text: result.text.trimmingCharacters(in: .whitespaces),
                startTime: 0,
                endTime: result.duration,
                order: 0
            )]
        }

        let pauseThreshold: TimeInterval = 0.8
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
