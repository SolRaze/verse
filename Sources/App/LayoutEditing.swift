import SwiftUI

/// The edit-mode primitives Home and Library share (#2/#4/#14): drag the body to reorder, a minus
/// badge to remove, a gallery sheet to add. Home built these first; Library was asked for "the
/// homepage implementation", so they live here rather than being written twice.

/// Drag the body itself to reorder — no 3-bar handle anywhere, per Control Center. Dropping onto a
/// neighbour inserts before it, which is enough ordering for a handful of items.
///
/// ponytail: no live gap under the finger — the layout settles on drop. Ceiling: SwiftUI hands
/// back no drag position here. Upgrade: track each frame in a preference key and reflow mid-drag.
struct ReorderDrag: ViewModifier {
    let id: String
    let active: Bool
    let onDrop: (String) -> Void

    func body(content: Content) -> some View {
        if active {
            content
                .draggable(id)
                .dropDestination(for: String.self) { items, _ in
                    guard let dragged = items.first, dragged != id else { return false }
                    withAnimation(.snappy) { onDrop(dragged) }
                    return true
                }
        } else {
            content
        }
    }
}

/// Delete affordance: filled badge on the leading corner, Control Center's shape. Badge only — a
/// horizontal swipe fights drag-to-reorder on a tile, and a row that swipes one way for delete and
/// drags the other is worse.
struct LayoutMinusBadge: View {
    let remove: () -> Void

    var body: some View {
        Button(action: remove) {
            Image(systemName: "minus")
                .font(.caption2.weight(.bold)).foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .glassEffect(.regular.interactive(), in: Circle())
        }
        .buttonStyle(.plain)
    }
}

/// One thing a surface can show, as the gallery lists it.
struct LayoutEntry: Identifiable, Hashable {
    let id: String
    let name: String
    /// Small caption under the name — Home says which zone, Library says what kind of row it is.
    let caption: String
    let icon: String
}

/// The add gallery: search on top, 2-up grid, name + caption under each preview. Replaces both
/// surfaces' old lists of "Add <name>" buttons.
///
/// ponytail: previews are the entry's icon, not a live render. Ceiling — a live preview means
/// building every candidate's real data just to draw the picker. Upgrade: render the real tile at
/// 1x1 once that data is cheap to ask for twice.
struct LayoutGallerySheet: View {
    let title: String
    let entries: [LayoutEntry]
    let placed: Set<String>
    let onAdd: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

    private var matches: [LayoutEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return entries.filter {
            !placed.contains($0.id) && (q.isEmpty || $0.name.lowercased().contains(q))
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if matches.isEmpty {
                    ContentUnavailableView("Nothing to add", systemImage: "square.grid.2x2",
                                           description: Text("Everything is already here."))
                        .padding(.top, 40)
                } else {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(matches) { entry in
                            Button { onAdd(entry.id) } label: { preview(entry) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding()
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.buttonStyle(.glass)
                }
            }
        }
        .themedTint()
    }

    private func preview(_ entry: LayoutEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.white.opacity(0.08))
                .aspectRatio(1, contentMode: .fit)
                .overlay { Image(systemName: entry.icon).font(.largeTitle).foregroundStyle(.tint) }
            Text(entry.name).font(.footnote.weight(.semibold)).lineLimit(1)
            Text(entry.caption).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// The Library root's own layout (#14), stored in `Pref.librarySections`. Same shape as
/// `HomeLayout`, minus the grid — a Library row has one size.
enum LibraryLayout {
    /// Everything the Library root can show. Collections first, then the two structural rows.
    static var catalog: [LayoutEntry] {
        CollectionKind.allCases.map {
            LayoutEntry(id: $0.id, name: $0.rawValue, caption: "Collection", icon: $0.icon)
        } + [
            LayoutEntry(id: "folders", name: "Folders", caption: "Section", icon: "folder"),
            LayoutEntry(id: "recentAdded", name: "Recently Added", caption: "Section",
                        icon: "clock"),
        ]
    }

    static func name(_ id: String) -> String { catalog.first { $0.id == id }?.name ?? id }

    /// Ordered ids, junk removed. An id the catalogue doesn't know would render nothing and be
    /// impossible to delete, so it drops here.
    static func parse(_ csv: String) -> [String] {
        var out: [String] = []
        let known = Set(catalog.map(\.id))
        for raw in csv.split(separator: ",") {
            let id = raw.trimmingCharacters(in: .whitespaces)
            if known.contains(id), !out.contains(id) { out.append(id) }
        }
        return out
    }

    static func csv(_ ids: [String]) -> String { ids.joined(separator: ",") }
}
