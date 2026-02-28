import SwiftUI

struct TranscriptionView: View {
    let file: AudioFile
    @StateObject private var vm = TranscriptionViewModel()
    @State private var selectedFormat: ExportService.ExportFormat = .txt

    var body: some View {
        HSplitView {
            // Левая панель: результат транскрипции
            resultPanel
                .frame(minWidth: 400)

            // Правая панель: настройки и экспорт
            sidePanel
                .frame(width: 220)
        }
        .frame(minWidth: 700, minHeight: 500)
        .toolbar { toolbarContent }
        .task { await vm.process(file: file) }
    }

    // MARK: – Панель результата

    private var resultPanel: some View {
        VStack(spacing: 0) {
            // Прогресс
            if vm.state.isProcessing {
                progressBar
            }

            // Поиск
            if case .completed = vm.state {
                searchBar
            }

            // Контент
            switch vm.state {
            case .idle, .converting, .transcribing, .diarizing:
                processingPlaceholder

            case .completed:
                if vm.filteredSegments.isEmpty && !vm.searchQuery.isEmpty {
                    noSearchResults
                } else {
                    segmentList
                }

            case .failed(let msg):
                errorView(msg)
            }
        }
    }

    private var progressBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(vm.state.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(vm.state.progress * 100))%")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: vm.state.progress)
                .progressViewStyle(.linear)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Поиск по тексту...", text: $vm.searchQuery)
                .textFieldStyle(.plain)
            if !vm.searchQuery.isEmpty {
                Button { vm.searchQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.textBackgroundColor))
        .overlay(Divider(), alignment: .bottom)
    }

    private var segmentList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(vm.filteredSegments, id: \.id) { segment in
                    let speaker = vm.result?.speaker(for: segment.speakerIndex)
                    SegmentRowView(
                        segment: segment,
                        speakerName: vm.result?.speakerName(for: segment.speakerIndex) ?? "Спикер",
                        speakerColor: speaker?.color ?? .secondary
                    )
                    .padding(.horizontal, 16)
                    Divider().padding(.leading, 31)
                }
            }
            .padding(.vertical, 8)
        }
    }

    private var processingPlaceholder: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            Text(vm.state.statusText)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noSearchResults: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Ничего не найдено")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.red)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Повторить") {
                Task { await vm.process(file: file) }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: – Боковая панель

    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Инфо о файле
            GroupBox("Файл") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(file.name).font(.headline).lineLimit(2)
                    Text("\(file.format) · \(file.formattedDuration)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Язык
            GroupBox("Язык") {
                Picker("", selection: $vm.selectedLanguage) {
                    Text("Русский").tag("ru")
                    Text("English").tag("en")
                    Text("Авто").tag("")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            // Экспорт
            if case .completed = vm.state {
                GroupBox("Экспорт") {
                    VStack(spacing: 8) {
                        Picker("Формат", selection: $selectedFormat) {
                            ForEach(ExportService.ExportFormat.allCases) { f in
                                Text(f.displayName).tag(f)
                            }
                        }
                        .pickerStyle(.menu)

                        Button("Сохранить") { vm.export(format: selectedFormat) }
                            .buttonStyle(.borderedProminent)
                            .frame(maxWidth: .infinity)
                    }
                }
            }

            Spacer()

            // Статистика
            if let result = vm.result {
                GroupBox("Статистика") {
                    VStack(alignment: .leading, spacing: 4) {
                        statRow("Сегментов", "\(result.segmentCount)")
                        statRow("Спикеров", "\(result.speakerCount)")
                        statRow("Язык", result.language.uppercased())
                    }
                }
            }
        }
        .padding(12)
        .background(Color(.windowBackgroundColor))
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption.weight(.medium))
        }
    }

    // MARK: – Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Text(file.name)
                .font(.headline)
        }
        ToolbarItem(placement: .status) {
            Text(vm.state.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
