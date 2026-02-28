import Foundation
import SwiftUI

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

    // MARK: – Основной пайплайн (Этап 1: только транскрипция)

    func process(file: AudioFile) async {
        state = .converting

        do {
            // 1. Конвертация
            let samples = try await converter.convert(url: file.url)

            // 2. Подготовка моделей (если ещё не готовы)
            if !transcriptionService.modelsReady {
                try await transcriptionService.prepareModels()
            }

            // 2б. Подготовка моделей диаризации (параллельно с ASR если первый запуск)
            if !diarizationService.modelsReady {
                try await diarizationService.prepareModels()
            }

            // 3. Транскрипция
            state = .transcribing(progress: 0)
            let rawSegments = try await transcriptionService.transcribe(
                samples: samples,
                onProgress: { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.state = .transcribing(progress: progress)
                    }
                }
            )

            // 4. Диаризация (определение спикеров)
            state = .diarizing
            let diarizationResult = try await diarizationService.diarize(samples: samples)

            // 5. Выравнивание: каждому ASR-сегменту назначаем спикера
            let aligned = aligner.align(segments: rawSegments, diarization: diarizationResult)
            let numSpeakers = aligner.speakerCount(from: diarizationResult)

            // 6. Сборка результата
            let transcriptionResult = TranscriptionResult(language: "en")

            // Создаём объекты Speaker для каждого обнаруженного спикера
            for i in 0..<numSpeakers {
                transcriptionResult.speakers.append(Speaker(index: i))
            }

            for (raw, speakerIndex) in aligned {
                let segment = Segment(
                    text: raw.text,
                    startTime: raw.startTime,
                    endTime: raw.endTime,
                    speakerIndex: speakerIndex,
                    order: raw.order
                )
                transcriptionResult.segments.append(segment)
            }

            self.result = transcriptionResult
            state = .completed

        } catch {
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
