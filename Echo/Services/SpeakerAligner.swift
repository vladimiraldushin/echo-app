import Foundation
import FluidAudio

/// Назначает индекс спикера каждому ASR-сегменту
/// по максимальному перекрытию с сегментами диаризации.
struct SpeakerAligner {

    // MARK: – Публичные методы

    /// Выравнивает ASR-сегменты с результатом диаризации.
    ///
    /// Для каждого сегмента находит спикера с наибольшим временным перекрытием.
    /// Если перекрытия нет — возвращает `speakerIndex == -1`.
    ///
    /// - Returns: Массив кортежей (сегмент, индекс спикера).
    func align(
        segments: [RawSegment],
        diarization: DiarizationResult
    ) -> [(segment: RawSegment, speakerIndex: Int)] {
        let dSegs = diarization.segments
        guard !dSegs.isEmpty else {
            return segments.map { ($0, -1) }
        }

        // Стабильный маппинг speakerId → Int (в порядке первого появления)
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

    /// Количество уникальных спикеров в результате диаризации.
    func speakerCount(from diarization: DiarizationResult) -> Int {
        Set(diarization.segments.map(\.speakerId)).count
    }

    // MARK: – Приватные методы

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
