import Foundation

/// Промежуточный тип для передачи результатов ASR между сервисами.
/// Не зависит от конкретного ASR-движка (FluidAudio / WhisperKit / etc.)
struct EchoTokenTiming {
    let token: String       // Слово / субтокен
    let startTime: Double   // Начало в секундах
    let endTime: Double     // Конец в секундах
}

struct EchoASRResult {
    let text: String
    let duration: Double
    let tokenTimings: [EchoTokenTiming]?
    let language: String
}
