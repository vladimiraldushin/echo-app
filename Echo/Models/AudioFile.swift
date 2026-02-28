import Foundation
import SwiftData

/// Аудиофайл, добавленный пользователем для транскрипции
@Model
final class AudioFile {
    var id: UUID
    var url: URL
    var name: String
    var duration: TimeInterval
    var fileSize: Int64
    var format: String
    var createdAt: Date
    var status: ProcessingStatus

    @Relationship(deleteRule: .cascade)
    var transcriptionResult: TranscriptionResult?

    init(url: URL, name: String, duration: TimeInterval = 0, fileSize: Int64 = 0) {
        self.id = UUID()
        self.url = url
        self.name = name
        self.duration = duration
        self.fileSize = fileSize
        self.format = url.pathExtension.uppercased()
        self.createdAt = Date()
        self.status = .pending
    }

    enum ProcessingStatus: String, Codable {
        case pending    = "pending"
        case converting = "converting"
        case transcribing = "transcribing"
        case diarizing  = "diarizing"
        case completed  = "completed"
        case failed     = "failed"

        var displayName: String {
            switch self {
            case .pending:      return "Ожидание"
            case .converting:   return "Конвертация"
            case .transcribing: return "Транскрипция"
            case .diarizing:    return "Диаризация"
            case .completed:    return "Готово"
            case .failed:       return "Ошибка"
            }
        }
    }

    var formattedDuration: String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: duration) ?? "0:00"
    }

    var formattedFileSize: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
}
