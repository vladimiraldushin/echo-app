import Foundation
import SwiftUI
import SwiftData

/// Спикер в транскрипции
@Model
final class Speaker {
    var id: UUID
    var index: Int           // 0, 1, 2... — порядковый номер (Speaker 0, Speaker 1...)
    var name: String         // Отображаемое имя (по умолчанию "Спикер 1")
    var colorHex: String     // Цвет для UI

    init(index: Int) {
        self.id = UUID()
        self.index = index
        self.name = "Спикер \(index + 1)"
        self.colorHex = Speaker.palette[index % Speaker.palette.count]
    }

    var color: Color {
        Color(hex: colorHex) ?? .blue
    }

    // Палитра цветов для спикеров
    static let palette: [String] = [
        "#4A90D9", // синий
        "#E8625A", // красный
        "#5BB974", // зелёный
        "#F5A623", // оранжевый
        "#9B59B6", // фиолетовый
        "#1ABC9C", // бирюзовый
        "#E74C3C", // тёмно-красный
        "#3498DB", // голубой
    ]
}

// MARK: - Color from hex
extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.hasPrefix("#") ? String(hexSanitized.dropFirst()) : hexSanitized
        guard hexSanitized.count == 6,
              let rgb = UInt64(hexSanitized, radix: 16) else { return nil }
        let r = Double((rgb >> 16) & 0xFF) / 255
        let g = Double((rgb >> 8)  & 0xFF) / 255
        let b = Double(rgb         & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
