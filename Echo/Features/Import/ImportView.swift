import SwiftUI
import UniformTypeIdentifiers

struct ImportView: View {
    @StateObject private var vm = ImportViewModel()
    var onStartProcessing: ([AudioFile]) -> Void

    var body: some View {
        VStack(spacing: 0) {
            dropZone
            if !vm.droppedFiles.isEmpty {
                fileList
                actionBar
            }
        }
        .frame(minWidth: 600, minHeight: 400)
    }

    // MARK: – Drop Zone

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    vm.isTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                    style: StrokeStyle(lineWidth: 2, dash: [8])
                )
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(vm.isTargeted
                              ? Color.accentColor.opacity(0.08)
                              : Color.secondary.opacity(0.04))
                )

            VStack(spacing: 12) {
                Image(systemName: "waveform.badge.plus")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)

                Text("Перетащите аудио или видео файлы")
                    .font(.title3.weight(.medium))

                Text("MP3 · M4A · WAV · MP4 · MOV и другие")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Выбрать файл") { vm.openFilePicker() }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }

            if let error = vm.error {
                VStack {
                    Spacer()
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .padding(10)
                        .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                        .padding()
                }
            }
        }
        .padding(24)
        .frame(height: vm.droppedFiles.isEmpty ? 300 : 160)
        .animation(.easeInOut(duration: 0.2), value: vm.isTargeted)
        .onDrop(of: [.fileURL], isTargeted: $vm.isTargeted) { providers in
            vm.handleDrop(providers: providers)
        }
    }

    // MARK: – Список файлов

    private var fileList: some View {
        List {
            ForEach(vm.droppedFiles, id: \.id) { file in
                HStack(spacing: 12) {
                    Image(systemName: iconName(for: file.format))
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 32)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.name)
                            .font(.body.weight(.medium))
                        HStack(spacing: 8) {
                            Text(file.format)
                            Text("·")
                            Text(file.formattedDuration)
                            Text("·")
                            Text(file.formattedFileSize)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        vm.removeFile(file)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 4)
            }
        }
        .listStyle(.plain)
        .frame(minHeight: 120, maxHeight: 300)
    }

    // MARK: – Нижняя панель

    private var actionBar: some View {
        HStack {
            Text("\(vm.droppedFiles.count) файл(ов)")
                .foregroundStyle(.secondary)
                .font(.subheadline)

            Spacer()

            Button("Очистить") { vm.clearAll() }
                .buttonStyle(.bordered)

            Button("Обработать →") {
                onStartProcessing(vm.droppedFiles)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.bar)
    }

    // MARK: – Иконки

    private func iconName(for format: String) -> String {
        switch format.uppercased() {
        case "MP4", "MOV", "M4V", "MKV": return "film"
        default:                          return "waveform"
        }
    }
}
