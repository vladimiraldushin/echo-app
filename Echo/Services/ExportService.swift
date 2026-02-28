import Foundation

/// Экспорт результата транскрипции в разные форматы
struct ExportService {

    enum ExportFormat: String, CaseIterable, Identifiable {
        case txt  = "txt"
        case json = "json"
        case srt  = "srt"
        case vtt  = "vtt"
        case md   = "md"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .txt:  return "Текст (.txt)"
            case .json: return "JSON (.json)"
            case .srt:  return "Субтитры (.srt)"
            case .vtt:  return "WebVTT (.vtt)"
            case .md:   return "Markdown (.md)"
            }
        }
    }

    enum ExportError: LocalizedError {
        case writeFailed(String)
        var errorDescription: String? {
            if case .writeFailed(let m) = self { return "Ошибка записи: \(m)" }
            return nil
        }
    }

    // MARK: – Экспорт

    func export(result: TranscriptionResult, to directory: URL, format: ExportFormat, filename: String) throws -> URL {
        let content = buildContent(result: result, format: format)
        let fileURL = directory.appendingPathComponent(filename).appendingPathExtension(format.rawValue)
        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            throw ExportError.writeFailed(error.localizedDescription)
        }
        return fileURL
    }

    // MARK: – Форматы

    private func buildContent(result: TranscriptionResult, format: ExportFormat) -> String {
        switch format {
        case .txt:  return buildTXT(result)
        case .json: return buildJSON(result)
        case .srt:  return buildSRT(result)
        case .vtt:  return buildVTT(result)
        case .md:   return buildMarkdown(result)
        }
    }

    // TXT: [00:00] Спикер 1: текст
    private func buildTXT(_ result: TranscriptionResult) -> String {
        result.sortedSegments.map { seg in
            let speaker = result.speakerName(for: seg.speakerIndex)
            return "[\(seg.formattedStart)] \(speaker): \(seg.text)"
        }.joined(separator: "\n")
    }

    // JSON: полная структура
    private func buildJSON(_ result: TranscriptionResult) -> String {
        let segments = result.sortedSegments.map { seg -> [String: Any] in
            [
                "start": seg.startTime,
                "end": seg.endTime,
                "speaker": result.speakerName(for: seg.speakerIndex),
                "text": seg.text
            ]
        }
        let speakers = result.speakers.map { s -> [String: Any] in
            ["index": s.index, "name": s.name]
        }
        let root: [String: Any] = [
            "language": result.language,
            "created_at": ISO8601DateFormatter().string(from: result.createdAt),
            "processing_time": result.processingTime,
            "speakers": speakers,
            "segments": segments
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: .prettyPrinted),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }

    // SRT: нумерованные субтитры
    private func buildSRT(_ result: TranscriptionResult) -> String {
        result.sortedSegments.enumerated().map { idx, seg in
            let speaker = result.speakerName(for: seg.speakerIndex)
            return """
            \(idx + 1)
            \(srtTime(seg.startTime)) --> \(srtTime(seg.endTime))
            \(speaker): \(seg.text)
            """
        }.joined(separator: "\n\n")
    }

    // VTT
    private func buildVTT(_ result: TranscriptionResult) -> String {
        var lines = ["WEBVTT\n"]
        result.sortedSegments.forEach { seg in
            let speaker = result.speakerName(for: seg.speakerIndex)
            lines.append("\(vttTime(seg.startTime)) --> \(vttTime(seg.endTime))\n\(speaker): \(seg.text)\n")
        }
        return lines.joined(separator: "\n")
    }

    // Markdown
    private func buildMarkdown(_ result: TranscriptionResult) -> String {
        var lines = ["# Транскрипция\n"]
        var lastSpeaker = ""
        result.sortedSegments.forEach { seg in
            let speaker = result.speakerName(for: seg.speakerIndex)
            if speaker != lastSpeaker {
                lines.append("\n## \(speaker)\n")
                lastSpeaker = speaker
            }
            lines.append("**[\(seg.formattedStart)]** \(seg.text)\n")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: – Вспомогательные

    private func srtTime(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        let ms = Int((seconds - Double(Int(seconds))) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    private func vttTime(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        let ms = Int((seconds - Double(Int(seconds))) * 1000)
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
    }
}
