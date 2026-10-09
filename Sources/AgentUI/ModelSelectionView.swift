import SwiftUI
import AgentServices

/// A stable snapshot avoids native Picker scrolling back whenever recording status updates.
struct ModelSelectionView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var models: [ConversationModel]
    @State private var selected: String
    @State private var search = ""
    let title: String
    let defaultLabel: String
    let choose: (String) -> Void
    init(title: String, models: [ConversationModel], selected: String, defaultLabel: String = "", choose: @escaping (String) -> Void) {
        self.title = title; self.defaultLabel = defaultLabel; self.choose = choose
        var unique = Dictionary(models.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if !selected.isEmpty, unique[selected] == nil { unique[selected] = ConversationModel(id: selected, title: selected) }
        _models = State(initialValue: unique.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending })
        _selected = State(initialValue: selected)
    }
    private var visible: [ConversationModel] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? models : models.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query) }
    }
    var body: some View {
        List {
            if !defaultLabel.isEmpty, search.isEmpty { row(id: "", title: defaultLabel) }
            ForEach(visible) { model in row(id: model.id, title: model.title) }
            if visible.isEmpty { Text("該当するモデルがありません").foregroundStyle(.secondary) }
        }
        .searchable(text: $search, prompt: "モデル名を検索")
        .navigationTitle(title)
        .toolbar { Text("\(models.count)モデル").font(.caption).foregroundStyle(.secondary) }
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
