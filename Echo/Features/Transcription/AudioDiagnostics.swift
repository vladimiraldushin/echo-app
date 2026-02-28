import Foundation
import Accelerate

/// Диагностика качества аудио и анализ характеристик
actor AudioDiagnostics {
    
    struct AudioQuality {
        let sampleRate: Double
        let duration: Double
        let sampleCount: Int
        
        // Уровни громкости
        let averageLevel: Float      // Средний уровень (dB)
        let peakLevel: Float          // Пиковый уровень (dB)
        let dynamicRange: Float       // Динамический диапазон (dB)
        
        // Шум и качество
        let noiseFloor: Float         // Уровень шума (dB)
        let signalToNoiseRatio: Float // SNR (dB)
        let clipPercentage: Float     // % клиппинга
        
        // Активность речи
        let speechPercentage: Float   // % времени с речью
        let silencePercentage: Float  // % времени тишины
        let averagePauseDuration: Float // Средняя длительность пауз
        
        // Качественная оценка
        var qualityRating: QualityRating {
            if signalToNoiseRatio > 30 && clipPercentage < 1.0 && speechPercentage > 20 {
                return .excellent
            } else if signalToNoiseRatio > 20 && clipPercentage < 5.0 && speechPercentage > 10 {
                return .good
            } else if signalToNoiseRatio > 10 && clipPercentage < 15.0 {
                return .acceptable
            } else {
                return .poor
            }
        }
        
        enum QualityRating: String {
            case excellent = "Отлично"
            case good = "Хорошо"
            case acceptable = "Приемлемо"
            case poor = "Плохо"
        }
        
        var description: String {
            """
            
            ═══════════════════════════════════════════════════════════════
            📊 ДИАГНОСТИКА АУДИО
            ═══════════════════════════════════════════════════════════════
            
            ⏱️  Длительность:       \(String(format: "%.1f", duration))с (\(sampleCount) сэмплов @ \(Int(sampleRate))Hz)
            
            🔊 УРОВНИ СИГНАЛА:
               • Средний уровень:    \(String(format: "%+.1f", averageLevel)) dB
               • Пиковый уровень:    \(String(format: "%+.1f", peakLevel)) dB
               • Динамический диапазон: \(String(format: "%.1f", dynamicRange)) dB
            
            📡 КАЧЕСТВО СИГНАЛА:
               • Уровень шума:       \(String(format: "%+.1f", noiseFloor)) dB
               • Отношение С/Ш:      \(String(format: "%.1f", signalToNoiseRatio)) dB \(snrIcon)
               • Клиппинг:           \(String(format: "%.2f", clipPercentage))% \(clipIcon)
            
            🎙️  РЕЧЕВАЯ АКТИВНОСТЬ:
               • Речь:               \(String(format: "%.1f", speechPercentage))%
               • Тишина:             \(String(format: "%.1f", silencePercentage))%
               • Средняя пауза:      \(String(format: "%.2f", averagePauseDuration))с
            
            ⭐️ ОБЩАЯ ОЦЕНКА:        \(qualityRating.rawValue) \(qualityIcon)
            
            \(recommendations)
            ═══════════════════════════════════════════════════════════════
            """
        }
        
        private var snrIcon: String {
            if signalToNoiseRatio > 30 { return "✅" }
            if signalToNoiseRatio > 20 { return "🟡" }
            return "⚠️"
        }
        
        private var clipIcon: String {
            if clipPercentage < 1.0 { return "✅" }
            if clipPercentage < 5.0 { return "🟡" }
            return "⚠️"
        }
        
        private var qualityIcon: String {
            switch qualityRating {
            case .excellent: return "🌟"
            case .good: return "✅"
            case .acceptable: return "🟡"
            case .poor: return "❌"
            }
        }
        
        private var recommendations: String {
            var issues: [String] = []
            
            if signalToNoiseRatio < 15 {
                issues.append("⚠️  Высокий уровень шума — рекомендуется шумоподавление")
            }
            if clipPercentage > 5.0 {
                issues.append("⚠️  Обнаружен клиппинг — аудио перегружено")
            }
            if speechPercentage < 10 {
                issues.append("⚠️  Мало речевой активности — возможно неправильный файл?")
            }
            if dynamicRange < 10 {
                issues.append("⚠️  Низкий динамический диапазон — сжатое аудио")
            }
            if averagePauseDuration < 0.3 {
                issues.append("ℹ️  Короткие паузы — возможны проблемы с диаризацией")
            }
            
            if issues.isEmpty {
                return "✅ Аудио отличного качества для транскрипции!\n"
            } else {
                return "РЕКОМЕНДАЦИИ:\n" + issues.map { "   \($0)" }.joined(separator: "\n") + "\n"
            }
        }
    }
    
    // MARK: - Анализ
    
    func analyze(samples: [Float], sampleRate: Double = 16000) -> AudioQuality {
        let sampleCount = samples.count
        let duration = Double(sampleCount) / sampleRate
        
        // Вычисляем уровни
        let avgLevel = averageLevel(samples)
        let peakLevel = peakLevel(samples)
        let noiseFloor = noiseFloor(samples)
        let dynamicRange = peakLevel - avgLevel
        let snr = avgLevel - noiseFloor
        let clipPercentage = clippingPercentage(samples)
        
        // Анализ речевой активности
        let (speechPct, silencePct, avgPause) = speechActivity(samples, sampleRate: sampleRate)
        
        return AudioQuality(
            sampleRate: sampleRate,
            duration: duration,
            sampleCount: sampleCount,
            averageLevel: avgLevel,
            peakLevel: peakLevel,
            dynamicRange: dynamicRange,
            noiseFloor: noiseFloor,
            signalToNoiseRatio: snr,
            clipPercentage: clipPercentage,
            speechPercentage: speechPct,
            silencePercentage: silencePct,
            averagePauseDuration: avgPause
        )
    }
    
    // MARK: - Приватные методы
    
    private func averageLevel(_ samples: [Float]) -> Float {
        var sum: Float = 0.0
        vDSP_meamgv(samples, 1, &sum, vDSP_Length(samples.count))
        return amplitudeToDecibels(sum)
    }
    
    private func peakLevel(_ samples: [Float]) -> Float {
        var peak: Float = 0.0
        vDSP_maxv(samples.map(abs), 1, &peak, vDSP_Length(samples.count))
        return amplitudeToDecibels(peak)
    }
    
    private func noiseFloor(_ samples: [Float]) -> Float {
        // Берём нижние 10% по амплитуде — это шум
        let sorted = samples.map(abs).sorted()
        let noiseIndex = samples.count / 10
        let noise = sorted[noiseIndex]
        return amplitudeToDecibels(max(noise, 0.0001))
    }
    
    private func clippingPercentage(_ samples: [Float]) -> Float {
        let threshold: Float = 0.99
        let clipped = samples.filter { abs($0) > threshold }.count
        return Float(clipped) / Float(samples.count) * 100.0
    }
    
    private func speechActivity(_ samples: [Float], sampleRate: Double) -> (speech: Float, silence: Float, avgPause: Float) {
        let frameSize = 400  // 25ms @ 16kHz
        let threshold: Float = 0.02
        
        var speechFrames = 0
        var silenceFrames = 0
        var pauseDurations: [Float] = []
        var currentPauseDuration = 0
        
        for i in stride(from: 0, to: samples.count - frameSize, by: frameSize) {
            let frame = Array(samples[i..<min(i + frameSize, samples.count)])
            var energy: Float = 0.0
            vDSP_meamgv(frame, 1, &energy, vDSP_Length(frame.count))
            
            if energy > threshold {
                speechFrames += 1
                if currentPauseDuration > 0 {
                    pauseDurations.append(Float(currentPauseDuration) * Float(frameSize) / Float(sampleRate))
                    currentPauseDuration = 0
                }
            } else {
                silenceFrames += 1
                currentPauseDuration += 1
            }
        }
        
        let totalFrames = speechFrames + silenceFrames
        let speechPct = Float(speechFrames) / Float(totalFrames) * 100.0
        let silencePct = Float(silenceFrames) / Float(totalFrames) * 100.0
        let avgPause = pauseDurations.isEmpty ? 0 : pauseDurations.reduce(0, +) / Float(pauseDurations.count)
        
        return (speechPct, silencePct, avgPause)
    }
    
    private func amplitudeToDecibels(_ amplitude: Float) -> Float {
        return 20.0 * log10(max(amplitude, 0.00001))
    }
}
