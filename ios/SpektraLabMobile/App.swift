//  App.swift — pick a photo, choose film and paper, print it, save it.

import Photos
import PhotosUI
import SwiftUI

@main
struct SpektraLabMobileApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

/// The Mac app's `Resources/StockCatalog.json`, shipped as-is (project.yml).
struct Stock: Decodable, Hashable {
    let id: String
    let name: String
    let stage: String
    let monochrome: Bool?

    static let all: [Stock] = {
        struct Wrapper: Decodable { let stocks: [Stock] }
        guard let url = Bundle.main.url(forResource: "StockCatalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let wrapper = try? JSONDecoder().decode(Wrapper.self, from: data) else { return [] }
        // Black and white is behind a feature flag on the Mac too.
        return wrapper.stocks.filter { !($0.monochrome ?? false) }
    }()
    static let films = all.filter { $0.stage == "filming" }
    static let papers = all.filter { $0.stage == "printing" }
}

struct ContentView: View {
    @State private var item: PhotosPickerItem?
    @State private var print: CGImage?
    @State private var status = "Pick a photo"
    @State private var busy = false

    // The Mac app's defaults (Params.swift).
    @State private var film = "kodak_portra_400"
    @State private var paper = "kodak_supra_endura"
    @State private var exposure = 0.0
    @State private var grain = true
    @State private var halation = true

    private var params: [String: Any] {
        ["film_stock": film, "print_stock": paper, "exposure_compensation_ev": exposure,
         "grain_active": grain, "halation_active": halation]
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    Color.black
                    if let print {
                        Image(decorative: print, scale: 1).resizable().scaledToFit()
                    }
                    if busy { ProgressView().tint(.white) }
                }
                Form {
                    Picker("Film", selection: $film) {
                        ForEach(Stock.films, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    .onChange(of: film) { develop(film: true) }
                    Picker("Paper", selection: $paper) {
                        ForEach(Stock.papers, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    .onChange(of: paper) { develop(film: false) }
                    VStack(alignment: .leading) {
                        Text("Exposure \(exposure, specifier: "%+.1f") EV")
                        Slider(value: $exposure, in: -3...3, step: 0.1) { editing in
                            if !editing { develop(film: true) }
                        }
                    }
                    Toggle("Grain", isOn: $grain).onChange(of: grain) { develop(film: true) }
                    Toggle("Halation", isOn: $halation).onChange(of: halation) { develop(film: true) }
                    Text(status).font(.footnote).foregroundStyle(.secondary)
                }
                .disabled(busy)
            }
            .navigationTitle("SpektraLab Mobile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    PhotosPicker(selection: $item, matching: .images) { Image(systemName: "photo") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save", action: save).disabled(print == nil || busy)
                }
            }
            .onChange(of: item) { open() }
        }
    }

    private func run(_ work: @escaping () async throws -> String) {
        busy = true
        Task {
            do { status = try await work() } catch { status = error.localizedDescription }
            busy = false
        }
    }

    private func open() {
        guard let item else { return }
        let params = params
        run {
            guard let data = try await item.loadTransferable(type: Data.self) else { return "Could not read the photo" }
            try await Engine.shared.open(data, params: params)
            let (image, ms) = try await Engine.shared.render([:], film: true)
            print = image
            return "\(image.width)×\(image.height) · \(Int(ms)) ms"
        }
    }

    private func develop(film: Bool) {
        guard print != nil else { return }
        let params = params
        run {
            let (image, ms) = try await Engine.shared.render(params, film: film)
            print = image
            return "\(image.width)×\(image.height) · \(Int(ms)) ms"
        }
    }

    private func save() {
        guard let print else { return }
        run {
            let data = try await Engine.shared.heic(print)
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }
            return "Saved to Photos"
        }
    }
}
