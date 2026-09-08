import SwiftUI

/// Slot maths for the reaction strip (#9/#18), kept out of the views so it can be tested: six
/// slots, no more, no duplicates, and a short Recently Used list behind the browser.
///
/// Six is the hard cap the ask names. Anything that would push past it replaces a slot instead of
/// growing the strip, which is why every write goes through `replacing(_:at:with:)`.
enum ReactionSlots {
    static let max = 6
    static let recentsCap = 12
    static let defaults = ["heart", "star", "flame", "bolt", "crown", "face.smiling"]
    static var defaultCSV: String { defaults.joined(separator: ",") }

    /// Stored CSV → exactly six glyphs. Blanks and repeats drop out, then the defaults top it up,
    /// so a hand-edited or half-written pref can never leave the strip short.
    static func parse(_ csv: String) -> [String] {
        var out: [String] = []
        for raw in csv.split(separator: ",") {
            let glyph = raw.trimmingCharacters(in: .whitespaces)
            if !glyph.isEmpty, !out.contains(glyph) { out.append(glyph) }
        }
        for fallback in defaults where out.count < max {
            if !out.contains(fallback) { out.append(fallback) }
        }
        return Array(out.prefix(max))
    }

    static func csv(_ glyphs: [String]) -> String { glyphs.joined(separator: ",") }

    /// Put `glyph` in slot `index`. Picking one that already sits elsewhere in the strip would
    /// leave a duplicate, so the two slots swap instead.
    static func replacing(_ glyphs: [String], at index: Int, with glyph: String) -> [String] {
        guard glyphs.indices.contains(index) else { return glyphs }
        var out = glyphs
        if let existing = out.firstIndex(of: glyph), existing != index {
            out[existing] = out[index]
        }
        out[index] = glyph
        return out
    }

    /// Newest first, no repeats, capped — the browser's Recently Used row.
    static func pushRecent(_ glyph: String, into csv: String) -> String {
        var out = csv.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != glyph }
        out.insert(glyph, at: 0)
        return out.prefix(recentsCap).joined(separator: ",")
    }

    static func recents(_ csv: String) -> [String] {
        csv.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Icons matching a typed query. Symbol names are dotted, so "thumbs up" has to match
    /// `hand.thumbsup` — the dots become spaces before comparing.
    static func search(_ query: String, in library: [String] = Pref.likeGlyphs) -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return library }
        return library.filter { $0.replacingOccurrences(of: ".", with: " ").contains(q) }
    }
}

/// The inline strip (#9): six replaceable slots plus a `+`, floated above the favourite button.
/// Was a popover; a popover can't sit flush over the player art, and the ask wants it inline.
struct ReactionStrip: View {
    @Binding var selected: String
    @AppStorage(Pref.likeGlyphSlots) private var slotsCSV = ReactionSlots.defaultCSV
    let onPick: () -> Void
    let onBrowse: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ReactionSlots.parse(slotsCSV), id: \.self) { glyph in
                Button {
                    selected = glyph
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onPick()
                } label: { ReactionGlyph(glyph: glyph, chosen: glyph == selected) }
                .buttonStyle(.plain)
            }
            Button(action: onBrowse) {
                Image(systemName: "plus")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .glassEffect(.regular, in: Capsule())
    }
}

/// One glyph in the strip. The glass capsule IS the selection indicator (#9 — a capsule now, the
/// old strip used a circle), so it can't be applied unconditionally.
private struct ReactionGlyph: View {
    let glyph: String
    let chosen: Bool

    var body: some View {
        let icon = Image(systemName: chosen ? "\(glyph).fill" : glyph)
            .font(.title3)
            .foregroundStyle(chosen ? AnyShapeStyle(.tint) : AnyShapeStyle(.white.opacity(0.7)))
            .frame(width: 38, height: 38)
        if chosen {
            icon.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            icon
        }
    }
}

