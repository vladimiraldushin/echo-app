import SwiftUI

/// Корневой экран: импорт → транскрипция
struct ContentView: View {
    @State private var currentFile: AudioFile?
    @State private var showImport = true

    var body: some View {
        Group {
            if showImport || currentFile == nil {
                ImportView { files in
                    if let first = files.first {
                        currentFile = first
                        showImport = false
                    }
                }
                .navigationTitle("Echo")
            } else if let file = currentFile {
                TranscriptionView(file: file)
                    .toolbar {
                        ToolbarItem(placement: .navigation) {
                            Button {
                                showImport = true
                                currentFile = nil
                            } label: {
                                Label("Назад", systemImage: "chevron.left")
                            }
                        }
                    }
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .onReceive(NotificationCenter.default.publisher(for: .openFilePicker)) { _ in
            showImport = true
        }
    }
}
