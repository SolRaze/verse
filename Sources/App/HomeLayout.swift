import SwiftUI

/// Which zone a Home item lives in (#2/#3). Tiles pack into the 4-column grid and can be resized;
/// shelves are full-width rows and are only ever reordered. A drag never crosses zones — that is
/// the whole point of splitting them, since a list-shaped shelf has no sensible 1x1 form.
enum HomeZone: String {
    case tile, shelf
}

/// Navigation value for the fetch review, pushed by the status tile (#5). `NavigationLink(value:)`
/// matches destinations on the static type, so the review needs a type of its own.
struct FetchReviewRef: Hashable {}

/// One placed tile: a catalogue id plus its span in grid cells.
struct HomeTile: Identifiable, Hashable {
    var id: String
    var cols: Int = 1
    var rows: Int = 1
}

/// Everything Home can show, and where it belongs. Zone is a property of the item, not a user
/// choice — Now Playing has a real 1x1 form, "Recently Added" does not.
enum HomeCatalog {
    static let items: [(id: String, name: String, zone: HomeZone, icon: String)] = [
        ("now", "Now Playing", .tile, "play.circle.fill"),
        ("albums", "Most Played Albums", .tile, "square.stack.fill"),
        ("fetch", "Fetch Status", .tile, "checklist"),
        ("playlists", "Playlists", .shelf, "music.note.list"),
        ("tracks", "Most Played", .shelf, "chart.bar.fill"),
        ("recentAdded", "Recently Added", .shelf, "clock.fill"),
        ("recentPlayed", "Recently Played", .shelf, "arrow.counterclockwise"),
    ]

    /// Sizes an item may take. Most take all three; an item whose face needs room says so here,
    /// the way the Create canvas lets a feature declare its own list.
    /// - `now` has nowhere to put a title at 1x1.
    /// - `albums` draws square covers, which a wide-and-short tile would crush.
    static func presets(for id: String) -> [(cols: Int, rows: Int)] {
        switch id {
        case "now": [(2, 1), (2, 2)]
        case "albums": [(1, 1), (2, 2)]
        default: HomeLayout.presets
        }
    }

    /// The same catalogue as the gallery sheet wants it, captioned with the zone it lands in.
    static var entries: [LayoutEntry] {
        items.map {
            LayoutEntry(id: $0.id, name: $0.name,
                        caption: $0.zone == .tile ? "Tile" : "Shelf", icon: $0.icon)
        }
    }

    static func name(_ id: String) -> String { items.first { $0.id == id }?.name ?? id }
    static func icon(_ id: String) -> String { items.first { $0.id == id }?.icon ?? "square.grid.2x2" }
    static func zone(_ id: String) -> HomeZone? { items.first { $0.id == id }?.zone }
}

/// Layout maths for Home, kept out of the views so it can be tested: parsing the two prefs,
/// reordering, snapping a resize to a preset, and packing tiles into rows.
enum HomeLayout {
    /// The only sizes a tile takes, as (cols, rows) — same vocabulary the Create canvas uses, where
    /// "1x2" means one row by two columns (the pill), not a narrow tall tile.
    static let presets: [(cols: Int, rows: Int)] = [(1, 1), (2, 1), (2, 2)]
    static let columns = 4

    static let defaultTilesCSV = "now:2:2"
    static let defaultShelvesCSV = "playlists,tracks"

    // MARK: prefs

    /// "id:cols:rows" pairs → tiles. Unknown ids, repeats and out-of-range spans drop out, so a
    /// hand-edited pref can't wedge the grid.
    static func parseTiles(_ csv: String) -> [HomeTile] {
        var out: [HomeTile] = []
        for entry in csv.split(separator: ",") {
            let parts = entry.split(separator: ":")
            guard let id = parts.first.map(String.init),
                  HomeCatalog.zone(id) == .tile,
                  !out.contains(where: { $0.id == id }) else { continue }
            let cols = parts.count > 1 ? Int(parts[1]) ?? 1 : 1
            let rows = parts.count > 2 ? Int(parts[2]) ?? 1 : 1
            let snapped = snap(cols: cols, rows: rows, for: id)
            out.append(HomeTile(id: id, cols: snapped.cols, rows: snapped.rows))
        }
        return out
    }

    static func tilesCSV(_ tiles: [HomeTile]) -> String {
        tiles.map { "\($0.id):\($0.cols):\($0.rows)" }.joined(separator: ",")
    }

    /// Shelf ids, in order. Tile ids that stray into this pref are dropped — `migrate` is what
    /// moves them across, and a duplicate in both zones would render twice.
    static func parseShelves(_ csv: String) -> [String] {
        var out: [String] = []
        for raw in csv.split(separator: ",") {
            let id = raw.trimmingCharacters(in: .whitespaces)
            if HomeCatalog.zone(id) == .shelf, !out.contains(id) { out.append(id) }
        }
        return out
    }

    /// One-time move from the old single-list layout: whatever tile-capable ids were in
    /// `home.sections` become tiles, in the order they sat, and the sections pref keeps the rest.
    /// Runs when the tiles pref has never been written; after that both prefs stand on their own.
    static func migrate(sectionsCSV: String, tilesCSV: String?) -> (tiles: String, shelves: String) {
        guard tilesCSV == nil else {
            return (tilesCSV!, parseShelves(sectionsCSV).joined(separator: ","))
        }
        let ids = sectionsCSV.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let carried = ids.filter { HomeCatalog.zone($0) == .tile }
        let tiles = carried.isEmpty
            ? defaultTilesCSV
            : self.tilesCSV(carried.map { HomeTile(id: $0, cols: 2, rows: 2) })
        return (tiles, parseShelves(sectionsCSV).joined(separator: ","))
    }

    // MARK: mutations

    /// Move `id` so it sits where `target` was — the drop-on-a-neighbour reorder both zones use.
    static func move<T: Equatable>(_ list: [T], _ id: T, before target: T) -> [T] {
        guard id != target, let from = list.firstIndex(of: id) else { return list }
        var out = list
        out.remove(at: from)
        guard let to = out.firstIndex(of: target) else { return list }
        out.insert(id, at: to)
        return out
    }

    /// Nearest preset by grid distance, so a small drag off a 1x1 lands on the pill instead of
    /// somewhere between two sizes. Snaps within the item's own preset list.
    static func snap(cols: Int, rows: Int, for id: String) -> (cols: Int, rows: Int) {
        HomeCatalog.presets(for: id).min {
            let da = ($0.cols - cols) * ($0.cols - cols) + ($0.rows - rows) * ($0.rows - rows)
            let db = ($1.cols - cols) * ($1.cols - cols) + ($1.rows - rows) * ($1.rows - rows)
            return da < db
        } ?? (1, 1)
    }

    /// Greedy row packing, same rule as the Create canvas: tiles fill left to right and wrap when
    /// the row would exceed 4 columns.
    ///
    /// ponytail: a 2x2 leaves the cell below it empty rather than letting a 1x1 flow underneath.
    /// Ceiling — no true bin packing, so a tall tile can waste a cell. Upgrade: track per-column
    /// occupancy and place into the first free slot that fits.
    static func pack(_ tiles: [HomeTile]) -> [[HomeTile]] {
        var out: [[HomeTile]] = []
        var row: [HomeTile] = []
        var used = 0
        for tile in tiles {
            let cols = min(max(tile.cols, 1), columns)
            if used + cols > columns { out.append(row); row = []; used = 0 }
            row.append(tile)
            used += cols
        }
        if !row.isEmpty { out.append(row) }
        return out
    }
}
