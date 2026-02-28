import Foundation
import SwiftUI
import FluidAudio  // Для DiarizerConfig

@MainActor
final class TranscriptionViewModel: ObservableObject {

    enum State {
        case idle
        case converting
        case transcribing(progress: Double)
        case diarizing
        case completed
        case failed(String)

        var statusText: String {
            switch self {
            case .idle:                      return "Ожидание"
            case .converting:                return "Конвертация аудио..."
            case .transcribing(let p):       return "Транскрипция \(Int(p * 100))%"
            case .diarizing:                 return "Определение спикеров..."
            case .completed:                 return "Готово"
            case .failed(let msg):           return "Ошибка: \(msg)"
            }
        }

        var progress: Double {
            switch self {
            case .converting:            return 0.1
            case .transcribing(let p):   return 0.1 + p * 0.5
            case .diarizing:             return 0.8
            case .completed:             return 1.0
            default:                     return 0
            }
        }

        var isProcessing: Bool {
            if case .converting = self { return true }
            if case .transcribing = self { return true }
            if case .diarizing = self { return true }
            return false
        }
    }

    @Published var state: State = .idle
    @Published var result: TranscriptionResult?
    @Published var selectedLanguage = "ru"
    @Published var searchQuery = ""
    @Published var expectedSpeakers: Int = -1  // -1 = автоопределение, 2+ = фиксированное число

    var filteredSegments: [Segment] {
        guard let result else { return [] }
        let sorted = result.sortedSegments
        guard !searchQuery.isEmpty else { return sorted }
        return sorted.filter { $0.text.localizedCaseInsensitiveContains(searchQuery) }
    }

    private let converter = AudioConverter()
    private let transcriptionService = TranscriptionService()
    private let diarizationService = DiarizationService()
    private let aligner = SpeakerAligner()
    private let audioDiagnostics = AudioDiagnostics()

    // MARK: – Основной пайплайн (Этап 1: только транскрипция)

