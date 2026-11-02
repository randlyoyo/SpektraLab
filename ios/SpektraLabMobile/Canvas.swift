//  Canvas.swift — the photo, with before/after: hold, the 原图 toggle, or the split.

import PhotosUI
import SwiftUI

enum Compare { case off, original, split }

struct CanvasView: View {
    @Environment(Library.self) private var lib
    @State private var holding = false
    @State private var compare = Compare.off
    @State private var split = 0.5 // the divider, as a fraction of the width
    @State private var zoom = 1.0
    @State private var lastZoom = 1.0
    @State private var pan = CGSize.zero
    @State private var lastPan = CGSize.zero

    var body: some View {
        // The photo runs under the navigation bar; the labels over it do not.
        ZStack { photo.ignoresSafeArea(edges: .top) }
        .overlay(alignment: .topLeading) {
            if lib.currentOriginal != nil, holding || compare != .off {
                HStack {
                    label("原图", highlight: compare != .split)
                    Spacer()
                    if compare == .split && !holding { label("冲印") }
                }
                .padding(12)
            }
        }
        .overlay(alignment: .bottom) {
            if lib.current != nil {
                HStack {
                    compareButtons
                    Spacer()
                    if lib.busy {
                        HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("冲印中") }
                            .font(.caption2).padding(.horizontal, 10).padding(.vertical, 6).glass(in: Capsule())
                    } else if let status = lib.current?.status, !status.isEmpty {
                        label(status)
                    }
                }
                .padding(12)
            }
        }
        .onChange(of: lib.currentID) { resetZoom() }
    }

    private var photo: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let print = lib.currentPrint {
                    let original = lib.currentOriginal
                    if compare == .split, let original, !holding {
                        splitView(print, original, width: geo.size.width)
                    } else {
                        zoomable(holding || compare == .original ? original ?? print : print)
                    }
                } else if let p = lib.current {
                    // The thumbnail under a spinner until the first print lands.
                    Image(uiImage: p.thumb ?? UIImage()).resizable().scaledToFit().blur(radius: 12).opacity(0.5)
                    ProgressView().controlSize(.large)
                } else {
                    empty
                }
            }
        }
    }

    private var empty: some View {
        @Bindable var lib = lib
        return PhotosPicker(selection: $lib.picked, selectionBehavior: .ordered, matching: .images,
                            preferredItemEncoding: .current) {
            VStack(spacing: 12) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 34))
                    .frame(width: 84, height: 84)
                    .background(amber.opacity(0.14), in: Circle())
                Text("导入照片").font(.headline).foregroundStyle(.white)
                Text("可以一次选多张 · RAW / ProRAW / HEIC / JPEG").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func zoomable(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable().scaledToFit()
            .scaleEffect(zoom)
            .offset(pan)
            .gesture(MagnifyGesture()
                .onChanged { zoom = min(6, max(1, lastZoom * $0.magnification)) }
                .onEnded { _ in lastZoom = zoom; if zoom == 1 { resetZoom() } })
            .simultaneousGesture(DragGesture()
                .onChanged { if zoom > 1 { pan = lastPan + $0.translation } }
                .onEnded { _ in lastPan = pan })
            .onTapGesture(count: 2) {
                withAnimation(.snappy) {
                    if zoom > 1 { resetZoom() } else { zoom = 2.5; lastZoom = 2.5 }
                }
            }
            // Press and hold to see the photo before the film.
            .onLongPressGesture(minimumDuration: 0.3, perform: {}, onPressingChanged: { holding = $0 })
    }

    /// Original left of the divider, print right of it. No zoom here: the
    /// divider is in screen coordinates.
    private func splitView(_ print: UIImage, _ original: UIImage, width: CGFloat) -> some View {
        ZStack {
            Image(uiImage: print).resizable().scaledToFit()
            Image(uiImage: original).resizable().scaledToFit()
                .mask(alignment: .leading) { Rectangle().frame(width: width * split) }
            GeometryReader { g in
                ZStack {
                    Rectangle().fill(.white).frame(width: 2)
                    Image(systemName: "arrow.left.and.right")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 36, height: 36)
                        .glass(in: Circle())
                }
                .position(x: g.size.width * split, y: g.size.height / 2)
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged {
            split = min(0.98, max(0.02, $0.location.x / width))
        })
    }

    /// 原图 toggle and 分屏; tapping the active one turns it off.
    private var compareButtons: some View {
        HStack(spacing: 0) {
            button(.original, "eye", "原图")
            Divider().frame(height: 18)
            button(.split, "rectangle.split.2x1", "分屏")
        }
        .glass(in: Capsule())
        .disabled(lib.currentOriginal == nil)
    }

    private func button(_ mode: Compare, _ icon: String, _ title: String) -> some View {
        Button { compare = compare == mode ? .off : mode } label: {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(compare == mode ? amber : .white)
                .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    private func label(_ text: String, highlight: Bool = false) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(highlight ? amber : .white)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .glass(in: Capsule())
    }

    private func resetZoom() {
        zoom = 1; lastZoom = 1; pan = .zero; lastPan = .zero
    }
}

private func + (a: CGSize, b: CGSize) -> CGSize { CGSize(width: a.width + b.width, height: a.height + b.height) }
