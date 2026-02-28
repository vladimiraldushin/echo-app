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

    /// Максимальная длина сегмента до принудительного разделения на паузах (секунды).
    private let maxSegmentDuration: Double = 15.0

    /// Минимальная пауза между словами для разделения длинного сегмента (секунды).
    private let minPauseForSplit: Double = 0.4

    // MARK: – Основной метод (diarization-driven)

    /// Строит сегменты из токенов ASR, используя диаризацию как опорную структуру.
    ///
    /// Алгоритм:
    /// 1. Для каждого сегмента диаризации собираем токены, чей `startTime` попадает в этот диапазон.
    /// 2. **Длинные сегменты (> 15с) разбиваем на паузах** — это решает проблему «мега-сегментов»
    ///    FluidAudio, которые захватывают обоих спикеров в одном 40-секундном куске.
    /// 3. Объединяем соседние сегменты одного спикера (убираем «лесенку» коротких реплик).
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
            print("✅ Diarization-driven: \(tokens.count) слов → \(dSegs.count) сегментов диаризации")
            let raw = buildFromTokens(tokens: tokens, dSegs: dSegs, idToIndex: idToIndex)
            print("   После распределения: \(raw.count) сегментов")

            // Дробим длинные сегменты на паузах
            let split = splitLongSegments(raw, tokens: tokens)
            print("   После разбиения длинных (>\(Int(maxSegmentDuration))с): \(split.count) сегментов")

            let merged = mergeAdjacentSameSpeaker(split)
            print("   После слияния одинаковых спикеров: \(merged.count) сегментов")
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

    // MARK: – Распределение токенов по сегментам

    private func buildFromTokens(
        tokens: [EchoTokenTiming],
        dSegs: [TimedSpeakerSegment],
        idToIndex: [String: Int]
    ) -> [(text: String, startTime: Double, endTime: Double, speakerIndex: Int)] {
        var result: [(text: String, startTime: Double, endTime: Double, speakerIndex: Int)] = []

        for dSeg in dSegs {
            let segStart = Double(dSeg.startTimeSeconds)
            let segEnd   = Double(dSeg.endTimeSeconds)

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

    // MARK: – Разбиение длинных сегментов

    /// Дробит сегменты длиннее `maxSegmentDuration` на самых длинных паузах между словами.
    ///
    /// Это критичный шаг: FluidAudio иногда создаёт один сегмент на 40 секунд,
    /// в котором оба спикера. Мы находим паузу ≥ 0.4с в пословных таймингах
    /// и разрезаем по ней. Спикер остаётся тем же (мы не можем его переопределить),
    /// но при слиянии с соседними сегментами он может быть скорректирован.
    private func splitLongSegments(
        _ segments: [(text: String, startTime: Double, endTime: Double, speakerIndex: Int)],
        tokens: [EchoTokenTiming]
    ) -> [(text: String, startTime: Double, endTime: Double, speakerIndex: Int)] {
        var result: [(text: String, startTime: Double, endTime: Double, speakerIndex: Int)] = []

        for seg in segments {
            let duration = seg.endTime - seg.startTime
            if duration <= maxSegmentDuration {
                result.append(seg)
                continue
            }

            // Собираем токены этого сегмента
            let segTokens = tokens.filter {
                $0.startTime >= seg.startTime && $0.startTime < seg.endTime
            }

            if segTokens.count < 2 {
                result.append(seg)
                continue
            }

            // Находим все паузы между словами
            var pauses: [(index: Int, gap: Double)] = []
            for i in 1..<segTokens.count {
                let gap = segTokens[i].startTime - segTokens[i - 1].endTime
                if gap >= minPauseForSplit {
                    pauses.append((index: i, gap: gap))
                }
            }

            if pauses.isEmpty {
                // Нет пауз — оставляем как есть
                result.append(seg)
                continue
            }

            // Сортируем паузы по убыванию длительности — рубим на самой длинной
            let sortedPauses = pauses.sorted { $0.gap > $1.gap }

            // Определяем точки разреза: рекурсивно делим пока все части ≤ maxSegmentDuration
            let splitIndices = findSplitPoints(
                segTokens: segTokens,
                pauses: sortedPauses,
                maxDuration: maxSegmentDuration
            )

            // Строим под-сегменты по точкам разреза
            var sliceStart = 0
            let allSplits = (splitIndices + [segTokens.count]).sorted()

            for splitEnd in allSplits {
                let sliceTokens = Array(segTokens[sliceStart..<splitEnd])
                guard !sliceTokens.isEmpty else { continue }

                let text = sliceTokens
                    .map { $0.token }
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespaces)

                if !text.isEmpty {
                    result.append((
                        text: text,
                        startTime: sliceTokens.first!.startTime,
                        endTime: sliceTokens.last!.endTime,
                        speakerIndex: seg.speakerIndex
                    ))
                }
                sliceStart = splitEnd
            }

            let splitCount = allSplits.count
            if splitCount > 1 {
                print("   ✂️  Разрезан сегмент [\(String(format: "%.1f", seg.startTime))–\(String(format: "%.1f", seg.endTime))s] (\(String(format: "%.0f", duration))с) → \(splitCount) частей")
            }
        }

        return result
    }

    /// Находит оптимальные точки разреза для массива токенов,
    /// чтобы все результирующие части были ≤ maxDuration.
    private func findSplitPoints(
        segTokens: [EchoTokenTiming],
        pauses: [(index: Int, gap: Double)],
        maxDuration: Double
    ) -> [Int] {
        guard segTokens.count >= 2 else { return [] }

        let totalStart = segTokens.first!.startTime
        let totalEnd = segTokens.last!.endTime

        if totalEnd - totalStart <= maxDuration {
            return []
        }

        // Ищем паузу, ближайшую к середине
        let midTime = (totalStart + totalEnd) / 2
        let bestPause = pauses
            .min { abs(segTokens[$0.index].startTime - midTime) < abs(segTokens[$1.index].startTime - midTime) }

        guard let pause = bestPause else { return [] }

        // Рекурсивно проверяем обе половины
        let leftTokens = Array(segTokens[0..<pause.index])
        let rightTokens = Array(segTokens[pause.index...])

        let leftPauses = pauses.filter { $0.index < pause.index }
        let rightPauses = pauses.map { (index: $0.index - pause.index, gap: $0.gap) }
            .filter { $0.index > 0 && $0.index < rightTokens.count }

        var splits = [pause.index]
        splits += findSplitPoints(segTokens: leftTokens, pauses: leftPauses, maxDuration: maxDuration)
        splits += findSplitPoints(segTokens: rightTokens, pauses: rightPauses, maxDuration: maxDuration)
            .map { $0 + pause.index }

        return splits
    }

    // MARK: – Фолбэк: пропорциональное распределение текста

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

    // MARK: – Слияние соседних сегментов одного спикера

    /// Объединяет подряд идущие сегменты одного спикера, разделённые паузой < 1.5 с.
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

    // MARK: – Вспомогательные

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
