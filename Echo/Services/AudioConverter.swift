import Foundation
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
        case ffmpegNotInstalled

        var errorDescription: String? {
            switch self {
            case .fileNotFound:       
                return "Файл не найден"
            case .noAudioTrack:       
                return "Аудиодорожка не найдена"
            case .exportFailed(let m): 
                return "Ошибка экспорта: \(m)"
            case .readFailed(let m):   
                return "Ошибка чтения: \(m)"
            case .ffmpegNotInstalled:
                return """
                ❌ Не удалось автоматически установить зависимости!
                
                WebM файлы требуют FFmpeg для конвертации.
                
                Возможно, требуется ввод пароля администратора.
                Попробуйте установить вручную в Terminal:
                
                /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
                brew install ffmpeg
                """
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

        // ✅ ПРОАКТИВНАЯ проверка WebM — сразу конвертируем без мудни!
        if url.pathExtension.lowercased() == "webm" {
            print("🎬 WebM detected → auto-converting...")
            return try await convertViaAFConvert(url: url)
        }

        // Обычная обработка для других форматов
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw ConversionError.noAudioTrack }

        // Экспортируем в временный CAF
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".caf")

        defer { try? FileManager.default.removeItem(at: tempURL) }

        try await exportToWAV(asset: asset, outputURL: tempURL)
        return try readSamples(from: tempURL)
    }
    
    // MARK: - WebM автоконвертация
    
    /// Автоматическая конвертация WebM через ffmpeg (afconvert НЕ поддерживает WebM!)
    private func convertViaAFConvert(url: URL) async throws -> [Float] {
        // WebM ТРЕБУЕТ ffmpeg — afconvert его не поддерживает
        return try await convertWithFFmpeg(url: url)
    }
    
    /// Конвертация через ffmpeg (с автоустановкой, если нужно)
    private func convertWithFFmpeg(url: URL) async throws -> [Float] {
        // Проверяем наличие ffmpeg
        let ffmpegPaths = [
            "/opt/homebrew/bin/ffmpeg",  // Apple Silicon
            "/usr/local/bin/ffmpeg",      // Intel Mac
            "/usr/bin/ffmpeg"             // Системный (редко)
        ]
        
        var ffmpegPath = ffmpegPaths.first(where: { FileManager.default.fileExists(atPath: $0) })
        
        // Если FFmpeg не найден — устанавливаем автоматически!
        if ffmpegPath == nil {
            print("❌ FFmpeg не найден!")
            print("📦 Автоматическая установка через Homebrew...")
            
            do {
                try await installFFmpegAutomatically()
                
                // Проверяем снова после установки
                ffmpegPath = ffmpegPaths.first(where: { FileManager.default.fileExists(atPath: $0) })
                
                guard ffmpegPath != nil else {
                    throw ConversionError.ffmpegNotInstalled
                }
                
                print("✅ FFmpeg успешно установлен!")
            } catch {
                print("❌ Не удалось установить FFmpeg автоматически")
                throw ConversionError.ffmpegNotInstalled
            }
        }
        
        guard let validFFmpegPath = ffmpegPath else {
            throw ConversionError.ffmpegNotInstalled
        }
        
        let tempWAV = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".wav")
        
        defer { try? FileManager.default.removeItem(at: tempWAV) }
        
        print("🔄 Converting via ffmpeg (\(validFFmpegPath))...")
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: validFFmpegPath)
        process.arguments = [
            "-i", url.path,
            "-vn",                    // Только аудио
            "-ar", "16000",           // 16kHz
            "-ac", "1",               // Mono
            "-f", "wav",              // WAV формат
            tempWAV.path,
            "-y"                      // Перезаписать
        ]
        
        // Подавляем вывод ffmpeg
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            throw ConversionError.exportFailed("FFmpeg failed with code \(process.terminationStatus)")
        }
        
        print("✅ Converted to WAV! Processing...")
        return try readSamples(from: tempWAV)
    }
    
    /// Автоматическая установка FFmpeg через Homebrew (с автоустановкой Homebrew!)
    private func installFFmpegAutomatically() async throws {
        // Проверяем, установлен ли Homebrew
        let brewPaths = [
            "/opt/homebrew/bin/brew",  // Apple Silicon
            "/usr/local/bin/brew"       // Intel Mac
        ]
        
        var brewPath = brewPaths.first(where: { FileManager.default.fileExists(atPath: $0) })
        
        // Если Homebrew не найден — устанавливаем его тоже!
        if brewPath == nil {
            print("❌ Homebrew не установлен!")
            print("📦 Автоматическая установка Homebrew...")
            
            do {
                try await installHomebrewAutomatically()
                
                // Проверяем снова после установки
                brewPath = brewPaths.first(where: { FileManager.default.fileExists(atPath: $0) })
                
                guard brewPath != nil else {
                    throw ConversionError.ffmpegNotInstalled
                }
                
                print("✅ Homebrew успешно установлен!")
            } catch {
                print("❌ Не удалось установить Homebrew автоматически")
                throw ConversionError.ffmpegNotInstalled
            }
        }
        
        guard let validBrewPath = brewPath else {
            throw ConversionError.ffmpegNotInstalled
        }
        
        print("🍺 Homebrew найден: \(validBrewPath)")
        print("📦 Устанавливаю FFmpeg... (это займёт ~1-2 минуты)")
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: validBrewPath)
        process.arguments = ["install", "ffmpeg"]
        
        // Показываем вывод в консоли
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        try process.run()
        
        // Читаем вывод в фоне
        Task {
            let handle = pipe.fileHandleForReading
            while process.isRunning {
                if let data = try? handle.availableData, !data.isEmpty {
                    if let output = String(data: data, encoding: .utf8) {
                        print(output, terminator: "")
                    }
                }
            }
        }
        
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            throw ConversionError.exportFailed("Homebrew installation failed")
        }
        
        print("✅ FFmpeg установлен!")
    }
    
    /// Автоматическая установка Homebrew
    private func installHomebrewAutomatically() async throws {
        print("🍺 Устанавливаю Homebrew... (это займёт ~3-5 минут)")
        
        // Официальный скрипт установки Homebrew
        let installScript = """
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        """
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", installScript]
        
        // Показываем вывод в консоли
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        // Читаем вывод в фоне
        Task {
            let handle = pipe.fileHandleForReading
            while process.isRunning {
                if let data = try? handle.availableData, !data.isEmpty {
                    if let output = String(data: data, encoding: .utf8) {
                        print(output, terminator: "")
                    }
                }
            }
        }
        
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            throw ConversionError.exportFailed("Homebrew installation failed")
        }
        
        print("✅ Homebrew установлен!")
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
