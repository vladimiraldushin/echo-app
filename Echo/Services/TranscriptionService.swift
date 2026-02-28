import Foundation
import FluidAudio

/// Обёртка над FluidAudio TranscriberManager
/// Отвечает за транскрипцию аудио с word-level timestamps
@MainActor
final class TranscriptionService: ObservableObject {

    enum TranscriptionError: LocalizedError {
        case modelsNotLoaded
        case transcriptionFailed(String)

        var errorDescription: String? {
            switch self {
            case .modelsNotLoaded:          return "Модели не загружены. Сначала вызовите prepareModels()"
            case .transcriptionFailed(let m): return "Ошибка транскрипции: \(m)"
            }
        }
    }

    @Published var isLoadingModels = false
    @Published var modelsReady = false
    @Published var loadingProgress: Double = 0

    private var transcriber: TranscriberManager?

    // MARK: – Публичные методы

    /// Загрузить ML-модели (один раз при старте)
    func prepareModels() async throws {
        guard !modelsReady else { return }
        isLoadingModels = true
        defer { isLoadingModels = false }

        let manager = TranscriberManager()
        try await manager.prepareModels()
        self.transcriber = manager
        self.modelsReady = true
    }

    /// Транскрибировать аудио из массива Float32 сэмплов
    /// - Parameters:
    ///   - samples: Float32 16kHz mono PCM
    ///   - language: ISO 639-1 код языка ("ru", "en" и т.д.) или nil для автодетекции
    ///   - onProgress: коллбэк прогресса (0.0 – 1.0)
    /// - Returns: Массив сегментов с таймстемпами
    func transcribe(
        samples: [Float],
        language: String? = "ru",
        onProgress: @escaping (Double) -> Void = { _ in }
    ) async throws -> [RawSegment] {
        guard let transcriber else { throw TranscriptionError.modelsNotLoaded }

        do {
            let result = try await transcriber.transcribe(
                audioData: samples,
                language: language
            )
            return result.segments.enumerated().map { idx, seg in
                RawSegment(
                    text: seg.text.trimmingCharacters(in: .whitespaces),
                    startTime: seg.start,
                    endTime: seg.end,
                    order: idx
                )
            }
        } catch {
            throw TranscriptionError.transcriptionFailed(error.localizedDescription)
        }
    }
}

// MARK: – Промежуточная структура (до AlignmentService)

struct RawSegment {
    let text: String
    let startTime: Double
    let endTime: Double
    let order: Int
}
