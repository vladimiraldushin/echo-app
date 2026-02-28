import Foundation

// Структура для сегмента диаризации
// Соответствует TimedSpeakerSegment из DiarizerTypes.swift
struct DiarizationSegment {
    let speakerId: String
    let startTimeSeconds: Float
    let endTimeSeconds: Float
}

/// Диагностика выравнивания ASR-сегментов со спикерами
struct AlignmentDiagnostics {
    
    struct Analysis {
        let totalSegments: Int
        let assignedSpeakers: [Int: Int]  // speaker_index -> count
        let unassignedSegments: Int
        let confidenceDistribution: [ConfidenceLevel: Int]
        let averageOverlap: Double  // Насколько хорошо сегменты перекрываются с диаризацией
        
        enum ConfidenceLevel: String, CaseIterable {
            case perfect = "Идеально"     // 100% перекрытие
            case high = "Высокая"         // 80-99%
            case medium = "Средняя"       // 50-79%
            case low = "Низкая"           // 20-49%
            case veryLow = "Очень низкая" // < 20%
        }
        
        var description: String {
            """
            
            ═══════════════════════════════════════════════════════════════
            🔗 ДИАГНОСТИКА ВЫРАВНИВАНИЯ
            ═══════════════════════════════════════════════════════════════
            
            📝 СЕГМЕНТЫ:
               • Всего транскрибировано: \(totalSegments)
               • Не назначено спикеров:   \(unassignedSegments) \(unassignedIcon)
               • Среднее перекрытие:      \(String(format: "%.1f", averageOverlap))% \(overlapIcon)
            
            👥 РАСПРЕДЕЛЕНИЕ ПО СПИКЕРАМ:
            \(speakerAssignmentText)
            
            📊 УВЕРЕННОСТЬ НАЗНАЧЕНИЙ:
            \(confidenceDistributionText)
            
            \(warnings)
            ═══════════════════════════════════════════════════════════════
            """
        }
        
        private var unassignedIcon: String {
            if unassignedSegments == 0 { return "✅" }
            if unassignedSegments < 3 { return "🟡" }
            return "⚠️"
        }
        
        private var overlapIcon: String {
            if averageOverlap > 80 { return "✅" }
            if averageOverlap > 50 { return "🟡" }
            return "⚠️"
        }
        
        private var speakerAssignmentText: String {
            let sorted = assignedSpeakers.sorted { $0.key < $1.key }
            let total = sorted.reduce(0) { $0 + $1.value }
            
            return sorted.map { speaker, count in
                let percentage = Double(count) / Double(total) * 100
                let bar = progressBar(percentage: percentage)
                return String(format: "   Спикер %d: %5.1f%% %@ (%d сегментов)",
                             speaker,
                             percentage,
                             bar,
                             count)
            }.joined(separator: "\n")
        }
        
        private var confidenceDistributionText: String {
            let total = confidenceDistribution.values.reduce(0, +)
            
            return ConfidenceLevel.allCases.map { level in
                let count = confidenceDistribution[level] ?? 0
                let percentage = Double(count) / Double(total) * 100
                let bar = progressBar(percentage: percentage)
                let paddedLevel = level.rawValue.padding(toLength: 13, withPad: " ", startingAt: 0)
                return String(format: "   %@: %5.1f%% %@ (%d)",
                             paddedLevel,
                             percentage,
                             bar,
                             count)
            }.joined(separator: "\n")
        }
        
        private func progressBar(percentage: Double, length: Int = 15) -> String {
            let filled = Int((percentage / 100.0) * Double(length))
            let empty = length - filled
            return String(repeating: "█", count: filled) + String(repeating: "░", count: empty)
        }
        
        private var warnings: String {
            var issues: [String] = []
            
            if unassignedSegments > 0 {
                issues.append("⚠️  \(unassignedSegments) сегментов без назначенного спикера")
                issues.append("   → Диаризация не покрыла всё аудио")
            }
            
            if averageOverlap < 50 {
                issues.append("❌ Низкое перекрытие сегментов (\(String(format: "%.1f", averageOverlap))%)")
                issues.append("   → Таймстемпы ASR и диаризации не совпадают")
                issues.append("   → Возможно, проблема в качестве аудио или моделях")
            }
            
            let lowConfidence = (confidenceDistribution[.low] ?? 0) + (confidenceDistribution[.veryLow] ?? 0)
            if lowConfidence > totalSegments / 4 {
                issues.append("⚠️  Много назначений с низкой уверенностью (\(lowConfidence))")
                issues.append("   → Попробуйте другие параметры диаризации")
            }
            
            // Проверяем перекос
            if let dominant = assignedSpeakers.values.max(),
               dominant == totalSegments - unassignedSegments {
                issues.append("⚠️  Все сегменты назначены одному спикеру")
                issues.append("   → Диаризация не смогла различить голоса")
            }
            
            if issues.isEmpty {
                return "✅ Выравнивание прошло успешно!\n"
            } else {
                return "ПРЕДУПРЕЖДЕНИЯ:\n" + issues.map { "   \($0)" }.joined(separator: "\n") + "\n"
            }
        }
    }
    
    static func analyze(
        segments: [RawSegment],
        aligned: [(RawSegment, Int)],
        diarizationSegments: [DiarizationSegment]
    ) -> Analysis {
        
        // Распределение по спикерам
        var speakerCounts: [Int: Int] = [:]
        for (_, speaker) in aligned {
            speakerCounts[speaker, default: 0] += 1
        }
        
        let unassigned = segments.count - aligned.count
        
        // Вычисляем уверенность для каждого назначения
        var confidenceDist: [Analysis.ConfidenceLevel: Int] = [:]
        var totalOverlap: Double = 0
        
        for (segment, speakerIdx) in aligned {
            // Находим все диаризационные сегменты этого спикера, которые перекрываются
            let speakerId = "speaker_\(speakerIdx)"
            let overlappingDiarization = diarizationSegments.filter {
                $0.speakerId == speakerId &&
                Self.overlapDuration(
                    seg1: (segment.startTime, segment.endTime),
                    seg2: (Double($0.startTimeSeconds), Double($0.endTimeSeconds))
                ) > 0
            }
            
            // Вычисляем процент перекрытия
            let segmentDuration = segment.endTime - segment.startTime
            let overlapDuration = overlappingDiarization.reduce(0.0) { sum, dSeg in
                sum + Self.overlapDuration(
                    seg1: (segment.startTime, segment.endTime),
                    seg2: (Double(dSeg.startTimeSeconds), Double(dSeg.endTimeSeconds))
                )
            }
            
            let overlapPercent = (overlapDuration / segmentDuration) * 100
            totalOverlap += overlapPercent
            
            let confidence: Analysis.ConfidenceLevel
            switch overlapPercent {
            case 95...: confidence = .perfect
            case 80..<95: confidence = .high
            case 50..<80: confidence = .medium
            case 20..<50: confidence = .low
            default: confidence = .veryLow
            }
            
            confidenceDist[confidence, default: 0] += 1
        }
        
        let avgOverlap = aligned.isEmpty ? 0 : totalOverlap / Double(aligned.count)
        
        return Analysis(
            totalSegments: segments.count,
            assignedSpeakers: speakerCounts,
            unassignedSegments: unassigned,
            confidenceDistribution: confidenceDist,
            averageOverlap: avgOverlap
        )
    }
    
    private static func overlapDuration(seg1: (Double, Double), seg2: (Double, Double)) -> Double {
        let start = max(seg1.0, seg2.0)
        let end = min(seg1.1, seg2.1)
        return max(0, end - start)
    }
}
