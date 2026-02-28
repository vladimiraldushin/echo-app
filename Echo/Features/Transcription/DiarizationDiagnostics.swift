import Foundation
import FluidAudio

/// Диагностика результатов диаризации
struct DiarizationDiagnostics {
    
    struct Analysis {
        let totalSegments: Int
        let uniqueSpeakers: Int
        let speakerDistribution: [String: TimeInterval]  // speaker_id -> total duration
        let averageSegmentDuration: TimeInterval
        let shortestSegment: TimeInterval
        let longestSegment: TimeInterval
        let speakerSwitches: Int  // Сколько раз меняется спикер
        let overlappingSegments: Int  // Сегменты с наложением
        
        var description: String {
            """
            
            ═══════════════════════════════════════════════════════════════
            🎙️  ДИАГНОСТИКА ДИАРИЗАЦИИ
            ═══════════════════════════════════════════════════════════════
            
            📊 ОБЩАЯ СТАТИСТИКА:
               • Всего сегментов:    \(totalSegments)
               • Уникальных спикеров: \(uniqueSpeakers) \(speakerCountIcon)
               • Смен спикеров:      \(speakerSwitches)
               • Наложений:          \(overlappingSegments) \(overlapIcon)
            
            ⏱️  ДЛИТЕЛЬНОСТЬ СЕГМЕНТОВ:
               • Средняя:            \(String(format: "%.2f", averageSegmentDuration))с
               • Кратчайшая:         \(String(format: "%.2f", shortestSegment))с
               • Длиннейшая:         \(String(format: "%.2f", longestSegment))с
            
            👥 РАСПРЕДЕЛЕНИЕ ПО СПИКЕРАМ:
            \(speakerDistributionText)
            
            \(warnings)
            ═══════════════════════════════════════════════════════════════
            """
        }
        
        private var speakerCountIcon: String {
            if uniqueSpeakers >= 2 { return "✅" }
            return "⚠️"
        }
        
        private var overlapIcon: String {
            if overlappingSegments == 0 { return "✅" }
            if overlappingSegments < 5 { return "🟡" }
            return "⚠️"
        }
        
        private var speakerDistributionText: String {
            let sorted = speakerDistribution.sorted { $0.value > $1.value }
            let total = sorted.reduce(0.0) { $0 + $1.value }
            
            return sorted.enumerated().map { index, item in
                let percentage = (item.value / total) * 100
                let bar = progressBar(percentage: percentage)
                return String(format: "   Спикер %d: %5.1f%% %@ (%.1fс)",
                             index,
                             percentage,
                             bar,
                             item.value)
            }.joined(separator: "\n")
        }
        
        private func progressBar(percentage: Double, length: Int = 20) -> String {
            let filled = Int((percentage / 100.0) * Double(length))
            let empty = length - filled
            return String(repeating: "█", count: filled) + String(repeating: "░", count: empty)
        }
        
        private var warnings: String {
            var issues: [String] = []
            
            if uniqueSpeakers == 1 {
                issues.append("❌ Обнаружен только 1 спикер!")
                issues.append("   → Попробуйте понизить clusteringThreshold до 0.5")
                issues.append("   → Или укажите ожидаемое количество спикеров вручную")
            }
            
            if uniqueSpeakers > 10 {
                issues.append("⚠️  Обнаружено очень много спикеров (\(uniqueSpeakers))")
                issues.append("   → Возможно, clusteringThreshold слишком низкий")
                issues.append("   → Или аудио содержит много фонового шума")
            }
            
            if overlappingSegments > 10 {
                issues.append("⚠️  Много наложений сегментов (\(overlappingSegments))")
                issues.append("   → Спикеры перебивают друг друга")
            }
            
            if shortestSegment < 0.2 {
                issues.append("⚠️  Очень короткие сегменты (мин: \(String(format: "%.2f", shortestSegment))с)")
                issues.append("   → Попробуйте увеличить minSpeechDuration")
            }
            
            // Проверяем перекос в распределении
            if let dominant = speakerDistribution.values.max(),
               let total = speakerDistribution.values.reduce(0, +) as? TimeInterval,
               dominant / total > 0.9 {
                issues.append("ℹ️  Один спикер доминирует (>\(String(format: "%.0f", (dominant/total)*100))% времени)")
                issues.append("   → Это может быть правильно, если интервью/монолог")
            }
            
            if issues.isEmpty {
                return "✅ Диаризация выглядит хорошо!\n"
            } else {
                return "ПРЕДУПРЕЖДЕНИЯ:\n" + issues.map { "   \($0)" }.joined(separator: "\n") + "\n"
            }
        }
    }
    
