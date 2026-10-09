import SwiftUI
import AgentServices

/// Keep row identity stable, while allowing asynchronous discovery to add candidates.
struct ModelSelectionView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var models: [ConversationModel]
    @State private var selected: String
    @State private var search = ""
    let title: String
    let defaultLabel: String
    let choose: (String) -> Void
    let availableModels: [ConversationModel]
    let loading: Bool
    let message: String
    let reload: (Bool) async -> Void
    init(title: String, models: [ConversationModel], selected: String, defaultLabel: String = "", loading: Bool = false, message: String = "", reload: @escaping (Bool) async -> Void, choose: @escaping (String) -> Void) {
        self.title = title; self.defaultLabel = defaultLabel; self.choose = choose
        availableModels = models; self.loading = loading; self.message = message; self.reload = reload
        _models = State(initialValue: Self.snapshot(models, selected: selected))
        _selected = State(initialValue: selected)
    }
    private static func snapshot(_ models: [ConversationModel], selected: String) -> [ConversationModel] {
        var unique = Dictionary(models.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if !selected.isEmpty, unique[selected] == nil { unique[selected] = ConversationModel(id: selected, title: selected) }
        return unique.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    private var visible: [ConversationModel] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? models : models.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        List {
            if loading { ProgressView("モデル一覧を取得中") }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
            if !defaultLabel.isEmpty, search.isEmpty { row(id: "", title: defaultLabel) }
            ForEach(visible) { model in row(id: model.id, title: model.title) }
            if visible.isEmpty { Text("該当するモデルがありません").foregroundStyle(.secondary) }
        }
        .searchable(text: $search, prompt: "モデル名を検索")
        .navigationTitle(title)
        .toolbar {
            Text("\(models.count)モデル").font(.caption).foregroundStyle(.secondary)
            Button { Task { await reload(true) } } label: { Image(systemName: "arrow.clockwise") }.disabled(loading).accessibilityLabel("モデル一覧を更新")
        }
        .onChange(of: availableModels) { values in models = Self.snapshot(values, selected: selected) }
        .task { if availableModels.isEmpty { await reload(false) } }
    }
    private func row(id: String, title: String) -> some View {
        Button {
            selected = id; choose(id); dismiss()
        } label: {
            HStack {
                Text(title).font(.body).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "checkmark").foregroundStyle(.tint).opacity(selected == id ? 1 : 0)
            }.padding(.vertical, 6).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selected == id ? .isSelected : [])
    }
}
