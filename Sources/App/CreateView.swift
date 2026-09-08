import SwiftUI

/// A deck on the Create canvas: a feature, sized in a 4-column grid. "Deck" is the pill, not the
/// tab — the tab is Create.
struct CreateTile: Codable, Identifiable, Hashable {
    var id = UUID()
    var feature: String
    var cols: Int = 1   // 1...4 — starts a 1x1 square, widen to make a pill
    var rows: Int = 1   // 1...3
}

/// The features the + menu offers. v1 ships iPod Mode; more slot in here.
enum CreateFeature: String, CaseIterable, Identifiable {
    case ipod = "iPod Mode"
    var id: String { rawValue }
    var icon: String { switch self { case .ipod: "opticaldisc" } }

    /// The sizes this feature's deck may take, as (cols, rows) — nothing in between. Small-icon
    /// features get the three fixed sizes: 1x1 square, 1x2 (one row, two
    /// columns — the pill), 2x2. A feature that needs a bigger canvas declares its own list here
    /// as it lands, rather than everything becoming free-form again.
    var presets: [(cols: Int, rows: Int)] {
        switch self {
        case .ipod: [(1, 1), (2, 1), (2, 2)]
        }
    }

    /// Fallback for a tile whose feature no longer exists in the enum.
    static let defaultPresets: [(cols: Int, rows: Int)] = [(1, 1), (2, 1), (2, 2)]
}

/// Create: a 4-column grid of resizable glass-pill decks. The + menu (top right) adds a feature;
/// hold a deck to enter edit mode, then drag the bottom-right corner grip to step through the
/// feature's preset sizes, or tap the minus on the top-right edge to remove. Layout persists.
struct CreatePage: View {
    @Environment(Coordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Pref.createTiles) private var tilesJSON = ""
    @State private var tiles: [CreateTile] = []
    @State private var showIPod = false
    @State private var showAdd = false
    @State private var editing = false      // #8: resize/remove only in edit mode

