import Foundation
import FluidAudio

/// Обёртка над OfflineDiarizerManager
/// Отвечает за диаризацию — определение «кто говорит когда»
@MainActor
final class DiarizationService: ObservableObject {

    enum DiarizationError: LocalizedError {
        case modelsNotLoaded
        case diarizationFailed(String)
        case noSpeechDetected

        var errorDescription: String? {
            switch self {
            case .modelsNotLoaded:
                return "Модели диаризации не загружены"
            case .diarizationFailed(let m):
                return "Ошибка диаризации: \(m)"
            case .noSpeechDetected:
                return "Речь не обнаружена в аудио"
            }
        }
    }

    @Published var isLoadingModels = false
    @Published var modelsReady = false

    private var diarizer: OfflineDiarizerManager?

    // MARK: – Публичные методы

    /// Загрузить модели диаризации (один раз при старте).
    /// Модели скачиваются автоматически при первом запуске.
    func prepareModels() async throws {
        guard !modelsReady else { return }
        isLoadingModels = true
        defer { isLoadingModels = false }

        let manager = OfflineDiarizerManager()
        try await manager.prepareModels()
        self.diarizer = manager
        self.modelsReady = true
    }

    /// Диаризовать аудио из массива Float32 сэмплов (16kHz mono).
    /// - Parameter samples: Float32 16kHz mono PCM
    /// - Returns: DiarizationResult с массивом TimedSpeakerSegment
    func diarize(samples: [Float]) async throws -> DiarizationResult {
        guard let diarizer else { throw DiarizationError.modelsNotLoaded }
        do {
            return try await diarizer.process(audio: samples)
        } catch OfflineDiarizationError.noSpeechDetected {
            throw DiarizationError.noSpeechDetected
        } catch {
            throw DiarizationError.diarizationFailed(error.localizedDescription)
        }
    }
}