    static func analyze(_ result: DiarizationResult) -> Analysis {
        let segments = result.segments
        let uniqueSpeakers = Set(segments.map(\.speakerId)).count
        
        // Распределение по спикерам
        var distribution: [String: TimeInterval] = [:]
        for segment in segments {
            let duration = TimeInterval(segment.endTimeSeconds - segment.startTimeSeconds)
            distribution[segment.speakerId, default: 0] += duration
        }
        
        // Длительности сегментов
        let durations = segments.map { TimeInterval($0.endTimeSeconds - $0.startTimeSeconds) }
        let avgDuration = durations.reduce(0, +) / Double(durations.count)
        let shortest = durations.min() ?? 0
        let longest = durations.max() ?? 0
        
        // Смены спикеров
        var switches = 0
        for i in 1..<segments.count {
            if segments[i].speakerId != segments[i-1].speakerId {
                switches += 1
            }
        }
        
        // Наложения
        var overlaps = 0
        for i in 0..<segments.count-1 {
            if segments[i].endTimeSeconds > segments[i+1].startTimeSeconds {
                overlaps += 1
            }
        }
        
        return Analysis(
            totalSegments: segments.count,
            uniqueSpeakers: uniqueSpeakers,
            speakerDistribution: distribution,
            averageSegmentDuration: avgDuration,
            shortestSegment: shortest,
            longestSegment: longest,
            speakerSwitches: switches,
            overlappingSegments: overlaps
        )
    }
    
    /// Визуализация таймлайна (ASCII art)
    static func visualizeTimeline(_ result: DiarizationResult, width: Int = 60) -> String {
        guard !result.segments.isEmpty else { return "" }
        
        let totalDuration = Double(result.segments.map(\.endTimeSeconds).max() ?? 0)
        let scale = Double(width) / totalDuration
        
        // Группируем по спикерам
        let speakers = Array(Set(result.segments.map(\.speakerId))).sorted()
        let colors = ["🟦", "🟩", "🟨", "🟧", "🟪", "🟥"]
        
        var timeline = "\n📊 ТАЙМЛАЙН (каждый символ ≈ \(String(format: "%.1f", totalDuration/Double(width)))с):\n\n"
        
        // Создаём визуальную дорожку
        var track = Array(repeating: "░", count: width)
        
        for (speakerIndex, speaker) in speakers.enumerated() {
            let speakerSegments = result.segments.filter { $0.speakerId == speaker }
            let color = colors[speakerIndex % colors.count]
            
            for segment in speakerSegments {
                let start = Int(Double(segment.startTimeSeconds) * scale)
                let end = Int(Double(segment.endTimeSeconds) * scale)
                for i in start..<min(end, width) {
                    track[i] = color
                }
            }
        }
        
        timeline += "   " + track.joined() + "\n\n"
        timeline += "   Легенда:\n"
        for (index, speaker) in speakers.enumerated() {
            let color = colors[index % colors.count]
            let duration = result.segments.filter { $0.speakerId == speaker }
                .reduce(0.0) { $0 + Double($1.endTimeSeconds - $1.startTimeSeconds) }
            timeline += "   \(color) Спикер \(index) (\(String(format: "%.1f", duration))с)\n"
        }
        
        return timeline
    }
}
