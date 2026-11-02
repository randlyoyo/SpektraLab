//  Canvas.swift — the photo: tap for full screen, the 原图 button to compare.

import PhotosUI
import SwiftUI

struct CanvasView: View {
    @Environment(Library.self) private var lib
    @State private var fullscreen = false

    /// The print, or the original while the 原图 button is on, cropped.
    private var shown: UIImage? { lib.shownImage }

    var body: some View {
        // The photo runs under the navigation bar; the labels over it do not.
        ZStack { photo.ignoresSafeArea(edges: .top) }
            .overlay(alignment: .topLeading) {
                if lib.showOriginal, lib.currentOriginal != nil { label("原图", highlight: true).padding(12) }
            }
            .overlay(alignment: .bottom) {
                if lib.current != nil {
                    HStack {
                        originalButton
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
            .fullScreenCover(isPresented: $fullscreen) {
                if let shown { FullscreenView(image: shown) }
            }
    }

    @ViewBuilder private var photo: some View {
        ZStack {
            Color.black
            if lib.pane == .crop, let p = lib.current, let turned = lib.turnedImage {
                CropEditor(image: turned, crop: Binding(get: { p.crop }, set: { p.crop = $0 }))
                    .padding(.top, 50) // clear of the navigation bar
            } else if let shown {
                ZoomableImage(image: shown, resetOn: lib.currentID) { fullscreen = true }
            } else if let p = lib.current {
                // The thumbnail under a spinner until the first print lands.
                Image(uiImage: p.thumb ?? UIImage()).resizable().scaledToFit().blur(radius: 12).opacity(0.5)
                ProgressView().controlSize(.large)
            } else {
                empty
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

    /// Switches between the print and the original.
    private var originalButton: some View {
        Button { lib.showOriginal.toggle() } label: {
            Label("原图", systemImage: lib.showOriginal ? "eye.fill" : "eye")
                .font(.caption)
                .foregroundStyle(lib.showOriginal ? amber : .white)
                .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .glass(in: Capsule())
        .disabled(lib.currentOriginal == nil)
    }

    private func label(_ text: String, highlight: Bool = false) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(highlight ? amber : .white)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .glass(in: Capsule())
    }
}

/// The photo alone on black. Tap to close; double-tap to zoom.
struct FullscreenView: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ZoomableImage(image: image, resetOn: nil, zoomOnDoubleTap: true) { dismiss() }
                .ignoresSafeArea()
        }
        .statusBarHidden()
    }
}

/// Pinch to zoom, drag to pan when zoomed; `onTap` on a single tap.
struct ZoomableImage: View {
    let image: UIImage
    let resetOn: String?
    var zoomOnDoubleTap = false
    let onTap: () -> Void

    @State private var zoom = 1.0
    @State private var lastZoom = 1.0
    @State private var pan = CGSize.zero
    @State private var lastPan = CGSize.zero

    var body: some View {
        Image(uiImage: image)
            .resizable().scaledToFit()
            .scaleEffect(zoom)
            .offset(pan)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(MagnifyGesture()
                .onChanged { zoom = min(6, max(1, lastZoom * $0.magnification)) }
                .onEnded { _ in lastZoom = zoom; if zoom == 1 { reset() } })
            .simultaneousGesture(DragGesture()
                .onChanged { if zoom > 1 { pan = lastPan + $0.translation } }
                .onEnded { _ in lastPan = pan })
            // Off on the canvas: a double-tap gesture would delay every single tap.
            .gesture(TapGesture(count: 2).onEnded {
                withAnimation(.snappy) {
                    if zoom > 1 { reset() } else { zoom = 2.5; lastZoom = 2.5 }
                }
            }, including: zoomOnDoubleTap ? .all : .none)
            .onTapGesture(perform: onTap)
            .onChange(of: resetOn) { reset() }
    }

    private func reset() {
        zoom = 1; lastZoom = 1; pan = .zero; lastPan = .zero
    }
}

private func + (a: CGSize, b: CGSize) -> CGSize { CGSize(width: a.width + b.width, height: a.height + b.height) }
