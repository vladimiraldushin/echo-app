import Foundation
import SwiftData

/// Полный результат транскрипции одного файла
@Model
final class TranscriptionResult {
    var id: UUID
    var language: String
    var createdAt: Date
    var processingTime: TimeInterval  // сколько секунд заняла обработка

    @Relationship(deleteRule: .cascade)
    var segments: [Segment]

    @Relationship(deleteRule: .cascade)
    var speakers: [Speaker]

    init(language: String = "ru") {
        self.id = UUID()
        self.language = language
        self.createdAt = Date()
        self.processingTime = 0
        self.segments = []
        self.speakers = []
    }

    /// Сегменты, отсортированные по времени
    var sortedSegments: [Segment] {
        segments.sorted { $0.startTime < $1.startTime }
    }

    /// Полный текст без разметки
    var plainText: String {
        sortedSegments.map(\.text).joined(separator: " ")
    }

    /// Текст с разметкой по спикерам и таймстемпами
    var formattedText: String {
        sortedSegments.map { segment in
            let speaker = speakerName(for: segment.speakerIndex)
            return "[\(segment.formattedStart)] \(speaker): \(segment.text)"
        }.joined(separator: "\n")
    }

    func speakerName(for index: Int) -> String {
        guard index >= 0,
              let speaker = speakers.first(where: { $0.index == index }) else {
            return "Спикер"
        }
        return speaker.name
    }

    func speaker(for index: Int) -> Speaker? {
        speakers.first { $0.index == index }
    }

    var speakerCount: Int { speakers.count }
    var segmentCount: Int { segments.count }
}
