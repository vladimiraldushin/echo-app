# ⚠️ ВАЖНО: Исправлена ошибка API

## Проблемы:
1. ❌ Ошибка компиляции: **"Extra argument 'config' in call"**
2. ❌ Ошибка компиляции: **"Cannot find type 'TimedSpeakerSegment' in scope"**

## Причины:

### Проблема 1: Extra argument 'config'
API FluidAudio SDK работает иначе, чем предполагалось:
- Конфигурация передаётся в **конструктор** `OfflineDiarizerManager(config:)`
- Метод `process(audio:)` **не принимает** параметр `config`

### Проблема 2: TimedSpeakerSegment
- Тип `TimedSpeakerSegment` определён в `DiarizerTypes.swift`
- Из-за проблем видимости модулей, создана локальная структура `DiarizationSegment`

## Решения:

### ✅ Исправлен `DiarizationService.swift`:

**Было (неправильно):**
```swift
let diarizer = OfflineDiarizerManager()  // Без конфигурации
try await diarizer.process(audio: samples, config: config)  // ❌ Ошибка!
```

**Стало (правильно):**
```swift
let diarizer = OfflineDiarizerManager(config: config)  // ✅ Конфиг в конструкторе
try await diarizer.process(audio: samples)  // ✅ Без параметра config
```

### ✅ Исправлен `TranscriptionViewModel.swift`:

**Изменения:**
- `DiarizerConfig` → `OfflineDiarizerConfig`
- `config.minSpeechDuration` → убрано (нет в API)
- `config.debugMode` → убрано (нет в API)
- `config.numClusters` → `config.clustering.numSpeakers`

**Теперь работает:**
```swift
var diarizationConfig = OfflineDiarizerConfig.default
diarizationConfig.clusteringThreshold = 0.6

if expectedSpeakers > 0 {
    diarizationConfig.clustering.numSpeakers = expectedSpeakers
}

let result = try await diarizationService.diarize(
    samples: samples,
    config: diarizationConfig
)
```

### ✅ Исправлен `AlignmentDiagnostics.swift`:

**Проблема:** Тип `TimedSpeakerSegment` не был виден

**Решение:** Создана локальная структура `DiarizationSegment`:
```swift
struct DiarizationSegment {
    let speakerId: String
    let startTimeSeconds: Float
    let endTimeSeconds: Float
}
```

И добавлено преобразование в `TranscriptionViewModel`:
```swift
let convertedSegments = diarizationResult.segments.map { seg in
    DiarizationSegment(
        speakerId: seg.speakerId,
        startTimeSeconds: seg.startTimeSeconds,
        endTimeSeconds: seg.endTimeSeconds
    )
}
```

---

## 🔧 Что теперь доступно в `OfflineDiarizerConfig`:

### Основные параметры:

```swift
var config = OfflineDiarizerConfig.default

// Порог кластеризации (главный параметр для количества спикеров)
config.clusteringThreshold = 0.6  // 0.4-0.9

// Количество спикеров (если знаете точно)
config.clustering.numSpeakers = 2  // 0 = автоопределение
config.clustering.minSpeakers = 1
config.clustering.maxSpeakers = 20

// Параметры VBx (продвинутые)
config.vbx.maxIterations = 10
config.vbx.convergenceTolerance = 0.001

// Постобработка
config.postProcessing.minGapDurationSeconds = 0.0
```

### Структура конфигурации:

```
OfflineDiarizerConfig
├── segmentation: Segmentation
│   ├── windowDurationSeconds
│   ├── sampleRate
│   ├── minDurationOn
│   ├── minDurationOff
│   └── ...
├── embedding: Embedding
│   ├── batchSize
│   ├── excludeOverlap
│   └── ...
├── clustering: Clustering ← Здесь количество спикеров
│   ├── threshold
│   ├── numSpeakers
│   ├── minSpeakers
│   ├── maxSpeakers
│   └── ...
├── vbx: VBx
└── postProcessing: PostProcessing
```

---

## 📝 Обновлённая документация:

Файлы, которые **НЕ нужно обновлять** (они используют правильный API):
- ✅ `БЫСТРЫЙ_СТАРТ.md`
- ✅ `ШПАРГАЛКА.md`
- ✅ `КАК_ЧИТАТЬ_ЛОГИ.md`
- ✅ `УСТАНОВКА_ЗАВЕРШЕНА.md`

Файлы с примерами кода обновлены автоматически через изменения в коде.

---

## 🚀 Что делать:

1. **Проект должен собираться без ошибок:**
   ```
   Cmd + B
   ```

2. **Запустите приложение:**
   ```
   Cmd + R
   ```

3. **Проверьте консоль:**
   ```
   Cmd + Shift + Y
   ```

Теперь всё должно работать! 🎉

---

**Исправлено:** 28 февраля 2026
