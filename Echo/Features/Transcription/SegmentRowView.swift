import SwiftUI

struct SegmentRowView: View {
    let segment: Segment
    let speakerName: String
    let speakerColor: Color
    var onTimeClick: (Double) -> Void = { _ in }

    @State private var isEditing = false
    @State private var editedText = ""

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Цветовая полоска спикера
            RoundedRectangle(cornerRadius: 2)
                .fill(speakerColor)
                .frame(width: 3)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 4) {
                // Шапка: имя спикера + время
                HStack(spacing: 6) {
                    Text(speakerName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(speakerColor)

                    Button(segment.formattedStart) {
                        onTimeClick(segment.startTime)
                    }
                    .buttonStyle(.plain)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                }

                // Текст сегмента
                if isEditing {
                    TextEditor(text: $editedText)
                        .font(.body)
                        .frame(minHeight: 40)
                        .onSubmit { commitEdit() }
                } else {
                    Text(segment.text)
                        .font(.body)
                        .textSelection(.enabled)
                        .onTapGesture(count: 2) { startEditing() }
                }
            }

            Spacer()

            if isEditing {
                VStack(spacing: 4) {
                    Button("Сохранить") { commitEdit() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("Отмена") { cancelEdit() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func startEditing() {
        editedText = segment.text
        isEditing = true
    }

    private func commitEdit() {
        segment.text = editedText
        isEditing = false
    }

    private func cancelEdit() {
        isEditing = false
    }
}