    private let gap: CGFloat = 12
    private let pad: CGFloat = 16

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let colW = (geo.size.width - pad * 2 - gap * 3) / 4
                ScrollView {
                    if tiles.isEmpty {
                        ContentUnavailableView(
                            "Nothing added", systemImage: "square.grid.2x2",
                            description: Text("Tap + to add a deck. Hold one to edit — drag its corner grip to resize, tap minus to remove."))
                            .padding(.top, 60)
                    } else {
                        VStack(alignment: .leading, spacing: gap) {
                            ForEach(Array(rows().enumerated()), id: \.offset) { _, row in
                                HStack(spacing: gap) {
                                    ForEach(row) { tile in tileView(tile, colW: colW) }
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                        .padding(pad)
                    }
                }
            }
            .navigationTitle("Create")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if editing {
                        Button("Done") { withAnimation(.snappy) { editing = false } }
                    } else {
                        Button { showAdd = true } label: { Image(systemName: "plus") }
                    }
                }
            }
            .sheet(isPresented: $showAdd) {
                AddWidgetSheet { add($0); showAdd = false }
                    .presentationDetents([.medium, .large])
            }
            .fullScreenCover(isPresented: $showIPod) { IPodView(player: coordinator.player) }
        }
        // Opened by a right-swipe from Home; a left-swipe closes it.
        .gesture(DragGesture(minimumDistance: 30).onEnded { v in
            if v.translation.width < -90, abs(v.translation.height) < 60 { dismiss() }
        })
        .onAppear { tiles = decode() }
    }

    // MARK: layout

    /// Greedy row packing: tiles fill left-to-right, wrapping when a row's columns exceed 4.
    private func rows() -> [[CreateTile]] {
        var out: [[CreateTile]] = []
        var row: [CreateTile] = []
        var used = 0
        for t in tiles {
            let c = min(max(t.cols, 1), 4)
            if used + c > 4 { out.append(row); row = []; used = 0 }
            row.append(t); used += c
        }
        if !row.isEmpty { out.append(row) }
        return out
    }

    /// A cell is `colW` square, so a 1x1 tile is a square and widening it makes a pill.
    private func size(_ tile: CreateTile, colW: CGFloat) -> CGSize {
        let c = CGFloat(min(max(tile.cols, 1), 4)), r = CGFloat(min(max(tile.rows, 1), 3))
        return CGSize(width: colW * c + gap * (c - 1), height: colW * r + gap * (r - 1))
    }

    @ViewBuilder private func tileView(_ tile: CreateTile, colW: CGFloat) -> some View {
        let feature = CreateFeature(rawValue: tile.feature)
        let sz = size(tile, colW: colW)
        // #8: at 1x1 the tile is just its icon; widen/tall and the name text appears.
        let iconOnly = tile.cols == 1 && tile.rows == 1
        WidgetBubble(title: feature?.rawValue ?? tile.feature,
                     icon: feature?.icon, iconOnly: iconOnly, size: sz)
            // Tap launches the feature only when not editing; hold enters edit mode (#8).
            .onTapGesture {
                guard !editing else { return }
                if feature == .ipod { showIPod = true }
            }
            .onLongPressGesture(minimumDuration: 0.4) {
                withAnimation(.snappy) { editing = true }
            }
            // Straddling the top-right edge, not tucked inside it — the offset puts
            // half the badge outside the bubble, iOS-home-screen style.
            .overlay(alignment: .topTrailing) {
                if editing {
                    Button { remove(tile) } label: {
                        Image(systemName: "minus")
                            .font(.caption2.weight(.bold)).foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .glassEffect(.regular.interactive(), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .offset(x: 8, y: -8)
                }
            }
            // On the bottom-right curved corner, where a resize grip is expected.
            .overlay(alignment: .bottomTrailing) {
                if editing {
                    ResizeBumper(colStep: colW + gap, rowStep: colW + gap) { dCols, dRows in
                        resize(tile, dCols: dCols, dRows: dRows)
                    }
                    .offset(x: 5, y: 5)
                }
            }
    }

    // MARK: mutations

    private func add(_ f: CreateFeature) { tiles.append(CreateTile(feature: f.rawValue)); persist() }
    private func remove(_ tile: CreateTile) { tiles.removeAll { $0.id == tile.id }; persist() }

    /// Resize snaps to one of the feature's preset sizes — a deck is never an arbitrary
    /// width/height. The drag's raw target picks the nearest preset by grid distance,
    /// so a small drag right off a 1x1 lands on the pill rather than somewhere between.
    private func resize(_ tile: CreateTile, dCols: Int, dRows: Int) {
        guard let i = tiles.firstIndex(where: { $0.id == tile.id }) else { return }
        let presets = CreateFeature(rawValue: tile.feature)?.presets ?? CreateFeature.defaultPresets
        let wantC = tiles[i].cols + dCols, wantR = tiles[i].rows + dRows
        guard let best = presets.min(by: { a, b in
            let da = (a.cols - wantC) * (a.cols - wantC) + (a.rows - wantR) * (a.rows - wantR)
            let db = (b.cols - wantC) * (b.cols - wantC) + (b.rows - wantR) * (b.rows - wantR)
            return da < db
        }) else { return }
        tiles[i].cols = best.cols
        tiles[i].rows = best.rows
        persist()
    }

    // MARK: persistence

    private func decode() -> [CreateTile] {
        (try? JSONDecoder().decode([CreateTile].self, from: Data(tilesJSON.utf8))) ?? []
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(tiles) {
            tilesJSON = String(decoding: data, as: UTF8.self)
        }
    }
}

/// The deck itself: a glass bubble with a rounded edge. A 1x1 tile is a rounded square showing
/// just the glyph; anything larger uses the two-corner layout — icon in
/// the top-left, description in the bottom-right. Widen it and the corner radius grows to a pill
/// (Control-Center-style shapes).
struct WidgetBubble: View {
    let title: String
    var icon: String? = nil
    var iconOnly: Bool = false      // 1x1 tile → glyph alone, no room for the description (#8)
    let size: CGSize

    var body: some View {
        let radius = size.width > size.height * 1.4
            ? size.height / 2                              // wide → pill
            : min(size.width, size.height) * 0.28          // square-ish → rounded square
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Group {
            if iconOnly {
                Image(systemName: icon ?? "square.grid.2x2")
                    .font(.title2).foregroundStyle(.white)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Image(systemName: icon ?? "square.grid.2x2")
                            .font(.title3).foregroundStyle(.white)
                        Spacer(minLength: 0)
                    }
                    Spacer(minLength: 4)
                    HStack {
                        Spacer(minLength: 0)
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .multilineTextAlignment(.trailing)
                            .lineLimit(2)
                            .minimumScaleFactor(0.7)
                    }
                }
            }
        }
        // Pills curve hard at the ends, so the corner content needs to clear the curve — inset
        // by a share of the radius rather than a flat 10.
        .padding(iconOnly ? 10 : max(10, radius * 0.45))
        .frame(width: size.width, height: size.height)
        .glassEffect(.regular, in: shape)
        .overlay { shape.strokeBorder(.white.opacity(0.18), lineWidth: 1) }
    }
}

/// The + palette: previews of each deck as it will look, tap one onto the canvas.
/// ponytail: tap-to-add — a modal sheet can't be a drop target for the canvas beneath it, so the
/// literal drag-from-sheet isn't possible; the preview + tap is the honest version.
struct AddWidgetSheet: View {
    let onPick: (CreateFeature) -> Void
    @Environment(\.dismiss) private var dismiss

    private let cols = [GridItem(.adaptive(minimum: 150), spacing: 16)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: cols, spacing: 16) {
                    ForEach(CreateFeature.allCases) { f in
                        Button { onPick(f) } label: {
                            // The same bubble the canvas draws, icon top-left / description
                            // bottom-right — the preview has to be the thing it previews.
                            WidgetBubble(title: f.rawValue, icon: f.icon,
                                         size: CGSize(width: 150, height: 150))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .navigationTitle("Add Deck")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.buttonStyle(.glass)
                }
            }
        }
    }
}

/// Corner resize grip: a glass bubble that rides the deck's bottom-right curve (it used
/// to be a capsule halfway up the right edge). Drag reads as whole grid steps, and the caller
/// snaps the result to one of the feature's preset sizes.
/// ponytail: commit-on-release only, no live preview — add one if resizing feels blind.
struct ResizeBumper: View {
    let colStep: CGFloat
    let rowStep: CGFloat
    let onCommit: (Int, Int) -> Void

    var body: some View {
        Image(systemName: "arrow.down.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white.opacity(0.85))
            .frame(width: 22, height: 22)
            .glassEffect(.regular.interactive(), in: Circle())
            .overlay { Circle().strokeBorder(.white.opacity(0.3), lineWidth: 1) }
            .contentShape(Rectangle().inset(by: -12))
            .gesture(DragGesture()
                .onEnded { v in
                    onCommit(Int((v.translation.width / colStep).rounded()),
                             Int((v.translation.height / rowStep).rounded()))
                })
    }
}
