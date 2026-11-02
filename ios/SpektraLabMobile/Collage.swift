//  Collage.swift — several photos as one picture, each with its own film and crop.

import Photos
import SwiftUI

struct CollageTemplate {
    let name: String
    let cells: [CGRect] // normalised, one per photo, in order

    /// Layouts for `n` photos (2…9), the plainest first.
    static func all(_ n: Int) -> [CollageTemplate] {
        let full = CGRect(x: 0, y: 0, width: 1, height: 1)
        func cols(_ k: Int, _ a: CGRect = full) -> [CGRect] {
            (0..<k).map { CGRect(x: a.minX + a.width * Double($0) / Double(k), y: a.minY, width: a.width / Double(k), height: a.height) }
        }
        func rows(_ k: Int, _ a: CGRect = full) -> [CGRect] {
            (0..<k).map { CGRect(x: a.minX, y: a.minY + a.height * Double($0) / Double(k), width: a.width, height: a.height / Double(k)) }
        }
        func grid(_ k: Int, _ a: CGRect = full) -> [CGRect] {
            let c = Int(Double(k).squareRoot().rounded(.up)), r = (k + c - 1) / c
            return (0..<k).map { i in
                // The last row's cells widen to fill it.
                let row = i / c, inRow = row == r - 1 ? k - c * (r - 1) : c
                return CGRect(x: a.minX + a.width * Double(i % c) / Double(inRow), y: a.minY + a.height * Double(row) / Double(r),
                              width: a.width / Double(inRow), height: a.height / Double(r))
            }
        }
        let t = { (name: String, cells: [CGRect]) in CollageTemplate(name: name, cells: cells) }
        switch n {
        case 2: return [t("左右", cols(2)), t("上下", rows(2))]
        case 3: return [t("三列", cols(3)), t("三行", rows(3)),
                        t("左大", [CGRect(x: 0, y: 0, width: 0.5, height: 1)] + rows(2, CGRect(x: 0.5, y: 0, width: 0.5, height: 1))),
                        t("上大", [CGRect(x: 0, y: 0, width: 1, height: 0.5)] + cols(2, CGRect(x: 0, y: 0.5, width: 1, height: 0.5)))]
        case 4: return [t("四宫格", grid(4)),
                        t("左大", [CGRect(x: 0, y: 0, width: 2.0 / 3, height: 1)] + rows(3, CGRect(x: 2.0 / 3, y: 0, width: 1.0 / 3, height: 1))),
                        t("上大", [CGRect(x: 0, y: 0, width: 1, height: 2.0 / 3)] + cols(3, CGRect(x: 0, y: 2.0 / 3, width: 1, height: 1.0 / 3))),
                        t("四列", cols(4))]
        default: return [t("网格", grid(n)),
                         t("上大", [CGRect(x: 0, y: 0, width: 1, height: 0.5)] + grid(n - 1, CGRect(x: 0, y: 0.5, width: 1, height: 0.5)))]
        }
    }
}

/// The look of a collage. `spacing` and `radius` are in points of a 360-point
/// wide frame and scale with the output.
struct CollageStyle {
    var template = 0
    var spacing = 8.0
    var radius = 0.0
    var background = Color.white
    var ratio = 1.0

    static let backgrounds: [Color] = [.white, Color(red: 0.95, green: 0.92, blue: 0.87), .black, Color(white: 0.17)]
    static let ratios: [(String, Double)] = [("1:1", 1), ("4:5", 0.8), ("3:4", 0.75), ("9:16", 9.0 / 16), ("16:9", 16.0 / 9)]

    /// Each cell in a frame `width` wide, spacing applied.
    func frames(_ cells: [CGRect], width: Double) -> [CGRect] {
        let height = width / ratio, k = width / 360, gap = spacing * k
        let inner = CGRect(x: gap / 2, y: gap / 2, width: width - gap, height: height - gap)
        return cells.map {
            CGRect(x: inner.minX + $0.minX * inner.width, y: inner.minY + $0.minY * inner.height,
                   width: $0.width * inner.width, height: $0.height * inner.height).insetBy(dx: gap / 2, dy: gap / 2)
        }
    }
}

struct CollageView: View {
    let photos: [Photo]
    @Environment(Library.self) private var lib
    @Environment(\.dismiss) private var dismiss
    @State private var order: [Photo] = []
    @State private var previews: [String: UIImage] = [:] // id → cropped print, for the screen
    @State private var style = CollageStyle()
    @State private var picked: Int?
    @State private var tab = 0
    @State private var exporting = false

