//  App.swift — the editor screen: native toolbar, canvas, filmstrip, panel.

import PhotosUI
import SwiftUI

let amber = Color(red: 0.89, green: 0.64, blue: 0.25)

@main
struct SpektraLabMobileApp: App {
    @State private var library = Library()

    var body: some Scene {
        WindowGroup {
            EditorView()
                .environment(library)
                .preferredColorScheme(.dark)
                .tint(amber)
        }
    }
}

struct EditorView: View {
    @Environment(Library.self) private var lib
    @State private var syncing = false
    @State private var shooting = false

    var body: some View {
        @Bindable var lib = lib
        NavigationStack {
            VStack(spacing: 0) {
                CanvasView()
                if !lib.photos.isEmpty { Filmstrip() }
                PanelView(syncing: $syncing)
            }
            .background(.black)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar { toolbar }
            .onChange(of: lib.picked) { Task { await lib.importPicked() } }
            .sheet(isPresented: $syncing) { SyncSheet() }
            .fullScreenCover(isPresented: $shooting, onDismiss: {
                if let p = lib.lastCaptured {
                    lib.lastCaptured = nil
                    lib.show(p)
                }
            }) { CameraView() }
            .sheet(isPresented: .constant(lib.exporting != nil)) { ExportSheet() }
            .overlay(alignment: .top) {
                if let toast = lib.toast {
                    Text(toast)
                        .font(.subheadline)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .glass(in: Capsule())
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.snappy, value: lib.toast)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        @Bindable var lib = lib
        ToolbarItemGroup(placement: .topBarLeading) {
            if lib.selecting {
                Button("全选", action: lib.selectAll).disabled(lib.photos.count < 2)
            } else {
                PhotosPicker(selection: $lib.picked, selectionBehavior: .ordered, matching: .images,
                             preferredItemEncoding: .current) {
                    Image(systemName: "plus")
                }
                .disabled(lib.busy)
                Button { shooting = true } label: { Image(systemName: "camera") }
            }
        }
        ToolbarItem(placement: .principal) {
            if let s = lib.current?.settings {
                VStack(spacing: 0) {
                    Text(Stock.byID[s.film]?.name ?? s.film).font(.subheadline.weight(.semibold))
                    Text(s.isPositive ? "反转片 · 直接扫描" : Stock.byID[s.paper]?.name ?? s.paper)
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            if lib.photos.count > 1 {
                Button(lib.selecting ? "完成" : "选择", action: lib.toggleSelecting)
            }
            if !lib.selecting, let p = lib.current {
                ShareLink(item: SharedPrint(id: p.id, settings: p.settings, crop: p.crop),
                          preview: SharePreview(Stock.byID[p.settings.film]?.name ?? "SpektraLab",
                                                image: Image(uiImage: lib.currentPrint ?? p.thumb ?? UIImage()))) {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(lib.currentPrint == nil || lib.busy)
            }
        }
    }
}

struct Filmstrip: View {
    @Environment(Library.self) private var lib

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 6) {
                ForEach(lib.photos) { p in thumb(p) }
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 68)
    }

    private func thumb(_ p: Photo) -> some View {
        let isCurrent = p.id == lib.currentID
        let isSelected = isCurrent || lib.selected.contains(p.id)
        return Button { lib.tap(p) } label: {
            Image(uiImage: p.thumb ?? UIImage())
                .resizable().scaledToFill()
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .opacity(lib.selecting && !isSelected ? 0.45 : 1)
                .padding(2)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(isCurrent ? amber : .clear, lineWidth: 2))
                .overlay(alignment: lib.selecting ? .bottomTrailing : .topTrailing) {
                    if lib.selecting {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 16))
                            .foregroundStyle(isSelected ? amber : .white.opacity(0.8))
                            .padding(4)
                    } else if p.edited {
                        Circle().fill(amber).frame(width: 7, height: 7).padding(5)
                    }
                }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("拷贝设置", systemImage: "doc.on.doc") {
                lib.clipboard = p.settings
                lib.say("已拷贝设置")
            }
            if lib.clipboard != nil {
                Button("粘贴设置", systemImage: "doc.on.clipboard") { lib.paste(to: p) }
            }
            Button("移除照片", systemImage: "trash", role: .destructive) { lib.remove(p) }
        }
    }
}

struct SyncSheet: View {
    @Environment(Library.self) private var lib
    @Environment(\.dismiss) private var dismiss
    @State private var groups = Set(SyncGroup.allCases)

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(SyncGroup.allCases) { g in
                        Toggle(g.rawValue, isOn: Binding(
                            get: { groups.contains(g) },
                            set: { if $0 { groups.insert(g) } else { groups.remove(g) } }))
                    }
                } footer: {
                    Text("把当前照片的设置应用到另外 \(lib.selected.count) 张。照片打开时按新设置冲印。")
                }
            }
            .navigationTitle("同步设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("同步") {
                        lib.sync(groups)
                        dismiss()
                    }
                    .disabled(groups.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

struct ExportSheet: View {
    @Environment(Library.self) private var lib

    var body: some View {
        let p = lib.exporting ?? (0, 1)
        VStack(spacing: 16) {
            Text("正在导出到相册").font(.headline)
            ProgressView(value: Double(p.done), total: Double(p.total))
            Text("\(p.done) / \(p.total)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            Button("停止", role: .destructive) { lib.stopExport = true }
                .disabled(lib.stopExport)
        }
        .padding(24)
        .presentationDetents([.height(220)])
        .interactiveDismissDisabled()
    }
}

extension View {
    /// Liquid Glass on iOS 26 and later, a material before it.
    @ViewBuilder func glass(in shape: some Shape) -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
        }
    }
}
