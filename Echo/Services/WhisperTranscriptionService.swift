import Foundation
import WhisperKit

/// Обёртка над WhisperKit для транскрипции с поддержкой русского языка.
///
/// Заменяет FluidAudio AsrManager (Parakeet), который поддерживал только английский.
/// WhisperKit использует модели OpenAI Whisper, нативно скомпилированные под Apple Silicon.
///
/// ВАЖНО: WhisperKit импортирует типы TranscriptionResult / TranscriptionSegment, которые
/// конфликтуют с одноимёнными типами в нашем модуле. Поэтому мы везде используем вывод типов
/// и НЕ пишем явные аннотации для типов WhisperKit — это позволяет компилятору корректно
/// определить их через сигнатуру метода whisperKit.transcribe(audioArrays:).
@MainActor
final class WhisperTranscriptionService: ObservableObject {

    enum WhisperError: LocalizedError {
        case modelsNotLoaded
        case transcriptionFailed(String)

        var errorDescription: String? {
            switch self {
            case .modelsNotLoaded:
                return "Модели Whisper не загружены. Сначала вызовите prepareModels()"
            case .transcriptionFailed(let m):
                return "Ошибка транскрипции: \(m)"
            }
        }
    }

    @Published var isLoadingModels = false
    @Published var modelsReady = false

    private var whisperKit: WhisperKit?

    // Выбор модели — баланс качества и скорости:
    //   openai_whisper-large-v3  — лучшее качество (~3 GB)
    //   openai_whisper-medium    — хорошее качество (~1.5 GB)
    //   openai_whisper-small     — быстрее (~244 MB)
    static let modelName = "openai_whisper-large-v3"

    // MARK: – Подготовка моделей

    func prepareModels() async throws {
        guard !modelsReady else { return }
        isLoadingModels = true
        defer { isLoadingModels = false }

        print("⏳ WhisperKit: загрузка модели \(Self.modelName)...")
        let wk = try await WhisperKit(
            model: Self.modelName,
            verbose: false
        )
        self.whisperKit = wk
        self.modelsReady = true
        print("✅ WhisperKit готов")
    }

    // MARK: – Транскрипция

    /// Транскрибировать массив PCM-сэмплов (16 kHz, mono, Float32).
    ///
    /// - Parameters:
    ///   - samples: Float32 16kHz mono PCM аудио
    ///   - language: Код языка ("ru", "en", "" = авто-определение)
    ///   - onProgress: Коллбэк прогресса 0.0–1.0
    /// - Returns: `EchoASRResult` с пословными таймингами
    func transcribeRaw(
        samples: [Float],
        language: String = "ru",
        onProgress: @escaping (Double) -> Void = { _ in }
    ) async throws -> EchoASRResult {
        guard let whisperKit else { throw WhisperError.modelsNotLoaded }

        let lang: String? = language.isEmpty ? nil : language

        var options = DecodingOptions()
        options.language = lang
        options.wordTimestamps = true
        options.skipSpecialTokens = true
        options.task = .transcribe

        print("🌍 WhisperKit: язык=\(lang ?? "авто"), samples=\(samples.count)")

        // transcribe(audioArrays:) принимает [[Float]], возвращает [[TranscriptionResult]?]
        // Типы намеренно выводятся, а не записываются явно, чтобы избежать конфликта имён
        // между WhisperKit.TranscriptionResult и нашим Echo.TranscriptionResult.
        let batchResults = await whisperKit.transcribe(
            audioArrays: [samples],
            decodeOptions: options
        )

        var allText = ""
        var duration: Double = 0
        var detectedLang = language
        var tokenTimings: [EchoTokenTiming] = []

        // batchResults: [[TranscriptionResult]?] — один элемент (мы передали один массив)
        for outerOptional in batchResults {
            guard let resultsArray = outerOptional else { continue }
            for result in resultsArray {
                if !result.language.isEmpty {
                    detectedLang = result.language
                }
                allText += result.text + " "

                for segment in result.segments {
                    duration = max(duration, Double(segment.end))

                    guard let words = segment.words else { continue }
                    for word in words {
                        let cleaned = word.word.trimmingCharacters(in: .whitespaces)
                        guard !cleaned.isEmpty else { continue }
                        tokenTimings.append(EchoTokenTiming(
                            token: cleaned,
                            startTime: Double(word.start),
                            endTime: Double(word.end)
                        ))
                    }
                }
            }
        }

        allText = allText.trimmingCharacters(in: .whitespaces)

        print("✅ WhisperKit: \(tokenTimings.count) слов, длина=\(String(format: "%.1f", duration))s, язык=\(detectedLang)")
        if tokenTimings.isEmpty {
            print("⚠️  WhisperKit: нет пословных таймингов — проверьте wordTimestamps")
        }

        return EchoASRResult(
            text: allText,
            duration: duration,
            tokenTimings: tokenTimings.isEmpty ? nil : tokenTimings,
            language: detectedLang
        )
    }
}