/// The icon browser (#18), raised by the strip's `+`. Opens at 60% height; the arrow pill takes it
/// fullscreen and flips to point down. Customize turns the same sheet into slot-editing mode.
///
/// `Reference/reaction/` (Instagram) puts search at the top, "Customise" as plain text top-right
/// and expands by dragging the grabber — the plan wins on all three, so the chrome here is glass
/// pills with search underneath them.
struct ReactionBrowser: View {
    @Binding var selected: String
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Pref.likeGlyphSlots) private var slotsCSV = ReactionSlots.defaultCSV
    @AppStorage(Pref.likeGlyphRecents) private var recentsCSV = ""
    @State private var query = ""
    @State private var customizing = false
    /// Which slot Customize is pointing at. Only meaningful while `customizing`.
    @State private var slotIndex = 0
    @State private var detent: PresentationDetent = .fraction(0.6)

    private var slots: [String] { ReactionSlots.parse(slotsCSV) }
    private var fullscreen: Bool { detent == .large }

    private let columns = [GridItem(.adaptive(minimum: 56), spacing: 12)]

    var body: some View {
        VStack(spacing: 12) {
            header
            if customizing { customizeBar }
            searchField
            ScrollView { results }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .presentationDetents([.fraction(0.6), .large], selection: $detent)
        .presentationDragIndicator(.hidden)
        .preferredColorScheme(.dark)
        .themedTint()
    }

    // MARK: chrome

    @ViewBuilder private var header: some View {
        if customizing {
            // Plain text, no button backgrounds — this row matches the reference exactly.
            HStack {
                Button("Reset") { reset() }
                Spacer()
                Text("Customize Reactions").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .buttonStyle(.plain)
            .font(.subheadline)
            .foregroundStyle(.white)
        } else {
            HStack {
                Button("Customize") { startCustomizing() }.buttonStyle(.glass)
                Spacer()
                Button {
                    withAnimation(.snappy) { detent = fullscreen ? .fraction(0.6) : .large }
                } label: {
                    Image(systemName: fullscreen ? "chevron.down" : "chevron.up")
                }
                .buttonStyle(.glass)
            }
            .font(.subheadline)
        }
    }

    /// The strip recalled to the top of the overlay while customizing — six slots, no `+`, because
    /// `+` means "add" and showing it mid-customize breaks the illusion.
    private var customizeBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 2) {
                ForEach(Array(slots.enumerated()), id: \.offset) { index, glyph in
                    Button { slotIndex = index } label: {
                        Image(systemName: glyph)
                            .font(.title3)
                            .foregroundStyle(index == slotIndex ? .white : .white.opacity(0.35))
                            .frame(width: 38, height: 38)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .glassEffect(.regular, in: Capsule())
            Text("tap a reaction, then choose an icon to replace it.")
                .font(.caption2).foregroundStyle(.white.opacity(0.5))
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.5))
            TextField("Search icons", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
            }
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.white.opacity(0.08), in: Capsule())
    }

    // MARK: icons

    @ViewBuilder private var results: some View {
        let matches = ReactionSlots.search(query)
        let recents = ReactionSlots.recents(recentsCSV).filter(matches.contains)
        VStack(alignment: .leading, spacing: 14) {
            if query.isEmpty {
                section("Selected", glyphs: [customizing ? slots[safe: slotIndex] ?? selected : selected])
            }
            if !recents.isEmpty { section("Recently Used", glyphs: recents) }
            section(query.isEmpty ? "All Icons" : "Results",
                    glyphs: matches.filter { query.isEmpty ? !recents.contains($0) : true })
        }
        .padding(.bottom, 24)
    }

    private func section(_ title: String, glyphs: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.white.opacity(0.5))
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(glyphs, id: \.self) { glyph in
                    Button { pick(glyph) } label: {
                        Image(systemName: glyph)
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: 52, height: 52)
                            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: actions

    /// Browsing replaces whichever slot the favourite button is currently wearing; customizing
    /// replaces the slot the user tapped. Either way the strip stays six long.
    private func pick(_ glyph: String) {
        let index = customizing ? slotIndex : (slots.firstIndex(of: selected) ?? slots.count - 1)
        slotsCSV = ReactionSlots.csv(ReactionSlots.replacing(slots, at: index, with: glyph))
        recentsCSV = ReactionSlots.pushRecent(glyph, into: recentsCSV)
        selected = glyph
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if !customizing { dismiss() }
    }

    /// Customize from fullscreen minimizes back to 60% first, as asked — the pill it recalls is
    /// meant to sit near the top of a half sheet, not float in the middle of a full one.
    private func startCustomizing() {
        if fullscreen { detent = .fraction(0.6) }
        slotIndex = slots.firstIndex(of: selected) ?? 0
        withAnimation(.snappy) { customizing = true }
    }

    private func reset() {
        slotsCSV = ReactionSlots.defaultCSV
        slotIndex = min(slotIndex, ReactionSlots.max - 1)
        if !ReactionSlots.defaults.contains(selected) { selected = ReactionSlots.defaults[0] }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