    private var templates: [CollageTemplate] { CollageTemplate.all(order.count) }
    private var cells: [CGRect] { templates[min(style.template, templates.count - 1)].cells }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                GeometryReader { geo in
                    let width = min(geo.size.width, geo.size.height * style.ratio)
                    ZStack(alignment: .topLeading) {
                        style.background
                        ForEach(Array(zip(order.indices, style.frames(cells, width: width))), id: \.0) { i, frame in
                            cell(i, frame: frame, scale: width / 360)
                        }
                    }
                    .frame(width: width, height: width / style.ratio)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
                }
                .padding(20)
                Text(picked == nil ? "点一格，再点另一格可以交换位置" : "再点一格和它交换")
                    .font(.caption).foregroundStyle(.secondary).padding(.bottom, 8)
                controls
            }
            .background(.black)
            .navigationTitle("拼图")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if exporting { ProgressView() } else { Button("导出") { Task { await export() } }.fontWeight(.semibold) }
                }
            }
            .disabled(exporting)
        }
        .task {
            order = photos
            await loadPreviews()
        }
    }

    private func cell(_ i: Int, frame: CGRect, scale: Double) -> some View {
        let p = order[i]
        let shape = RoundedRectangle(cornerRadius: style.radius * scale)
        return Image(uiImage: previews[p.id] ?? p.thumb ?? UIImage())
            .resizable().scaledToFill()
            .frame(width: frame.width, height: frame.height)
            .clipShape(shape)
            .overlay { if picked == i { shape.stroke(amber, lineWidth: 3) } }
            .offset(x: frame.minX, y: frame.minY)
            .onTapGesture {
                if let j = picked { order.swapAt(i, j); picked = nil } else { picked = i }
            }
    }

    private var controls: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("布局").tag(0); Text("边框").tag(1); Text("比例").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(16)
            Group {
                switch tab {
                case 0: layouts
                case 1: border
                default: ratios
                }
            }
            .frame(height: 110)
        }
        .background(Color(.secondarySystemBackground), in: UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20))
        .background(Color(.secondarySystemBackground).ignoresSafeArea(edges: .bottom).padding(.top, 20))
    }

    private var layouts: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(templates.indices, id: \.self) { i in
                    Button { style.template = i } label: {
                        VStack(spacing: 4) {
                            Canvas { ctx, size in
                                for c in templates[i].cells {
                                    let r = CGRect(x: c.minX * size.width, y: c.minY * size.height,
                                                   width: c.width * size.width, height: c.height * size.height).insetBy(dx: 1.5, dy: 1.5)
                                    ctx.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(.secondary))
                                }
                            }
                            .frame(width: 56, height: 56)
                            .padding(4)
                            .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(style.template == i ? amber : .clear, lineWidth: 2))
                            Text(templates[i].name).font(.caption2).foregroundStyle(style.template == i ? amber : .primary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var border: some View {
        VStack(spacing: 6) {
            HStack { Text("间距").frame(width: 40, alignment: .leading); Slider(value: $style.spacing, in: 0...24) }
            HStack { Text("圆角").frame(width: 40, alignment: .leading); Slider(value: $style.radius, in: 0...24) }
            HStack {
                Text("底色").frame(width: 40, alignment: .leading)
                ForEach(CollageStyle.backgrounds, id: \.self) { c in
                    Button { style.background = c } label: {
                        Circle().fill(c).frame(width: 28, height: 28)
                            .overlay(Circle().stroke(style.background == c ? amber : Color(.separator), lineWidth: style.background == c ? 2.5 : 1))
                    }
                    .padding(.leading, 10)
                }
                Spacer()
            }
        }
        .tint(amber)
        .padding(.horizontal, 16)
    }

    private var ratios: some View {
        HStack(spacing: 18) {
            ForEach(CollageStyle.ratios, id: \.0) { name, value in
                Button { style.ratio = value } label: {
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(style.ratio == value ? amber : .secondary, lineWidth: 2)
                            .aspectRatio(value, contentMode: .fit)
                            .frame(width: 44, height: 44)
                        Text(name).font(.caption).foregroundStyle(style.ratio == value ? amber : .primary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Each photo printed with its own settings and cropped, at preview size.
    private func loadPreviews() async {
        for p in order {
            if let image = try? await Engine.shared.croppedPrint(p.id, p.settings, p.crop, longEdge: 1200) {
                previews[p.id] = UIImage(cgImage: image)
            }
        }
    }

    /// Full-size prints into a 3600-point-wide collage, saved to Photos.
    private func export() async {
        exporting = true
        defer { exporting = false }
        let width = 3600.0, height = (width / style.ratio).rounded()
        let space = CGColorSpace(name: CGColorSpace.displayP3)!
        guard let ctx = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        // Top-left origin, as the frames are.
        ctx.translateBy(x: 0, y: height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.setFillColor(UIColor(style.background).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (p, frame) in zip(order, style.frames(cells, width: width)) {
            guard let image = try? await Engine.shared.croppedPrint(p.id, p.settings, p.crop, longEdge: nil) else { continue }
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: frame, cornerWidth: style.radius * width / 360,
                               cornerHeight: style.radius * width / 360, transform: nil))
            ctx.clip()
            // Fill the cell, centred; drawn flipped back so the photo is upright.
            let s = max(frame.width / Double(image.width), frame.height / Double(image.height))
            let w = Double(image.width) * s, h = Double(image.height) * s
            let r = CGRect(x: frame.midX - w / 2, y: frame.midY - h / 2, width: w, height: h)
            ctx.translateBy(x: 0, y: r.maxY + r.minY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(image, in: r)
            ctx.restoreGState()
        }
        guard let collage = ctx.makeImage(), let data = UIImage(cgImage: collage).heicData() else { return }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            }
            lib.say("已保存拼图")
            dismiss()
        } catch {
            lib.say(error.localizedDescription)
        }
        // The engine now holds the last collage photo; reopen the current one.
        if let current = lib.current { lib.request(current) }
    }
}
