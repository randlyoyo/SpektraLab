//  Model.swift — films, settings, the photo library and what editing does to it.
//  Behaviour follows the Flutter design prototype in mobile/.

import Foundation
import Observation
import PhotosUI
import SwiftUI

/// The Mac app's `Resources/StockCatalog.json`, shipped as-is (project.yml).
struct Stock: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let stage: String
    let use: String
    let type: String?
    let cover: String?
    let monochrome: Bool?

    var isFilm: Bool { stage == "filming" }
    var isPositive: Bool { type == "positive" }
    var isCine: Bool { use == "cine" }
    var brand: String { String(name.split(separator: " ").first ?? "") }
    var shortName: String { String(name.dropFirst(brand.count)).trimmingCharacters(in: .whitespaces) }

    static let all: [Stock] = {
        struct Wrapper: Decodable { let stocks: [Stock] }
        guard let url = Bundle.main.url(forResource: "StockCatalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let wrapper = try? JSONDecoder().decode(Wrapper.self, from: data) else { return [] }
        // Black and white is behind a feature flag on the Mac too.
        return wrapper.stocks.filter { !($0.monochrome ?? false) }
    }()
    static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    static let films = all.filter(\.isFilm)
    static let papers = all.filter { !$0.isFilm }
}

/// What can be synced from one photo to others, as the Mac app's clipboard groups.
enum SyncGroup: String, CaseIterable, Identifiable {
    case film = "胶片", paper = "相纸", exposure = "曝光", effects = "颗粒与光晕"
    var id: Self { self }
}

/// One photo's develop settings. The defaults are the Mac app's (Params.swift).
struct Settings: Equatable, Sendable {
    var film = "kodak_portra_400"
    var paper = "kodak_supra_endura"
    var exposure = 0.0
    var grain = true
    var halation = true

    var isPositive: Bool { Stock.byID[film]?.isPositive ?? false }

    /// This, with `groups` taken from `other`.
    func synced(from other: Settings, _ groups: Set<SyncGroup>) -> Settings {
        var s = self
        if groups.contains(.film) { s.film = other.film }
        if groups.contains(.paper) { s.paper = other.paper }
        if groups.contains(.exposure) { s.exposure = other.exposure }
        if groups.contains(.effects) { s.grain = other.grain; s.halation = other.halation }
        return s
    }

    var params: [String: Any] {
        ["film_stock": film,
         "print_stock": paper,
         // A slide film is scanned, not printed (the Mac app's film stage rule).
         "scan_film": isPositive,
         "exposure_compensation_ev": exposure,
         "grain_active": grain,
         "halation_active": halation]
    }
}

@Observable
final class Photo: Identifiable {
    let id: String
    let thumb: UIImage?
    var settings = Settings()
    var status = ""

    init(id: String, thumb: UIImage?) {
        self.id = id
        self.thumb = thumb
    }

    var edited: Bool { settings != Settings() }
}

@Observable @MainActor
final class Library {
    var photos: [Photo] = []
    var currentID: String?
    var picked: [PhotosPickerItem] = []

    var selecting = false
    var selected: Set<String> = [] // besides the current photo, which is always included
    var clipboard: Settings?

    // What the canvas shows: only the current photo's images are kept decoded.
    var currentPrint: UIImage?
    var currentOriginal: UIImage?

    var busy = false
    var exporting: (done: Int, total: Int)?
    var stopExport = false
    var toast: String?

    // Edits made while the engine works are coalesced into one more print.
    private var pending: (photo: Photo, film: Bool)?

    var current: Photo? { photos.first { $0.id == currentID } }

    /// The photos an edit applies to.
    var targets: [Photo] {
        guard let current else { return [] }
        return selecting ? photos.filter { $0 === current || selected.contains($0.id) } : [current]
    }

    // MARK: engine

    func request(_ p: Photo, film: Bool = true) {
        if busy {
            pending = (p, (pending?.film ?? false) || film || pending?.photo !== p)
            return
        }
        busy = true // now, not in the task: a second edit this instant must queue
        Task { await develop(p, film: film) }
    }

    private func develop(_ p: Photo, film: Bool) async {
        busy = true
        do {
            let d = try await Engine.shared.develop(p.id, p.settings, film: film)
            p.status = d.info
            if p.id == currentID {
                currentPrint = d.print
                if let o = d.original { currentOriginal = o }
            }
        } catch {
            p.status = error.localizedDescription
        }
        busy = false
        if let next = pending {
            pending = nil
            await develop(next.photo, film: next.film)
        }
    }

    /// Apply an edit to every target photo, then print the current one.
    func edit(film: Bool, _ change: (inout Settings) -> Void) {
        for p in targets { change(&p.settings) }
        if let current { request(current, film: film) }
    }

    /// Change the targets without printing (a slider mid-drag).
    func preview(_ change: (inout Settings) -> Void) {
        for p in targets { change(&p.settings) }
    }

    // MARK: library

    func importPicked() async {
        let items = picked
        picked = []
        for item in items {
            guard let file = try? await item.loadTransferable(type: PickedFile.self) else { continue }
            photos.append(Photo(id: file.id, thumb: PhotoStore.thumbnail(file.url)))
        }
        if current == nil, let first = photos.first { show(first) }
    }

    func show(_ p: Photo) {
        guard p.id != currentID else { return }
        currentID = p.id
        currentPrint = nil
        currentOriginal = nil
        request(p)
    }

    func tap(_ p: Photo) {
        guard selecting else { return show(p) }
        guard p.id != currentID else { return }
        if selected.contains(p.id) { selected.remove(p.id) } else { selected.insert(p.id) }
    }

    func toggleSelecting() {
        selecting.toggle()
        selected = []
    }

    func selectAll() {
        let others = Set(photos.map(\.id)).subtracting([currentID ?? ""])
        selected = selected == others ? [] : others
    }

    func paste(to p: Photo) {
        guard let clipboard else { return }
        p.settings = clipboard
        if p.id == currentID { request(p) }
        say("已粘贴设置")
    }

    func remove(_ p: Photo) {
        PhotoStore.remove(p.id)
        photos.removeAll { $0 === p }
        selected.remove(p.id)
        if p.id == currentID {
            currentID = nil
            currentPrint = nil
            currentOriginal = nil
            if let first = photos.first { show(first) }
        }
    }

    // MARK: batch

    func sync(_ groups: Set<SyncGroup>) {
        guard let from = current?.settings else { return }
        let to = photos.filter { selected.contains($0.id) }
        for p in to { p.settings = p.settings.synced(from: from, groups) }
        say("已同步到 \(to.count) 张照片，打开时冲印")
    }

    /// Print each photo at full size with its own settings and save it to Photos.
    func export(_ list: [Photo]) async {
        guard !busy else { return say("正在冲印，请稍候") }
        busy = true
        stopExport = false
        exporting = (0, list.count)
        var saved = 0, failed = 0
        for p in list {
            if stopExport { break }
            do {
                _ = try await Engine.shared.develop(p.id, p.settings, film: true, display: false)
                try await Engine.shared.save()
                saved += 1
            } catch {
                failed += 1
            }
            exporting?.done += 1
        }
        exporting = nil
        busy = false
        say("已保存 \(saved) 张" + (failed > 0 ? "，\(failed) 张失败" : ""))
        // The engine now holds the last exported photo; reopen the current one.
        if let current { request(current) }
    }

    func say(_ text: String) {
        toast = text
        Task {
            try? await Task.sleep(for: .seconds(2))
            if toast == text { toast = nil }
        }
    }
}
