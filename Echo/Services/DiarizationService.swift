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
    private var currentConfig: OfflineDiarizerConfig?

    // MARK: – Публичные методы

    /// Загрузить модели диаризации (один раз при старте).
    /// Модели скачиваются автоматически при первом запуске.
    func prepareModels(config: OfflineDiarizerConfig = .default) async throws {
        guard !modelsReady else { return }
        isLoadingModels = true
        defer { isLoadingModels = false }

        let manager = OfflineDiarizerManager(config: config)
        try await manager.prepareModels()
        self.diarizer = manager
        self.currentConfig = config
        self.modelsReady = true
    }

    /// Диаризовать аудио из массива Float32 сэмплов (16kHz mono).
    /// - Parameters:
    ///   - samples: Float32 16kHz mono PCM
    ///   - config: Конфигурация диаризации (если отличается от prepareModels, будет пересоздан менеджер)
    /// - Returns: DiarizationResult с массивом TimedSpeakerSegment
    func diarize(samples: [Float], config: OfflineDiarizerConfig? = nil) async throws -> DiarizationResult {
        // Определяем конфигурацию
        let targetConfig = config ?? createOptimizedConfig()
        
        // Если конфигурация изменилась, пересоздаём diarizer
        let configChanged = currentConfig == nil ||
            currentConfig?.clusteringThreshold != targetConfig.clusteringThreshold ||
            currentConfig?.clustering.minSpeakers != targetConfig.clustering.minSpeakers ||
            currentConfig?.clustering.maxSpeakers != targetConfig.clustering.maxSpeakers ||
            currentConfig?.clustering.numSpeakers != targetConfig.clustering.numSpeakers ||
            currentConfig?.segmentationStepRatio != targetConfig.segmentationStepRatio ||
            currentConfig?.Fb != targetConfig.Fb

        if configChanged {
            modelsReady = false
            try await prepareModels(config: targetConfig)
        }
        
        guard let diarizer else { throw DiarizationError.modelsNotLoaded }
        
        do {
            return try await diarizer.process(audio: samples)
        } catch OfflineDiarizationError.noSpeechDetected {
            throw DiarizationError.noSpeechDetected
        } catch {
            throw DiarizationError.diarizationFailed(error.localizedDescription)
        }
    }
    
    // MARK: - Private
    
    /// Создаёт оптимизированную конфигурацию для русской речи
    private func createOptimizedConfig() -> OfflineDiarizerConfig {
        var cfg = OfflineDiarizerConfig.default
        // Понижаем порог для лучшего различения похожих голосов
        cfg.clusteringThreshold = 0.6  // Было 0.7
        return cfg
    }
}
