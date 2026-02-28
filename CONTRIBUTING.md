# Участие в разработке Echo

## Рабочий процесс

### Обязательные правила после каждого значимого изменения

1. **`git push`** — запушить изменения в репозиторий
2. **Changelog в Notion** — добавить запись сверху со ссылкой на коммит/PR
3. **Трекер проектов** — обновить поле «Следующий шаг»
4. **Статус** — обновить если фаза изменилась (Этап 1 → Этап 2 и т.д.)

> ❌ Нельзя обновить Changelog без пуша в GitHub.
> ❌ Нельзя пушить и не обновить Changelog.

---

## Формат коммитов

```
<тип>: <краткое описание> (Этап N)
```

**Типы:**
- `feat` — новая функциональность
- `fix` — исправление бага
- `refactor` — рефакторинг без изменения поведения
- `docs` — изменения в документации
- `test` — добавление или изменение тестов
- `chore` — рутинные задачи (настройка, зависимости)

**Примеры:**
```
feat: AudioConverter 16kHz mono Float32 PCM (Этап 1)
feat: TranscriptionService базовая транскрипция (Этап 1)
fix: crash при пустом аудиофайле
refactor: AlignmentService оптимизация алгоритма перекрытия
docs: обновить README секцию архитектуры
test: unit-тесты для ExportService
```

---

## Ветки

```
main          — стабильный код, только через PR
feat/этап-1-transcription   — разработка Этапа 1
feat/этап-2-diarization     — разработка Этапа 2
feat/этап-3-full-product    — разработка Этапа 3
fix/название-бага           — исправление конкретного бага
```

---

## Структура PR

Заголовок PR: `feat: краткое описание (Этап N)`

Описание PR обязательно включает:
- **Что сделано** — список изменений
- **Файлы** — новые и изменённые файлы
- **Как проверить** — шаги для ревью
- **Ссылка на Notion Changelog** — запись с этим PR

---

## Структура кода

```
Echo/
├── App/                    # AppDelegate, DI контейнер, SwiftData setup
├── Features/               # UI-модули по функциям (MVVM)
│   ├── Import/
│   ├── Transcription/
│   ├── History/
│   └── Export/
├── Services/               # Бизнес-логика, без UI-зависимостей
├── Models/                 # Доменные модели (Codable, SwiftData)
└── Resources/              # Локализация, Assets
```

**Правила:**
- `Views` не содержат бизнес-логику
- `ViewModels` не импортируют SwiftUI
- `Services` не знают о `ViewModels`
- Все асинхронные операции через `async/await`
- `@MainActor` для всех UI-операций

---

## Тесты

Перед пушем в `main` проверить:

```bash
xcodebuild test -scheme Echo -destination 'platform=macOS'
```

Покрытие тестами обязательно для:
- `AudioConverter`
- `AlignmentService`
- `ExportService` (все форматы)

---

## Notion-ссылки

| Ресурс | Ссылка |
|---|---|
| Страница проекта | https://www.notion.so/315252c23cda815ab6bdd4c098fe460a |
| Changelog | https://www.notion.so/315252c23cda81989f67d586810d0fc3 |
| ТЗ | https://www.notion.so/315252c23cda819091dee638e7c8daab |
| Трекер проектов | https://www.notion.so/706c71386f6b4cac95a20b1ecabbe944 |
