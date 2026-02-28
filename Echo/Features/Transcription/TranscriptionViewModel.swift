import Foundation
import SwiftUI

@MainActor
final class TranscriptionViewModel: ObservableObject {

    enum State {
        case idle
        case converting
        case transcribing(progress: Double)
        case completed
        case failed(String)

        var statusText: String {
            switch self {
            case .idle:                      return "Ожидание"
            case .converting:                return "Конвертация аудио..."
            case .transcribing(let p):       return "Транскрипция \(Int(p * 100))%"
            case .completed:                 return "Готово"
            case .failed(let msg):           return "Ошибка: \(msg)"
            }
        }

        var progress: Double {
            switch self {
            case .converting:            return 0.1
            case .transcribing(let p):   return 0.1 + p * 0.9
            case .completed:             return 1.0
            default:                     return 0
            }
        }

        var isProcessing: Bool {
            if case .converting = self { return true }
            if case .transcribing = self { return true }
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

            // 3. Транскрипция
            state = .transcribing(progress: 0)
            let rawSegments = try await transcriptionService.transcribe(
                samples: samples,
                language: selectedLanguage,
                onProgress: { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.state = .transcribing(progress: progress)
                    }
                }
            )

            // 4. Сборка результата
            let transcriptionResult = TranscriptionResult(language: selectedLanguage)
            for raw in rawSegments {
                let segment = Segment(
                    text: raw.text,
                    startTime: raw.startTime,
                    endTime: raw.endTime,
                    speakerIndex: -1,
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
