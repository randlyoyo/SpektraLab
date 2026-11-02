//  Crop.swift — post-print geometry: quarter turns, flips, straighten, crop.
//  Like the Mac app, it stays with its photo and is never synced.

import CoreImage
import SwiftUI

struct Crop: Hashable, Sendable {
    var turns = 0 // clockwise quarter turns
    var flipH = false
    var flipV = false
    var straighten = 0.0 // degrees, -45…45, clockwise positive
    var rect = CGRect(x: 0, y: 0, width: 1, height: 1) // normalised, top-left origin, of the straightened image
    var ratio = "free" // a key of `ratios`

    /// Width:height of the result; nil is free, 0 the photo's own.
    static let ratios: [(key: String, label: String, value: Double?)] = [
        ("free", "自由", nil), ("original", "原始", 0), ("1:1", "1:1", 1), ("4:5", "4:5", 4.0 / 5),
        ("3:4", "3:4", 3.0 / 4), ("2:3", "2:3", 2.0 / 3), ("9:16", "9:16", 9.0 / 16),
        ("16:9", "16:9", 16.0 / 9), ("xpan", "65:24", 65.0 / 24),
    ]
    var ratioValue: Double? { Self.ratios.first { $0.key == ratio }?.value }

    /// Width:height of a photo of `aspect` after the quarter turns.
    func turnedAspect(_ aspect: Double) -> Double { turns % 2 == 1 ? 1 / aspect : aspect }

    /// The largest centred rect of result ratio `ratio` in an image of `aspect`.
    static func fit(_ ratio: Double, _ aspect: Double) -> CGRect {
        let w = min(1, ratio / aspect), h = min(1, aspect / ratio)
        return CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }

    /// The rect for the chosen ratio in an image of turned aspect `turned`; free keeps `rect`.
    func rectForRatio(_ turned: Double) -> CGRect {
        guard let r = ratioValue else { return rect }
        return Self.fit(r == 0 ? turned : r, turned)
    }

    /// How much straightening zooms in so that no corner shows.
    static func cover(_ degrees: Double, aspect: Double) -> Double {
        let a = abs(degrees) * .pi / 180
        return max(cos(a) + sin(a) / aspect, cos(a) + sin(a) * aspect)
    }

    /// The geometry applied to `image`; `all: false` stops before the
    /// straighten and the crop (what the crop editor draws under its frame).
    func apply(_ image: CIImage, all: Bool = true) -> CIImage {
        var i = origin(image)
        // Core Image is y-up, so clockwise is a negative angle.
        for _ in 0..<(turns % 4) { i = origin(i.transformed(by: CGAffineTransform(rotationAngle: -.pi / 2))) }
        if flipH { i = origin(i.transformed(by: CGAffineTransform(scaleX: -1, y: 1))) }
        if flipV { i = origin(i.transformed(by: CGAffineTransform(scaleX: 1, y: -1))) }
        guard all else { return i }
        let w = i.extent.width, h = i.extent.height
        if straighten != 0 {
            let s = Self.cover(straighten, aspect: w / h)
            let t = CGAffineTransform(translationX: w / 2, y: h / 2)
                .rotated(by: -straighten * .pi / 180)
                .scaledBy(x: s, y: s)
                .translatedBy(x: -w / 2, y: -h / 2)
            i = i.transformed(by: t).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        }
        let r = CGRect(x: rect.minX * w, y: (1 - rect.maxY) * h, width: rect.width * w, height: rect.height * h)
        return origin(i.cropped(to: r.integral))
    }

    private func origin(_ i: CIImage) -> CIImage {
        i.transformed(by: CGAffineTransform(translationX: -i.extent.minX, y: -i.extent.minY))
    }
}

/// The whole (turned, flipped) photo with the crop frame over it: drag inside
/// to move the frame, drag a corner to resize it, keeping a chosen ratio.
struct CropEditor: View {
    let image: UIImage
    @Binding var crop: Crop
    @State private var start: (rect: CGRect, corner: Int?)? // corner: 0 TL, 1 TR, 2 BR, 3 BL

    var body: some View {
        let aspect = image.size.width / image.size.height
        GeometryReader { geo in
            let size = fitted(aspect, in: geo.size)
            let frame = CGRect(x: crop.rect.minX * size.width, y: crop.rect.minY * size.height,
                               width: crop.rect.width * size.width, height: crop.rect.height * size.height)
            ZStack(alignment: .topLeading) {
                Image(uiImage: image).resizable()
                    .frame(width: size.width, height: size.height)
                    .rotationEffect(.degrees(crop.straighten))
                    .scaleEffect(Crop.cover(crop.straighten, aspect: aspect))
                    .frame(width: size.width, height: size.height)
                    .clipped()
                CropFrame(frame: frame).allowsHitTesting(false)
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag($0, size: size, aspect: aspect, frame: frame) }
                .onEnded { _ in start = nil })
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .padding(24)
    }

    private func fitted(_ aspect: Double, in box: CGSize) -> CGSize {
        box.width / box.height > aspect
            ? CGSize(width: box.height * aspect, height: box.height)
            : CGSize(width: box.width, height: box.width / aspect)
    }

