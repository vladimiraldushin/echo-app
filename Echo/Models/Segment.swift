import Foundation
import SwiftData

/// Один сегмент транскрипции: кусок текста, привязанный к спикеру и времени
@Model
final class Segment {
    var id: UUID
    var text: String
    var startTime: Double   // секунды
    var endTime: Double     // секунды
    var speakerIndex: Int   // индекс спикера (-1 если не определён)
    var order: Int          // порядок в транскрипции

    init(text: String, startTime: Double, endTime: Double, speakerIndex: Int = -1, order: Int = 0) {
        self.id = UUID()
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.speakerIndex = speakerIndex
        self.order = order
    }

    var duration: Double { endTime - startTime }

    var formattedStart: String { formatTime(startTime) }
    var formattedEnd: String   { formatTime(endTime) }

    var hasSpeaker: Bool { speakerIndex >= 0 }

    private func formatTime(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
