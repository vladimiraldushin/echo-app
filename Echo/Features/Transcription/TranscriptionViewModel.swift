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
            case .transcribing(let p):   return 0.1 + p * 0.6
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
    private let whisperService = WhisperTranscriptionService()
    private let aligner = SpeakerAligner()
    private let audioDiagnostics = AudioDiagnostics()

    // MARK: – Основной пайплайн

    func process(file: AudioFile) async {
        state = .converting

        do {
            print("\n")
            print("🚀 НАЧАЛО ОБРАБОТКИ: \(file.name)")
            print("═══════════════════════════════════════════════════════════════")

            // 1. Конвертация в 16kHz mono Float32
            let samples = try await converter.convert(url: file.url)

            // 1б. Диагностика качества аудио
            let audioQuality = await audioDiagnostics.analyze(samples: samples)
            print(audioQuality.description)

            // 2. Подготовка WhisperKit (загрузка модели, если ещё не готова)
            if !whisperService.modelsReady {
                print("⏳ Загрузка моделей WhisperKit...")
                try await whisperService.prepareModels()
                print("✅ WhisperKit готов\n")
            }

            // 3. Транскрипция через WhisperKit (Whisper large-v3, русский)
            state = .transcribing(progress: 0)

            print("═══════════════════════════════════════════════════════════════")
            print("📝 ЭТАП 1: ТРАНСКРИПЦИЯ (WhisperKit)")
            print("═══════════════════════════════════════════════════════════════\n")
            print("🌍 Язык: \(selectedLanguage.isEmpty ? "авто" : selectedLanguage.uppercased())")

            let asrResult = try await whisperService.transcribeRaw(
                samples: samples,
                language: selectedLanguage,
                onProgress: { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.state = .transcribing(progress: progress)
                    }
                }
            )

            print("\n✅ Транскрипция завершена:")
            print("   • Слов: \(asrResult.tokenTimings?.count ?? 0)")
            print("   • Длительность: \(String(format: "%.1f", asrResult.duration))s")
            print("   • Символов в тексте: \(asrResult.text.count)")
            print("   • Язык: \(asrResult.language)")
            if let firstToken = asrResult.tokenTimings?.first,
               let lastToken  = asrResult.tokenTimings?.last {
                print("   • Диапазон: [\(String(format: "%.2f", firstToken.startTime))s – \(String(format: "%.2f", lastToken.endTime))s]")
            }

            // 4. Диаризация + выравнивание (NativeDiarizer — спектральные признаки + k-means)
            state = .diarizing

            print("═══════════════════════════════════════════════════════════════")
            print("🎙️  ЭТАП 2: ДИАРИЗАЦИЯ (NativeDiarizer — спектральные признаки)")
            print("═══════════════════════════════════════════════════════════════\n")

            let numSpeakers = expectedSpeakers > 0 ? expectedSpeakers : 2
            print("⚙️  Число спикеров: \(numSpeakers)")

            let aligned = aligner.buildSegments(
                from: asrResult,
                audioSamples: samples,
                numSpeakers: numSpeakers
            )

            print("\n📋 Примеры назначений:")
            for (i, seg) in aligned.prefix(5).enumerated() {
                print("  [\(i)] Спикер \(seg.speakerIndex): \"\(seg.text.prefix(60))\"")
                print("       [\(String(format: "%.2f", seg.startTime))s – \(String(format: "%.2f", seg.endTime))s]\n")
            }

            // 5. Сборка результата
            print("═══════════════════════════════════════════════════════════════")
            print("✅ СБОРКА ФИНАЛЬНОГО РЕЗУЛЬТАТА")
            print("═══════════════════════════════════════════════════════════════\n")

            let transcriptionResult = TranscriptionResult(language: asrResult.language)

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
            print("   • Язык: \(asrResult.language)")
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
