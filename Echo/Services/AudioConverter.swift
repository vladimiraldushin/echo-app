import Foundation
import AVFoundation
import CoreMedia

/// Конвертирует любой аудио/видеофайл в массив Float32 сэмплов (16kHz mono)
/// — формат, требуемый FluidAudio SDK
actor AudioConverter {

    enum ConversionError: LocalizedError {
        case fileNotFound
        case noAudioTrack
        case exportFailed(String)
        case readFailed(String)

        var errorDescription: String? {
            switch self {
            case .fileNotFound:       return "Файл не найден"
            case .noAudioTrack:       return "Аудиодорожка не найдена"
            case .exportFailed(let m): return "Ошибка экспорта: \(m)"
            case .readFailed(let m):   return "Ошибка чтения: \(m)"
            }
        }
    }

    private let targetSampleRate: Double = 16_000
    private let targetChannels: UInt32 = 1

    /// Конвертировать файл → [Float] (16kHz mono PCM)
    func convert(url: URL) async throws -> [Float] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ConversionError.fileNotFound
        }

        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw ConversionError.noAudioTrack }

        // Экспортируем в временный WAV
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".caf")

        defer { try? FileManager.default.removeItem(at: tempURL) }

        try await exportToWAV(asset: asset, outputURL: tempURL)
        return try readSamples(from: tempURL)
    }

    // MARK: – Приватные методы

    private func exportToWAV(asset: AVAsset, outputURL: URL) async throws {
        // Экспортируем с точным контролем формата через AVAssetWriter
        try await exportWithWriter(asset: asset, outputURL: outputURL)
    }

    private func exportWithWriter(asset: AVAsset, outputURL: URL) async throws {
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .caf)

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: targetChannels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: outputSettings)
        writerInput.expectsMediaDataInRealTime = false
        writer.add(writerInput)

        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let firstTrack = tracks.first else { throw ConversionError.noAudioTrack }

        let readerOutput = AVAssetReaderTrackOutput(
            track: firstTrack,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: targetSampleRate,
                AVNumberOfChannelsKey: targetChannels,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        )

        let reader = try AVAssetReader(asset: asset)
        reader.add(readerOutput)

        reader.startReading()
        writer.startWriting()
        writer.startSession(atSourceTime: CMTime.zero)

        await withCheckedContinuation { continuation in
            writerInput.requestMediaDataWhenReady(on: DispatchQueue(label: "audio.converter")) {
                while writerInput.isReadyForMoreMediaData {
                    if let buffer = readerOutput.copyNextSampleBuffer() {
                        writerInput.append(buffer)
                    } else {
                        writerInput.markAsFinished()
                        writer.finishWriting { continuation.resume() }
                        return
                    }
                }
            }
        }

        if let error = writer.error { throw ConversionError.exportFailed(error.localizedDescription) }
        if let error = reader.error { throw ConversionError.readFailed(error.localizedDescription) }
    }

    private func readSamples(from url: URL) throws -> [Float] {
        let audioFile = try AVAudioFile(forReading: url)
        
        var samples: [Float] = []
        samples.reserveCapacity(Int(audioFile.length))
        
        // Читаем файл по частям для экономии памяти
        let bufferSize: AVAudioFrameCount = 4096
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: audioFile.processingFormat,
            frameCapacity: bufferSize
        ) else {
            throw ConversionError.readFailed("Не удалось выделить буфер")
        }
        
        while audioFile.framePosition < audioFile.length {
            try audioFile.read(into: buffer)
            
            guard let channelData = buffer.floatChannelData?[0] else {
                throw ConversionError.readFailed("Нет данных канала")
            }
            
            samples.append(contentsOf: UnsafeBufferPointer(
                start: channelData,
                count: Int(buffer.frameLength)
            ))
        }
        
        return samples
    }
}
