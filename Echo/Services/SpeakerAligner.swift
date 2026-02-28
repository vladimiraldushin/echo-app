import Foundation

/// Строит сегменты транскрипции с привязкой к спикерам.
///
/// Использует NativeDiarizer для определения спикера каждого слова
/// на основе спектральных признаков аудио, затем группирует
/// последовательные слова одного спикера в сегменты.
struct SpeakerAligner {

    private let nativeDiarizer = NativeDiarizer()

    // MARK: – Основной метод

    /// Строит сегменты из ASR-результата и аудио-сэмплов.
    ///
    /// 1. NativeDiarizer определяет спикера каждого слова (спектральные признаки + k-means)
    /// 2. Последовательные слова одного спикера группируются в сегменты
    /// 3. Короткие соседние сегменты одного спикера сливаются
    func buildSegments(
        from asrResult: EchoASRResult,
        audioSamples: [Float],
        numSpeakers: Int = 2
    ) -> [(text: String, startTime: Double, endTime: Double, speakerIndex: Int)] {
        guard let tokens = asrResult.tokenTimings, !tokens.isEmpty else {
            print("⚠️  Нет пословных таймингов — невозможно построить сегменты")
            return []
        }

        print("✅ SpeakerAligner: \(tokens.count) слов, \(numSpeakers) спикеров")

        // 1. Диаризация — определяем спикера каждого слова
        let speakerLabels = nativeDiarizer.diarize(
            samples: audioSamples,
            words: tokens,
            numSpeakers: numSpeakers
        )

        // 2. Группируем последовательные слова одного спикера
        var segments: [(text: String, startTime: Double, endTime: Double, speakerIndex: Int)] = []
        var currentWords: [EchoTokenTiming] = [tokens[0]]
        var currentSpeaker = speakerLabels[0]

        for i in 1..<tokens.count {
            let speakerChanged = speakerLabels[i] != currentSpeaker
            // Также разбиваем на длинных паузах (> 3с) даже без смены спикера
            let longPause = tokens[i].startTime - tokens[i - 1].endTime > 3.0

            if speakerChanged || longPause {
                flush(words: currentWords, speaker: currentSpeaker, into: &segments)
                currentWords = [tokens[i]]
                currentSpeaker = speakerLabels[i]
            } else {
                currentWords.append(tokens[i])
            }
        }
        flush(words: currentWords, speaker: currentSpeaker, into: &segments)

        print("   Сформировано \(segments.count) сегментов")

        // 3. Слияние соседних сегментов одного спикера с малой паузой
        let merged = mergeAdjacentSameSpeaker(segments)
        print("   После слияния: \(merged.count) сегментов")

        return merged
    }

    /// Количество спикеров (задаётся параметром, а не из диаризации)
    func speakerCount(numSpeakers: Int) -> Int {
        numSpeakers
    }

    // MARK: – Private

    private func flush(
        words: [EchoTokenTiming],
        speaker: Int,
        into segments: inout [(text: String, startTime: Double, endTime: Double, speakerIndex: Int)]
    ) {
        guard !words.isEmpty else { return }
        let text = words
            .map { $0.token }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }

        segments.append((
            text: text,
            startTime: words.first!.startTime,
            endTime: words.last!.endTime,
            speakerIndex: speaker
        ))
    }

    /// Объединяет подряд идущие сегменты одного спикера, разделённые паузой < 2с.
    private func mergeAdjacentSameSpeaker(
        _ segments: [(text: String, startTime: Double, endTime: Double, speakerIndex: Int)]
    ) -> [(text: String, startTime: Double, endTime: Double, speakerIndex: Int)] {
        var merged: [(text: String, startTime: Double, endTime: Double, speakerIndex: Int)] = []
        for seg in segments {
            if var last = merged.last,
               last.speakerIndex == seg.speakerIndex,
               seg.startTime - last.endTime < 2.0 {
                last = (
                    text: last.text + " " + seg.text,
                    startTime: last.startTime,
                    endTime: seg.endTime,
                    speakerIndex: last.speakerIndex
                )
                merged[merged.count - 1] = last
            } else {
                merged.append(seg)
            }
        }
        return merged
    }
}
