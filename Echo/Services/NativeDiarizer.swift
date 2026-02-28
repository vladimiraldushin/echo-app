import Foundation
import Accelerate

/// Нативная диаризация на основе спектральных признаков + k-means.
///
/// Заменяет FluidAudio для определения спикеров в телефонных разговорах.
/// Использует Accelerate framework для быстрого FFT.
///
/// Алгоритм:
/// 1. Для каждого слова извлекаем спектральные признаки
/// 2. Группируем слова в реплики по паузам
/// 3. Усредняем признаки по репликам
/// 4. K-means++ кластеризация → индексы спикеров
struct NativeDiarizer {

    private let sampleRate = 16000
    private let fftSize = 512
    private let hopSize = 256

    /// Минимальная пауза для разделения реплик (секунды)
    private let turnPause: Double = 0.6

    // MARK: - Public

    /// Диаризует аудио, возвращая индекс спикера для каждого слова.
    func diarize(
        samples: [Float],
        words: [EchoTokenTiming],
        numSpeakers: Int = 2
    ) -> [Int] {
        guard words.count >= 2 else {
            return Array(repeating: 0, count: words.count)
        }

        print("   🎤 NativeDiarizer: обработка \(words.count) слов...")

        // 1. FFT setup (один раз)
        let log2n = vDSP_Length(log2(Float(fftSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            print("   ❌ Не удалось создать FFT setup")
            return Array(repeating: 0, count: words.count)
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        // Hann window (один раз)
        var hannWindow = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&hannWindow, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        // 2. Спектральные признаки каждого слова
        let wordFeatures = words.map { word -> [Float] in
            let startIdx = max(0, Int(word.startTime * Double(sampleRate)))
            let endIdx = min(samples.count, Int(word.endTime * Double(sampleRate)))
            guard startIdx < endIdx, endIdx - startIdx > 10 else {
                return [Float](repeating: 0, count: 6)
            }
            return extractFeatures(
                Array(samples[startIdx..<endIdx]),
                fftSetup: fftSetup,
                hannWindow: hannWindow
            )
        }

        // 3. Группировка в реплики по паузам
        var utterances: [[Int]] = [[0]]
        for i in 1..<words.count {
            let pause = words[i].startTime - words[i - 1].endTime
            if pause > turnPause {
                utterances.append([i])
            } else {
                utterances[utterances.count - 1].append(i)
            }
        }

        print("   📊 \(utterances.count) реплик (паузы > \(turnPause)с)")

        guard utterances.count >= numSpeakers else {
            print("   ⚠️  Слишком мало реплик для \(numSpeakers) спикеров")
            return Array(repeating: 0, count: words.count)
        }

        // 4. Средние признаки по репликам
        let uttFeatures: [[Float]] = utterances.map { indices in
            let feats = indices.compactMap { idx -> [Float]? in
                let f = wordFeatures[idx]
                return f.allSatisfy({ $0 == 0 }) ? nil : f
            }
            guard !feats.isEmpty else {
                return [Float](repeating: 0, count: 6)
            }
            return averageVectors(feats)
        }

        // 5. Нормализация (z-score)
        let normalized = zScoreNormalize(uttFeatures)

        // 6. K-means++ кластеризация
        let uttLabels = kmeans(vectors: normalized, k: numSpeakers)

        // 7. Проверка баланса: если один кластер < 10% — fallback
        let counts = (0..<numSpeakers).map { s in uttLabels.filter { $0 == s }.count }
        let minCount = counts.min() ?? 0
        let maxCount = counts.max() ?? 1
        let ratio = Float(minCount) / Float(max(maxCount, 1))

        var finalUttLabels = uttLabels
        if ratio < 0.05 {
            print("   ⚠️  Кластеризация не разделила спикеров (ratio=\(String(format: "%.2f", ratio))), fallback на чередование")
            finalUttLabels = alternatingLabels(count: utterances.count, k: numSpeakers)
        }

        // 8. Раскладываем метки на слова
        var wordLabels = Array(repeating: 0, count: words.count)
        for (uIdx, indices) in utterances.enumerated() {
            for wIdx in indices {
                wordLabels[wIdx] = finalUttLabels[uIdx]
            }
        }

        for s in 0..<numSpeakers {
            let count = wordLabels.filter { $0 == s }.count
            let pct = Int(Double(count) / Double(words.count) * 100)
            print("   • Спикер \(s): \(count) слов (\(pct)%)")
        }

        return wordLabels
    }

    // MARK: - Feature Extraction

    /// 6 признаков: RMS, spectral centroid, bandwidth, rolloff, ZCR, dominant pitch
    private func extractFeatures(
        _ segment: [Float],
        fftSetup: FFTSetup,
        hannWindow: [Float]
    ) -> [Float] {
        // RMS energy
        var rms: Float = 0
        vDSP_rmsqv(segment, 1, &rms, vDSP_Length(segment.count))

        // Zero-crossing rate
        var zcr: Float = 0
        if segment.count > 1 {
            for i in 1..<segment.count {
                if (segment[i] >= 0) != (segment[i - 1] >= 0) { zcr += 1 }
            }
            zcr /= Float(segment.count - 1)
        }

        // Спектральные признаки из overlapping frames
        var centroids: [Float] = []
        var bandwidths: [Float] = []
        var rolloffs: [Float] = []
        var peaks: [Float] = []

        if segment.count >= fftSize {
            var offset = 0
            while offset + fftSize <= segment.count {
                let frame = Array(segment[offset..<offset + fftSize])
                let s = spectralFeatures(frame, fftSetup: fftSetup, hannWindow: hannWindow)
                centroids.append(s.centroid)
                bandwidths.append(s.bandwidth)
                rolloffs.append(s.rolloff)
                peaks.append(s.peak)
                offset += hopSize
            }
        } else {
            var padded = [Float](repeating: 0, count: fftSize)
            for i in 0..<segment.count { padded[i] = segment[i] }
            let s = spectralFeatures(padded, fftSetup: fftSetup, hannWindow: hannWindow)
            centroids.append(s.centroid)
            bandwidths.append(s.bandwidth)
            rolloffs.append(s.rolloff)
            peaks.append(s.peak)
        }

        let avg = { (arr: [Float]) -> Float in
            arr.isEmpty ? 0 : arr.reduce(0, +) / Float(arr.count)
        }

        return [rms, avg(centroids), avg(bandwidths), avg(rolloffs), zcr, avg(peaks)]
    }

    /// Спектральные признаки одного 512-sample frame
    private func spectralFeatures(
        _ frame: [Float],
        fftSetup: FFTSetup,
        hannWindow: [Float]
    ) -> (centroid: Float, bandwidth: Float, rolloff: Float, peak: Float) {
        let halfN = fftSize / 2

        // Apply Hann window
        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(frame, 1, hannWindow, 1, &windowed, 1, vDSP_Length(fftSize))

        // Pack into split complex (even → realp, odd → imagp)
        var realp = [Float](repeating: 0, count: halfN)
        var imagp = [Float](repeating: 0, count: halfN)
        for i in 0..<halfN {
            realp[i] = windowed[2 * i]
            imagp[i] = windowed[2 * i + 1]
        }

        // In-place real FFT
        var split = DSPSplitComplex(realp: &realp, imagp: &imagp)
        let log2n = vDSP_Length(log2(Float(fftSize)))
        vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))

        // Squared magnitudes → magnitudes
        var mags = [Float](repeating: 0, count: halfN)
        vDSP_zvmags(&split, 1, &mags, 1, vDSP_Length(halfN))
        var sqrtCount = Int32(halfN)
        vvsqrtf(&mags, mags, &sqrtCount)

        let freqRes = Float(sampleRate) / Float(fftSize)

        // Sum of magnitudes
        var magSum: Float = 0
        vDSP_sve(mags, 1, &magSum, vDSP_Length(halfN))
        guard magSum > 1e-10 else { return (0, 0, 0, 0) }

        // Spectral centroid = Σ(f * mag) / Σ(mag)
        let freqs = (0..<halfN).map { Float($0) * freqRes }
        var weightedSum: Float = 0
        freqs.withUnsafeBufferPointer { fp in
            mags.withUnsafeBufferPointer { mp in
                vDSP_dotpr(fp.baseAddress!, 1, mp.baseAddress!, 1, &weightedSum, vDSP_Length(halfN))
            }
        }
        let centroid = weightedSum / magSum

        // Spectral bandwidth
        let diffs = freqs.map { ($0 - centroid) * ($0 - centroid) }
        var bwSum: Float = 0
        diffs.withUnsafeBufferPointer { dp in
            mags.withUnsafeBufferPointer { mp in
                vDSP_dotpr(dp.baseAddress!, 1, mp.baseAddress!, 1, &bwSum, vDSP_Length(halfN))
            }
        }
        let bandwidth = sqrt(bwSum / magSum)

        // Spectral rolloff (85%)
        let threshold = magSum * 0.85
        var cumSum: Float = 0
        var rolloff: Float = freqs.last ?? 0
        for i in 0..<halfN {
            cumSum += mags[i]
            if cumSum >= threshold {
                rolloff = freqs[i]
                break
            }
        }

        // Dominant peak in speech F0 range (80–400 Hz)
        let minBin = max(1, Int(80.0 / freqRes))
        let maxBin = min(halfN - 1, Int(400.0 / freqRes))
        var peakFreq: Float = 0
        var peakMag: Float = 0
        if minBin < maxBin {
            for i in minBin...maxBin {
                if mags[i] > peakMag { peakMag = mags[i]; peakFreq = freqs[i] }
            }
        }

        return (centroid, bandwidth, rolloff, peakFreq)
    }

    // MARK: - Clustering

    private func averageVectors(_ vectors: [[Float]]) -> [Float] {
        guard let first = vectors.first else { return [] }
        var avg = [Float](repeating: 0, count: first.count)
        for vec in vectors {
            for i in 0..<min(avg.count, vec.count) { avg[i] += vec[i] }
        }
        let n = Float(vectors.count)
        return avg.map { $0 / n }
    }

    private func zScoreNormalize(_ vectors: [[Float]]) -> [[Float]] {
        guard let first = vectors.first, vectors.count > 1 else { return vectors }
        let dims = first.count
        var means = [Float](repeating: 0, count: dims)
        var stds = [Float](repeating: 0, count: dims)
        for d in 0..<dims {
            let vals = vectors.map { $0[d] }
            means[d] = vals.reduce(0, +) / Float(vals.count)
            let v = vals.map { ($0 - means[d]) * ($0 - means[d]) }.reduce(0, +) / Float(vals.count)
            stds[d] = sqrt(v)
            if stds[d] < 1e-8 { stds[d] = 1 }
        }
        return vectors.map { vec in
            (0..<dims).map { (vec[$0] - means[$0]) / stds[$0] }
        }
    }

    /// K-means++ кластеризация
    private func kmeans(vectors: [[Float]], k: Int, maxIter: Int = 100) -> [Int] {
        let n = vectors.count
        guard n >= k, let first = vectors.first else {
            return Array(repeating: 0, count: n)
        }
        let dims = first.count

        // K-means++ init: первый центроид — случайный, следующие — максимально далёкие
        var centroids: [[Float]] = [vectors[0]]
        for _ in 1..<k {
            let dists = vectors.map { v -> Float in
                centroids.map { c in
                    zip(v, c).map { ($0.0 - $0.1) * ($0.0 - $0.1) }.reduce(0, +)
                }.min() ?? 0
            }
            let maxIdx = dists.enumerated().max(by: { $0.1 < $1.1 })?.0 ?? 0
            centroids.append(vectors[maxIdx])
        }

        var labels = [Int](repeating: 0, count: n)

        for _ in 0..<maxIter {
            var changed = false
            for i in 0..<n {
                var best = 0
                var bestD: Float = .infinity
                for j in 0..<k {
                    let d = zip(vectors[i], centroids[j])
                        .map { ($0.0 - $0.1) * ($0.0 - $0.1) }
                        .reduce(0, +)
                    if d < bestD { bestD = d; best = j }
                }
                if labels[i] != best { changed = true; labels[i] = best }
            }
            if !changed { break }

            for j in 0..<k {
                var sum = [Float](repeating: 0, count: dims)
                var cnt = 0
                for i in 0..<n where labels[i] == j {
                    for d in 0..<dims { sum[d] += vectors[i][d] }
                    cnt += 1
                }
                if cnt > 0 { centroids[j] = sum.map { $0 / Float(cnt) } }
            }
        }

        return labels
    }

    /// Fallback: чередование спикеров по репликам
    private func alternatingLabels(count: Int, k: Int) -> [Int] {
        (0..<count).map { $0 % k }
    }
}
