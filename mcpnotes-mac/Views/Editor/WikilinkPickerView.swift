import MCPNotesCore
import SwiftUI

struct WikilinkPickerView: View {
    let notes: [Note]
    let onSelect: (String) -> Void

    @State private var search = ""
    @FocusState private var isSearchFocused: Bool

    private var filtered: [Note] {
        let sorted = notes.sorted { $0.createdAt > $1.createdAt }
        if search.isEmpty { return sorted }
        let q = search.lowercased()
        return sorted.filter { $0.filename.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search notes…", text: $search)
                .textFieldStyle(.plain)
                .padding(10)
                .focused($isSearchFocused)

            Divider()

            if filtered.isEmpty {
                Text("No notes found")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filtered) { note in
                    Button {
                        onSelect("[[\(note.filename)]]")
                    } label: {
                        Text(note.filename)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 2)
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 260, height: 320)
        .onAppear { isSearchFocused = true }
    }
}
