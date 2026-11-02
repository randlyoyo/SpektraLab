//  Panel.swift — the bottom panel: 胶片 / 相纸 / 调整, and the select-mode bar.

import SwiftUI

enum Pane: String, CaseIterable { case film = "胶片", paper = "相纸", adjust = "调整", crop = "裁剪" }

enum FilmGroup: String, CaseIterable {
    case all = "全部", negative = "负片", positive = "反转片", cine = "电影卷"

    func contains(_ s: Stock) -> Bool {
        switch self {
        case .all: true
        case .negative: !s.isPositive && !s.isCine
        case .positive: s.isPositive
        case .cine: s.isCine
        }
    }
}

struct PanelView: View {
    @Environment(Library.self) private var lib
    @Binding var syncing: Bool
    @State private var group = FilmGroup.all
    @State private var collaging = false

    private var s: Settings { lib.current?.settings ?? Settings() }

    var body: some View {
        @Bindable var lib = lib
        VStack(spacing: 0) {
            if lib.selecting { selectBar }
            Picker("", selection: $lib.pane) {
                ForEach(Pane.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)

            Group {
                switch lib.pane {
                case .film: filmPane
                case .paper: paperPane
                case .adjust: adjustPane
                case .crop: cropPane
                }
            }
            .frame(height: 186)
            .disabled(lib.current == nil)
            .opacity(lib.current == nil ? 0.4 : 1)
        }
        .background(Color(.secondarySystemBackground), in: UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20))
        .background(Color(.secondarySystemBackground).ignoresSafeArea(edges: .bottom).padding(.top, 20))
        .fullScreenCover(isPresented: $collaging) { CollageView(photos: lib.targets) }
    }

    @ViewBuilder private var cropPane: some View {
        if let p = lib.current {
            let size = lib.currentPrint?.size ?? CGSize(width: 3, height: 2)
            CropPane(crop: Binding(get: { p.crop }, set: { p.crop = $0 }), aspect: size.width / size.height)
        }
    }

    private var selectBar: some View {
        let n = lib.selected.count + 1
        return HStack {
            Text("已选 \(n) 张").font(.footnote).foregroundStyle(.secondary)
            Spacer()
            Button("同步") { syncing = true }.disabled(lib.selected.isEmpty)
            Button("拼图") { collaging = true }
                .disabled(n < 2 || n > 9 || lib.busy)
                .padding(.leading, 12)
            Button("导出 \(n) 张") { Task { await lib.export(lib.targets) } }
                .disabled(lib.busy)
                .padding(.leading, 12)
        }
        .padding(.horizontal, 16).padding(.top, 10)
    }

    private var filmPane: some View {
        VStack(spacing: 10) {
            Picker("", selection: $group) {
                ForEach(FilmGroup.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .padding(.horizontal, 16)
            cards(Stock.films.filter(group.contains), chosen: s.film) { stock in
                lib.edit(film: true) { $0.film = stock.id }
            }
        }
    }

    @ViewBuilder private var paperPane: some View {
        if s.isPositive {
            Text("反转片冲出来就是正像，直接扫描，不经过相纸。\n换一卷负片就可以选相纸。")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).lineSpacing(4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            cards(Stock.papers, chosen: s.paper) { stock in
                lib.edit(film: false) { $0.paper = stock.id }
            }
            .padding(.top, 6)
        }
    }

    private func cards(_ stocks: [Stock], chosen: String, _ choose: @escaping (Stock) -> Void) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 10) {
                ForEach(stocks) { stock in
                    StockCard(stock: stock, selected: stock.id == chosen) { choose(stock) }
                }
            }
            .padding(.horizontal, 14)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var adjustPane: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                HStack {
                    Text("曝光")
                    Spacer()
                    Text(String(format: "%+.1f EV", s.exposure)).monospacedDigit().foregroundStyle(.secondary)
                    if s.exposure != 0 {
                        Button { lib.edit(film: true) { $0.exposure = 0 } } label: {
                            Image(systemName: "arrow.counterclockwise").font(.footnote)
                        }
                        .padding(.leading, 6)
                    }
                }
                Slider(value: Binding(get: { s.exposure }, set: { v in lib.preview { $0.exposure = v } }),
                       in: -3...3, step: 0.1) { editing in
                    // Moves without printing; prints on release.
                    if !editing { lib.edit(film: true) { _ in } }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider().padding(.leading, 16)
            Toggle("颗粒", isOn: Binding(get: { s.grain }, set: { v in lib.edit(film: true) { $0.grain = v } }))
                .padding(.horizontal, 16).frame(height: 46)
            Divider().padding(.leading, 16)
            Toggle("光晕", isOn: Binding(get: { s.halation }, set: { v in lib.edit(film: true) { $0.halation = v } }))
                .padding(.horizontal, 16).frame(height: 46)
        }
        .tint(amber)
        .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// A film box or a paper packet: the cover photo where the Mac app has one,
/// otherwise a card in the brand's colour.
struct StockCard: View {
    let stock: Stock
    let selected: Bool
    let action: () -> Void

    private static let brandColors: [String: Color] = [
        "Kodak": Color(red: 0.91, green: 0.69, blue: 0.04),
        "Fujifilm": Color(red: 0.18, green: 0.56, blue: 0.36),
        "CineStill": Color(red: 0.72, green: 0.20, blue: 0.16),
    ]

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                cover
                    .frame(width: 80, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .padding(2)
                    .overlay(RoundedRectangle(cornerRadius: 11).stroke(selected ? amber : .clear, lineWidth: 2))
                Text(stock.shortName).font(.caption2).lineLimit(1)
                    .foregroundStyle(selected ? amber : .primary)
                    .padding(.top, 3)
                Text(stock.brand).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .frame(width: 84, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var cover: some View {
        if let name = stock.cover,
           let path = Bundle.main.path(forResource: name, ofType: nil, inDirectory: "FilmCovers"),
           let image = UIImage(contentsOfFile: path) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            let paper = !stock.isFilm
            let base = paper ? Color(red: 0.93, green: 0.90, blue: 0.85) : Self.brandColors[stock.brand] ?? .gray
            let ink: Color = paper || stock.brand == "Kodak" ? .black.opacity(0.85) : .white
            VStack(alignment: .leading) {
                Text(stock.brand.uppercased()).font(.system(size: 8)).kerning(1.2).foregroundStyle(ink.opacity(0.7))
                Spacer()
                Text(stock.shortName).font(.system(size: 12, weight: .bold)).lineLimit(3).foregroundStyle(ink)
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [base, base.mix(with: .black, by: paper ? 0.12 : 0.35)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing))
        }
    }
}