    func process(file: AudioFile) async {
        state = .converting

        do {
            print("\n")
            print("🚀 НАЧАЛО ОБРАБОТКИ: \(file.name)")
            print("═══════════════════════════════════════════════════════════════")
            
            // 1. Конвертация
            let samples = try await converter.convert(url: file.url)
            
            // 1б. Диагностика качества аудио
            let audioQuality = await audioDiagnostics.analyze(samples: samples)
            print(audioQuality.description)

            // 2. Подготовка моделей (если ещё не готовы)
            if !transcriptionService.modelsReady {
                print("⏳ Загрузка моделей транскрипции...")
                try await transcriptionService.prepareModels()
                print("✅ Модели транскрипции готовы\n")
            }

            // 2б. Подготовка моделей диаризации (параллельно с ASR если первый запуск)
            if !diarizationService.modelsReady {
                print("⏳ Загрузка моделей диаризации...")
                try await diarizationService.prepareModels()
                print("✅ Модели диаризации готовы\n")
            }

            // 3. Транскрипция (получаем сырой ASRResult с токенами)
            state = .transcribing(progress: 0)

            print("═══════════════════════════════════════════════════════════════")
            print("📝 ЭТАП 1: ТРАНСКРИПЦИЯ")
            print("═══════════════════════════════════════════════════════════════\n")
            print("🌍 Язык: \(selectedLanguage.uppercased())")

            let asrResult = try await transcriptionService.transcribeRaw(
                samples: samples,
                onProgress: { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.state = .transcribing(progress: progress)
                    }
                }
            )

            print("\n✅ Транскрипция завершена:")
            print("   • Токенов: \(asrResult.tokenTimings?.count ?? 0)")
            print("   • Длительность: \(String(format: "%.1f", asrResult.duration))s")
            print("   • Символов в тексте: \(asrResult.text.count)")
            if let firstToken = asrResult.tokenTimings?.first,
               let lastToken  = asrResult.tokenTimings?.last {
                print("   • Диапазон токенов: [\(String(format: "%.2f", firstToken.startTime))s – \(String(format: "%.2f", lastToken.endTime))s]")
            }

            // 4. Диаризация (определение спикеров)
            state = .diarizing
            
            print("═══════════════════════════════════════════════════════════════")
            print("🎙️  ЭТАП 2: ДИАРИЗАЦИЯ (ОПРЕДЕЛЕНИЕ СПИКЕРОВ)")
            print("═══════════════════════════════════════════════════════════════\n")
            
            // Настраиваем конфигурацию диаризации
            var diarizationConfig = OfflineDiarizerConfig.default
            diarizationConfig.clusteringThreshold = 0.6  // Понижаем для лучшего различения
            
            print("⚙️  Конфигурация диаризации:")
            print("   • clusteringThreshold: \(diarizationConfig.clusteringThreshold)")
            
            if expectedSpeakers > 0 {
                diarizationConfig.clustering.numSpeakers = expectedSpeakers
                print("   • Ожидаемое количество: \(expectedSpeakers) спикеров\n")
            } else {
                print("   • Автоопределение количества спикеров\n")
            }
            
            let diarizationResult = try await diarizationService.diarize(
                samples: samples,
                config: diarizationConfig
            )
            
            // Диагностика диаризации
            let diarizationAnalysis = DiarizationDiagnostics.analyze(diarizationResult)
            print(diarizationAnalysis.description)
            
            // Визуальный таймлайн
            print(DiarizationDiagnostics.visualizeTimeline(diarizationResult, width: 60))

            // 5. Выравнивание: diarization-driven сегментация
            print("═══════════════════════════════════════════════════════════════")
            print("🔗 ЭТАП 3: ВЫРАВНИВАНИЕ (ТОКЕНЫ → СЕГМЕНТЫ ДИАРИЗАЦИИ)")
            print("═══════════════════════════════════════════════════════════════\n")

            let aligned = aligner.buildSegments(from: asrResult, diarization: diarizationResult)
            let numSpeakers = aligner.speakerCount(from: diarizationResult)

            print("\n📋 Примеры назначений:")
            for (i, seg) in aligned.prefix(5).enumerated() {
                print("  [\(i)] Спикер \(seg.speakerIndex): \"\(seg.text.prefix(60))\"")
                print("       [\(String(format: "%.2f", seg.startTime))s – \(String(format: "%.2f", seg.endTime))s]\n")
            }

            // 6. Сборка результата
            print("═══════════════════════════════════════════════════════════════")
            print("✅ СБОРКА ФИНАЛЬНОГО РЕЗУЛЬТАТА")
            print("═══════════════════════════════════════════════════════════════\n")

            let transcriptionResult = TranscriptionResult(language: selectedLanguage)

            // Создаём объекты Speaker для каждого обнаруженного спикера
            for i in 0..<numSpeakers {
                transcriptionResult.speakers.append(Speaker(index: i))
            }

            for (order, seg) in aligned.enumerated() {
                let segment = Segment(
                    text: seg.text,
                    startTime: seg.startTime,
                    endTime: seg.endTime,
                    speakerIndex: seg.speakerIndex,
                    order: order
                )
                transcriptionResult.segments.append(segment)
            }

            self.result = transcriptionResult
            
            print("📊 Итого:")
            print("   • Сегментов: \(transcriptionResult.segments.count)")
            print("   • Спикеров: \(numSpeakers)")
            print("   • Язык: \(selectedLanguage.uppercased())")
            print("\n🎉 ОБРАБОТКА ЗАВЕРШЕНА УСПЕШНО!")
            print("═══════════════════════════════════════════════════════════════\n")
            
            state = .completed

        } catch {
            print("\n❌ ОШИБКА: \(error.localizedDescription)")
            print("═══════════════════════════════════════════════════════════════\n")
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: – Экспорт

    func export(format: ExportService.ExportFormat) {
        guard let result else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = []
        panel.nameFieldStringValue = "transcription.\(format.rawValue)"
        panel.title = "Сохранить транскрипцию"

        if panel.runModal() == .OK, let url = panel.url {
            let dir = url.deletingLastPathComponent()
            let name = url.deletingPathExtension().lastPathComponent
            do {
                let exported = try ExportService().export(
                    result: result, to: dir, format: format, filename: name
                )
                NSWorkspace.shared.activateFileViewerSelecting([exported])
            } catch {
                // TODO: показать алерт
            }
        }
    }

    // MARK: – Редактирование

    func renameSpeaker(index: Int, newName: String) {
        result?.speakers.first(where: { $0.index == index })?.name = newName
    }
}