    private func drag(_ v: DragGesture.Value, size: CGSize, aspect: Double, frame: CGRect) {
        if start == nil {
            let corners = [CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.minY),
                           CGPoint(x: frame.maxX, y: frame.maxY), CGPoint(x: frame.minX, y: frame.maxY)]
            let hit = corners.firstIndex { hypot($0.x - v.startLocation.x, $0.y - v.startLocation.y) < 32 }
            start = (crop.rect, hit)
        }
        guard let (r, corner) = start else { return }
        let dx = v.translation.width / size.width, dy = v.translation.height / size.height
        guard let corner else {
            crop.rect = r.offsetBy(dx: min(max(dx, -r.minX), 1 - r.maxX), dy: min(max(dy, -r.minY), 1 - r.maxY))
            return
        }
        // The corner opposite the dragged one stays put.
        let anchor = [CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY),
                      CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY)][corner]
        let moving = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                      CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)][corner]
        var w = min(1, max(0.1, abs(moving.x + dx - anchor.x)))
        var h = min(1, max(0.1, abs(moving.y + dy - anchor.y)))
        if let ratio = crop.ratioValue {
            h = w / (ratio == 0 ? 1 : ratio / aspect) // normalised width over height
            if h > 1 { h = 1; w = ratio == 0 ? 1 : ratio / aspect }
        }
        let next = CGRect(x: corner == 0 || corner == 3 ? anchor.x - w : anchor.x,
                          y: corner == 0 || corner == 1 ? anchor.y - h : anchor.y, width: w, height: h)
        // Refuse a drag that would leave the photo rather than distort the ratio.
        if next.minX >= -1e-6, next.minY >= -1e-6, next.maxX <= 1 + 1e-6, next.maxY <= 1 + 1e-6 { crop.rect = next }
    }
}

/// Dimmed outside, thirds inside, corner handles.
private struct CropFrame: View {
    let frame: CGRect

    var body: some View {
        Canvas { ctx, size in
            var outside = Path(CGRect(origin: .zero, size: size))
            outside.addRect(frame)
            ctx.fill(outside, with: .color(.black.opacity(0.55)), style: FillStyle(eoFill: true))
            var thirds = Path()
            for i in 1...2 {
                let x = frame.minX + frame.width * Double(i) / 3, y = frame.minY + frame.height * Double(i) / 3
                thirds.move(to: CGPoint(x: x, y: frame.minY)); thirds.addLine(to: CGPoint(x: x, y: frame.maxY))
                thirds.move(to: CGPoint(x: frame.minX, y: y)); thirds.addLine(to: CGPoint(x: frame.maxX, y: y))
            }
            ctx.stroke(thirds, with: .color(.white.opacity(0.5)), lineWidth: 0.5)
            ctx.stroke(Path(frame), with: .color(.white), lineWidth: 1)
            var handles = Path()
            let l = 18.0
            for (p, sx, sy) in [(CGPoint(x: frame.minX, y: frame.minY), 1.0, 1.0), (CGPoint(x: frame.maxX, y: frame.minY), -1, 1),
                                (CGPoint(x: frame.maxX, y: frame.maxY), -1, -1), (CGPoint(x: frame.minX, y: frame.maxY), 1, -1)] {
                handles.move(to: CGPoint(x: p.x + l * sx, y: p.y)); handles.addLine(to: p)
                handles.addLine(to: CGPoint(x: p.x, y: p.y + l * sy))
            }
            ctx.stroke(handles, with: .color(.white), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
    }
}

/// The panel's 裁剪 tab: ratio presets, turn and flip, straighten.
struct CropPane: View {
    @Binding var crop: Crop
    let aspect: Double // of the uncropped, unturned print

    var body: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Crop.ratios, id: \.key) { r in
                        Button(r.label) {
                            crop.ratio = r.key
                            crop.rect = crop.rectForRatio(crop.turnedAspect(aspect))
                        }
                        .font(.subheadline)
                        .foregroundStyle(crop.ratio == r.key ? .black : .primary)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(crop.ratio == r.key ? amber : Color(.tertiarySystemBackground), in: Capsule())
                    }
                }
                .padding(.horizontal, 16)
            }
            HStack {
                tool("rotate.right", "旋转") {
                    // A quarter turn swaps the sides; the frame starts over at the ratio.
                    crop.turns = (crop.turns + 1) % 4
                    crop.rect = crop.ratioValue == nil ? CGRect(x: 0, y: 0, width: 1, height: 1)
                        : crop.rectForRatio(crop.turnedAspect(aspect))
                }
                tool("arrow.left.and.right.righttriangle.left.righttriangle.right", "水平翻转") { crop.flipH.toggle() }
                tool("arrow.up.and.down.righttriangle.up.righttriangle.down", "垂直翻转") { crop.flipV.toggle() }
                tool("arrow.counterclockwise", "复原") { crop = Crop() }
            }
            HStack {
                Text("拉直")
                Slider(value: $crop.straighten, in: -45...45, step: 0.5).tint(amber)
                Text(String(format: "%.1f°", crop.straighten)).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
            }
            .padding(.horizontal, 16)
        }
    }

    private func tool(_ icon: String, _ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(.primary)
    }
}
