import Foundation
import FluidAudio

/// Выравнивает токены ASR с сегментами диаризации.
///
/// Основной подход — **diarization-driven**:
/// вместо того чтобы разбивать ASR-вывод на сегменты и потом назначать спикеров,
/// мы используем сегменты диаризации как опорную структуру и распределяем
/// токены ASR по этим сегментам. Это решает проблему, когда ASR
/// возвращает один гигантский сегмент для длинного аудио.
struct SpeakerAligner {

    // MARK: – Основной метод (diarization-driven)

    /// Строит сегменты из токенов ASR, используя диаризацию как опорную структуру.
    ///
    /// Алгоритм:
    /// 1. Для каждого сегмента диаризации собираем токены, чей `startTime` попадает в этот диапазон.
    /// 2. Объединяем соседние сегменты одного спикера (убираем «лесенку» коротких реплик).
    ///
    /// Если токенов нет — пропорционально распределяем текст по сегментам диаризации.
    ///
    /// - Returns: Массив `(text, startTime, endTime, speakerIndex)` в хронологическом порядке.
    func buildSegments(
        from asrResult: EchoASRResult,
        diarization: DiarizationResult
    ) -> [(text: String, startTime: Double, endTime: Double, speakerIndex: Int)] {
        let dSegs = diarization.segments
        guard !dSegs.isEmpty else { return [] }

        let idToIndex = buildSpeakerIndex(from: dSegs)

        if let tokens = asrResult.tokenTimings, !tokens.isEmpty {
            print("✅ Diarization-driven: \(tokens.count) токенов → \(dSegs.count) сегментов диаризации")
            let raw = buildFromTokens(tokens: tokens, dSegs: dSegs, idToIndex: idToIndex)
            let merged = mergeAdjacentSameSpeaker(raw)
            print("   Итого после слияния: \(merged.count) сегментов")
            return merged
        }

        print("⚠️  Нет токенов с таймингами — пропорциональное распределение текста")
        let raw = buildFromPlainText(
            text: asrResult.text,
            duration: asrResult.duration,
            dSegs: dSegs,
            idToIndex: idToIndex
        )
        return mergeAdjacentSameSpeaker(raw)
    }

    /// Количество уникальных спикеров в результате диаризации.
    func speakerCount(from diarization: DiarizationResult) -> Int {
        Set(diarization.segments.map(\.speakerId)).count
    }

    // MARK: – Устаревший метод (оставлен для совместимости)

    /// Назначает индекс спикера каждому ASR-сегменту по максимальному перекрытию.
    /// Не используется при diarization-driven подходе.
    func align(
        segments: [RawSegment],
        diarization: DiarizationResult
    ) -> [(segment: RawSegment, speakerIndex: Int)] {
        let dSegs = diarization.segments
        guard !dSegs.isEmpty else {
            return segments.map { ($0, -1) }
        }
        let idToIndex = buildSpeakerIndex(from: dSegs)
        return segments.map { seg in
            let idx = dominantSpeaker(
                from: seg.startTime,
                to: seg.endTime,
                dSegs: dSegs,
                idToIndex: idToIndex
            )
            return (seg, idx)
        }
    }

    // MARK: – Приватные методы

    /// Распределяет токены (слова) по сегментам диаризации.
    private func buildFromTokens(
        tokens: [EchoTokenTiming],
        dSegs: [TimedSpeakerSegment],
        idToIndex: [String: Int]
    ) -> [(text: String, startTime: Double, endTime: Double, speakerIndex: Int)] {
        var result: [(text: String, startTime: Double, endTime: Double, speakerIndex: Int)] = []

        for dSeg in dSegs {
            let segStart = Double(dSeg.startTimeSeconds)
            let segEnd   = Double(dSeg.endTimeSeconds)

            // Слова, чей startTime попадает в диапазон этого сегмента диаризации
            let segTokens = tokens.filter { $0.startTime >= segStart && $0.startTime < segEnd }
            guard !segTokens.isEmpty else { continue }

            let text = segTokens
                .map { $0.token }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }

            let speakerIndex = idToIndex[dSeg.speakerId] ?? -1
            result.append((
                text: text,
                startTime: segTokens.first!.startTime,
                endTime: segTokens.last!.endTime,
                speakerIndex: speakerIndex
            ))
        }

        return result
    }

    /// Пропорционально распределяет слова текста по сегментам диаризации.
    /// Используется как фолбэк, если токены не содержат таймингов.
    private func buildFromPlainText(
        text: String,
        duration: TimeInterval,
        dSegs: [TimedSpeakerSegment],
        idToIndex: [String: Int]
    ) -> [(text: String, startTime: Double, endTime: Double, speakerIndex: Int)] {
        let words = text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }

        let totalDur = dSegs.reduce(0.0) { $0 + Double($1.endTimeSeconds - $1.startTimeSeconds) }
        var wordIndex = 0
        var result: [(text: String, startTime: Double, endTime: Double, speakerIndex: Int)] = []

        for dSeg in dSegs {
            guard wordIndex < words.count else { break }
            let segDur   = Double(dSeg.endTimeSeconds - dSeg.startTimeSeconds)
            let fraction = totalDur > 0 ? segDur / totalDur : 1.0 / Double(dSegs.count)
            let wordCount = max(1, Int(Double(words.count) * fraction))
            let endIdx = min(wordIndex + wordCount, words.count)

            let segText = words[wordIndex..<endIdx].joined(separator: " ")
            let speakerIndex = idToIndex[dSeg.speakerId] ?? -1
            result.append((
                text: segText,
                startTime: Double(dSeg.startTimeSeconds),
                endTime: Double(dSeg.endTimeSeconds),
                speakerIndex: speakerIndex
            ))
            wordIndex = endIdx
        }

        return result
    }

    /// Объединяет подряд идущие сегменты одного спикера, разделённые паузой < 1.5 с.
    /// Снижает фрагментацию и делает транскрипцию читаемее.
    private func mergeAdjacentSameSpeaker(
        _ segments: [(text: String, startTime: Double, endTime: Double, speakerIndex: Int)]
    ) -> [(text: String, startTime: Double, endTime: Double, speakerIndex: Int)] {
        var merged: [(text: String, startTime: Double, endTime: Double, speakerIndex: Int)] = []
        for seg in segments {
            if var last = merged.last,
               last.speakerIndex == seg.speakerIndex,
               seg.startTime - last.endTime < 1.5 {
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

    private func buildSpeakerIndex(from segments: [TimedSpeakerSegment]) -> [String: Int] {
        var map: [String: Int] = [:]
        for seg in segments {
            if map[seg.speakerId] == nil {
                map[seg.speakerId] = map.count
            }
        }
        return map
    }

    private func dominantSpeaker(
        from start: Double,
        to end: Double,
        dSegs: [TimedSpeakerSegment],
        idToIndex: [String: Int]
    ) -> Int {
        var overlapBySpeaker: [String: Double] = [:]
        for dSeg in dSegs {
            let segStart = Double(dSeg.startTimeSeconds)
            let segEnd   = Double(dSeg.endTimeSeconds)
            let overlapStart = max(start, segStart)
            let overlapEnd   = min(end,   segEnd)
            if overlapEnd > overlapStart {
                overlapBySpeaker[dSeg.speakerId, default: 0] += overlapEnd - overlapStart
            }
        }
        guard let best = overlapBySpeaker.max(by: { $0.value < $1.value }) else {
            return -1
        }
        return idToIndex[best.key] ?? -1
    }
}
