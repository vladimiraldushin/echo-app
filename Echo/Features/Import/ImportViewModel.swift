import Foundation
import AVFoundation
import SwiftUI

@MainActor
final class ImportViewModel: ObservableObject {

    @Published var droppedFiles: [AudioFile] = []
    @Published var isTargeted = false   // drag-over состояние
    @Published var error: String?

    private let supportedExtensions: Set<String> = [
        "mp3", "m4a", "wav", "aac", "ogg", "flac", "opus",
        "mp4", "mov", "m4v", "mkv"
    ]

    // MARK: – Drop handler

    func handleDrop(providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { [weak self] item, error in
                    guard let self else { return }
                    if let data = item as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil) {
                        Task { @MainActor in
                            await self.addFile(url: url)
                        }
                    }
                }
                handled = true
            }
        }
        return handled
    }

    // MARK: – Добавить файл через диалог

    func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = []
        panel.title = "Выберите аудио или видеофайл"

        if panel.runModal() == .OK {
            Task {
                for url in panel.urls {
                    await addFile(url: url)
                }
            }
        }
    }

    // MARK: – Добавить файл

    func addFile(url: URL) async {
        let ext = url.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else {
            error = "Формат .\(ext) не поддерживается"
            return
        }

        // Проверяем дубликат
        if droppedFiles.contains(where: { $0.url == url }) { return }

        let asset = AVURLAsset(url: url)
        let duration = try? await asset.load(.duration)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = attrs?[.size] as? Int64 ?? 0

        let file = AudioFile(
            url: url,
            name: url.deletingPathExtension().lastPathComponent,
            duration: duration?.seconds ?? 0,
            fileSize: fileSize
        )
        droppedFiles.append(file)
        error = nil
    }

    func removeFile(_ file: AudioFile) {
        droppedFiles.removeAll { $0.id == file.id }
    }

    func clearAll() {
        droppedFiles.removeAll()
    }
}
