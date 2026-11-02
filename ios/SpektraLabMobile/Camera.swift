//  Camera.swift — a viewfinder that shows the film live, and a shutter that
//  keeps the RAW for the full engine.
//
//  The live view is the camera's video frames through a 3D LUT the engine
//  bakes for the chosen film and paper (Engine.bakeLUT): the same colour, but
//  without grain or halation, which are spatial and need the real print. The
//  shutter saves Apple ProRAW where the lens has it, else Bayer RAW, else
//  HEIC, into the library with the film it was shot on (and, unless turned
//  off, the original into Photos, since the library does not outlive the app).

import AVFoundation
import AVKit
import CoreImage
import CoreImage.CIFilterBuiltins
import MetalKit
import Photos
import SwiftUI

/// The capture session, the live LUT and the shutter. Video frames arrive on
/// `videoQueue`; `cube` and the preview's image are handed across with locks.
/// Observable state is only ever set on the main queue.
@Observable
final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate {
    struct Lens: Identifiable { let id: String; let label: String; let device: AVCaptureDevice }

    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored private let photoOutput = AVCapturePhotoOutput()
    @ObservationIgnored private let videoOutput = AVCaptureVideoDataOutput()
    @ObservationIgnored private let sessionQueue = DispatchQueue(label: "camera.session")
    @ObservationIgnored private let videoQueue = DispatchQueue(label: "camera.video")
    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private var cube: Data?
    @ObservationIgnored private var input: AVCaptureDeviceInput?
    @ObservationIgnored private var rotation: AVCaptureDevice.RotationCoordinator?

    @ObservationIgnored weak var preview: PreviewView?
    @ObservationIgnored var onCapture: (@MainActor (URL) -> Void)?
    @ObservationIgnored var onError: (@MainActor (String) -> Void)?

    private(set) var format = "" // "ProRAW", "RAW" or "HEIC" for the current lens
    private(set) var lenses: [Lens] = [] // the back lenses, widest first
    private(set) var lensID = ""
    private(set) var front = false
    private(set) var flashModes: [AVCaptureDevice.FlashMode] = []
    private(set) var biasRange: ClosedRange<Float> = -2...2
    var flash = AVCaptureDevice.FlashMode.off
    var saveOriginals = true

    func start() async {
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            await onError?("没有相机权限：请在 设置 › SpektraLab Mobile 里打开")
            return
        }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                self.configure()
                self.session.startRunning()
                done.resume()
            }
        }
    }

    func stop() {
        sessionQueue.async { self.session.stopRunning() }
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .photo
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        session.commitConfiguration()

        let lenses = Self.backLenses()
        DispatchQueue.main.async { self.lenses = lenses }
        if let wide = lenses.first(where: { $0.device.deviceType == .builtInWideAngleCamera }) ?? lenses.first {
            use(wide.device)
        }
    }

    /// The back cameras with their zoom labels, from the triple (or dual)
    /// camera's switch-over factors when there is one: those are relative to
    /// its widest lens.
    private static func backLenses() -> [Lens] {
        let kinds: [AVCaptureDevice.DeviceType] = [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera]
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: kinds, mediaType: .video, position: .back).devices
        let virtual = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera], mediaType: .video, position: .back
        ).devices.first
        let factors = [1.0] + (virtual?.virtualDeviceSwitchOverVideoZoomFactors.map { $0.doubleValue } ?? [])
        // Factors are relative to the virtual camera's first constituent; the wide lens is "1×".
        let constituents = virtual?.constituentDevices ?? []
        let wideIndex = constituents.firstIndex { $0.deviceType == .builtInWideAngleCamera } ?? 0
        let base = wideIndex < factors.count ? factors[wideIndex] : 1
        return devices.sorted { kinds.firstIndex(of: $0.deviceType)! < kinds.firstIndex(of: $1.deviceType)! }.map { d in
            let i = constituents.firstIndex { $0.deviceType == d.deviceType }
            let f = i.flatMap { $0 < factors.count ? factors[$0] / base : nil }
                ?? (d.deviceType == .builtInUltraWideCamera ? 0.5 : d.deviceType == .builtInTelephotoCamera ? 2 : 1)
            let label = f == f.rounded() ? "\(Int(f))" : String(format: "%.1f", f).replacingOccurrences(of: "0.", with: ".")
            return Lens(id: d.uniqueID, label: label + "×", device: d)
        }
    }

    /// Switch the session to `device`. On `sessionQueue`.
    private func use(_ device: AVCaptureDevice) {
        session.beginConfiguration()
        if let input { session.removeInput(input) }
        if let next = try? AVCaptureDeviceInput(device: device), session.canAddInput(next) {
            session.addInput(next)
            input = next
        }
        // ProRAW depends on the lens, and can only be switched on with the output in the session.
        photoOutput.isAppleProRAWEnabled = photoOutput.isAppleProRAWSupported
        // The live view is portrait; photos follow how the phone is held (`shoot`).
        if let c = videoOutput.connection(with: .video), c.isVideoRotationAngleSupported(90) { c.videoRotationAngle = 90 }
        session.commitConfiguration()

        let rotation = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        self.rotation = rotation
        let format = photoOutput.isAppleProRAWEnabled ? "ProRAW"
            : photoOutput.availableRawPhotoPixelFormatTypes.isEmpty ? "HEIC" : "RAW"
        let flashModes = photoOutput.supportedFlashModes
        let range = device.minExposureTargetBias...device.maxExposureTargetBias
        DispatchQueue.main.async {
            self.format = format
            self.lensID = device.uniqueID
            self.front = device.position == .front
            self.flashModes = flashModes
            if !flashModes.contains(self.flash) { self.flash = .off }
            self.biasRange = max(range.lowerBound, -2)...min(range.upperBound, 2)
        }
    }

    func selectLens(_ lens: Lens) {
        sessionQueue.async { self.use(lens.device) }
    }

    func flipCamera() {
        let toFront = !front
        sessionQueue.async {
            let device = toFront
                ? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
                : self.lenses.first { $0.device.deviceType == .builtInWideAngleCamera }?.device
            if let device { self.use(device) }
        }
    }

    /// Focus and meter at `point`, normalised in the portrait live view.
    func focus(at point: CGPoint) {
        sessionQueue.async {
            guard let device = self.input?.device, (try? device.lockForConfiguration()) != nil else { return }
            defer { device.unlockForConfiguration() }
            // The sensor is landscape: portrait (x, y) is sensor (y, 1 - x), or (y, x) mirrored on the front.
            let p = CGPoint(x: point.y, y: device.position == .front ? point.x : 1 - point.x)
            if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
                device.focusPointOfInterest = p
                device.focusMode = .autoFocus
            }
            if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposurePointOfInterest = p
                device.exposureMode = .continuousAutoExposure
            }
            device.isSubjectAreaChangeMonitoringEnabled = true
        }
    }

    /// Exposure compensation in stops.
    func setBias(_ ev: Float) {
        sessionQueue.async {
            guard let device = self.input?.device, (try? device.lockForConfiguration()) != nil else { return }
            device.setExposureTargetBias(ev)
            device.unlockForConfiguration()
        }
    }

    /// The live look; nil shows the camera as it is.
    func setCube(_ data: Data?) {
        lock.lock(); cube = data; lock.unlock()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        var image = CIImage(cvPixelBuffer: buffer)
        lock.lock(); let cube = cube; lock.unlock()
        if let cube {
            let filter = CIFilter.colorCubeWithColorSpace()
            filter.cubeDimension = 33
            filter.cubeData = cube
            filter.colorSpace = CGColorSpace(name: CGColorSpace.rommrgb)
            filter.inputImage = image
            image = filter.outputImage ?? image
        }
        preview?.show(image)
    }

    func shoot() {
        let flash = flash
        sessionQueue.async {
            // Upright however the phone is held.
            if let c = self.photoOutput.connection(with: .video), let angle = self.rotation?.videoRotationAngleForHorizonLevelCapture,
               c.isVideoRotationAngleSupported(angle) {
                c.videoRotationAngle = angle
            }
            let raw = self.photoOutput.availableRawPhotoPixelFormatTypes.first {
                self.photoOutput.isAppleProRAWEnabled
                    ? AVCapturePhotoOutput.isAppleProRAWPixelFormat($0)
                    : AVCapturePhotoOutput.isBayerRAWPixelFormat($0)
            }
            let settings = raw.map { AVCapturePhotoSettings(rawPixelFormatType: $0) }
                ?? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            if self.photoOutput.supportedFlashModes.contains(flash) { settings.flashMode = flash }
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let url = PhotoStore.dir.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(photo.isRawPhoto ? "dng" : "heic")
        guard error == nil, let data = photo.fileDataRepresentation(), (try? data.write(to: url)) != nil else {
            let message = error?.localizedDescription ?? "拍照失败"
            Task { @MainActor in self.onError?(message) }
            return
        }
        if saveOriginals {
            PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: url, options: nil)
            }
        }
        Task { @MainActor in self.onCapture?(url) }
    }
}

/// Draws the latest frame, filling the view, at the display's pace.
final class PreviewView: MTKView, MTKViewDelegate {
    private let context: CIContext
    private let queue: MTLCommandQueue
    private let lock = NSLock()
    private var latest: CIImage?

    init() {
        let device = MTLCreateSystemDefaultDevice()!
        context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        queue = device.makeCommandQueue()!
        super.init(frame: .zero, device: device)
        framebufferOnly = false
        colorPixelFormat = .bgra8Unorm
        preferredFramesPerSecond = 30
        delegate = self
    }

    required init(coder: NSCoder) { fatalError("not from a storyboard") }

    func show(_ image: CIImage) {
        lock.lock(); latest = image; lock.unlock()
    }

    func draw(in view: MTKView) {
        lock.lock(); let image = latest; lock.unlock()
        guard let image, let drawable = currentDrawable, let commands = queue.makeCommandBuffer() else { return }
        let size = drawableSize
        let s = max(size.width / image.extent.width, size.height / image.extent.height)
        let scaled = image.transformed(by: .init(scaleX: s, y: s))
        // Centred. No vertical flip: rendering to the drawable already puts the top at the top.
        let placed = scaled.transformed(by: .init(translationX: (size.width - scaled.extent.width) / 2 - scaled.extent.minX,
                                                  y: (size.height - scaled.extent.height) / 2 - scaled.extent.minY))
        context.render(placed, to: drawable.texture, commandBuffer: commands,
                       bounds: CGRect(origin: .zero, size: size), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        commands.present(drawable)
        commands.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}

struct CameraPreview: UIViewRepresentable {
    let camera: Camera

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        camera.preview = view
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}
}

struct CameraView: View {
    @Environment(Library.self) private var lib
    @Environment(\.dismiss) private var dismiss
    @State private var camera = Camera()
    @State private var settings = Settings()
    @State private var baking = false
    @State private var lastShot: UIImage?
    @State private var flash = false
    @State private var error: String?
    @State private var grid = false
    @State private var timer = 0 // seconds; 0 is off
    @State private var countdown = 0
    @State private var bias: Float = 0
    @State private var showBias = false
    @State private var focusPoint: CGPoint?

    var body: some View {
        VStack(spacing: 0) {
            topBar
            preview
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 10) {
                    ForEach(Stock.films) { stock in
                        StockCard(stock: stock, selected: stock.id == settings.film) { settings.film = stock.id }
                    }
                }
                .padding(.horizontal, 14)
            }
            .frame(height: 130)
            .padding(.top, 12)
            bottomBar
        }
        .background(.black)
        .statusBarHidden()
        .task {
            settings = lib.current?.settings ?? Settings()
            camera.onCapture = { url in
                lib.addCaptured(url, settings: settings)
                lastShot = PhotoStore.thumbnail(url)
            }
            camera.onError = { error = $0 }
            await camera.start()
            await bake()
        }
        .onChange(of: settings) { Task { await bake() } }
        .onDisappear { camera.stop() }
        // The volume buttons and the Camera Control fire the shutter too.
        .onCameraCaptureEvent { event in
            if event.phase == .ended { shutter() }
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { dismiss() } label: { icon("xmark") }
            Spacer()
            if !camera.flashModes.isEmpty {
                Button {
                    let modes: [AVCaptureDevice.FlashMode] = [.off, .auto, .on].filter(camera.flashModes.contains)
                    camera.flash = modes[((modes.firstIndex(of: camera.flash) ?? 0) + 1) % modes.count]
                } label: {
                    icon(camera.flash == .on ? "bolt.fill" : camera.flash == .auto ? "bolt.badge.automatic" : "bolt.slash",
                         on: camera.flash != .off)
                }
            }
            Button { timer = timer == 0 ? 3 : timer == 3 ? 10 : 0 } label: {
                ZStack {
                    icon("timer", on: timer > 0)
                    if timer > 0 {
                        Text("\(timer)").font(.system(size: 9, weight: .bold)).foregroundStyle(amber).offset(x: 13, y: -13)
                    }
                }
            }
            Button { showBias.toggle() } label: { icon("plusminus.circle", on: bias != 0 || showBias) }
            Button { grid.toggle() } label: { icon("grid", on: grid) }
            Menu {
                Toggle("原片存入相册", isOn: $camera.saveOriginals)
            } label: { icon("ellipsis") }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private var preview: some View {
        GeometryReader { geo in
            CameraPreview(camera: camera)
                .overlay { if grid { thirds } }
                .overlay { if flash { Color.black } }
                .contentShape(Rectangle())
                .onTapGesture { p in
                    camera.focus(at: CGPoint(x: p.x / geo.size.width, y: p.y / geo.size.height))
                    focusPoint = p
                    Task {
                        try? await Task.sleep(for: .seconds(1.2))
                        if focusPoint == p { focusPoint = nil }
                    }
                }
                .overlay(alignment: .topLeading) {
                    if let p = focusPoint {
                        RoundedRectangle(cornerRadius: 4).stroke(amber, lineWidth: 1.5)
                            .frame(width: 70, height: 70)
                            .position(p)
                            .transition(.scale(scale: 1.4).combined(with: .opacity))
                            .allowsHitTesting(false)
                    }
                }
                .animation(.snappy, value: focusPoint)
        }
        .aspectRatio(3 / 4, contentMode: .fit)
        .overlay(alignment: .top) {
            HStack {
                VStack(spacing: 0) {
                    Text(Stock.byID[settings.film]?.name ?? "").font(.caption.weight(.semibold))
                    Text(settings.isPositive ? "反转片 · 直接扫描" : Stock.byID[settings.paper]?.name ?? "")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 5)
                .glass(in: Capsule())
                if baking { ProgressView().controlSize(.small) }
                Spacer()
                if !camera.format.isEmpty {
                    Text(camera.format).font(.caption2.weight(.bold)).foregroundStyle(amber)
                        .padding(.horizontal, 10).padding(.vertical, 6).glass(in: Capsule())
                }
            }
            .padding(10)
        }
        .overlay(alignment: .bottom) {
            VStack(spacing: 10) {
                if showBias {
                    HStack {
                        Text(String(format: "%+.1f", bias)).font(.caption.monospacedDigit()).frame(width: 36)
                        Slider(value: $bias, in: camera.biasRange, step: 0.1).tint(amber)
                            .onChange(of: bias) { camera.setBias(bias) }
                        Button { bias = 0 } label: { Image(systemName: "arrow.counterclockwise").font(.caption) }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .glass(in: Capsule())
                    .padding(.horizontal, 40)
                }
                HStack(spacing: 4) {
                    if !camera.front {
                        ForEach(camera.lenses) { lens in
                            Button { camera.selectLens(lens) } label: {
                                Text(lens.label)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(lens.id == camera.lensID ? amber : .white)
                                    .frame(width: 38, height: 38)
                            }
                        }
                    }
                }
                .padding(.horizontal, 4)
                .glass(in: Capsule())
                .opacity(camera.lenses.count > 1 && !camera.front ? 1 : 0)
            }
            .padding(.bottom, 10)
        }
        .overlay {
            if countdown > 0 {
                Text("\(countdown)").font(.system(size: 96, weight: .thin)).foregroundStyle(.white)
                    .shadow(radius: 8).contentTransition(.numericText())
            }
            if let error {
                Text(error).font(.footnote).multilineTextAlignment(.center)
                    .padding().glass(in: RoundedRectangle(cornerRadius: 14)).padding()
            }
        }
    }

    private var bottomBar: some View {
        HStack {
            Menu {
                Picker("相纸", selection: $settings.paper) {
                    ForEach(Stock.papers) { Text($0.name).tag($0.id) }
                }
            } label: { icon("doc.plaintext", size: 52) }
            .disabled(settings.isPositive)
            Button { camera.flipCamera() } label: { icon("arrow.triangle.2.circlepath.camera", size: 52) }
            Spacer()
            Button(action: shutter) {
                Circle().fill(.white).frame(width: 66, height: 66)
                    .padding(5).overlay(Circle().stroke(.white, lineWidth: 3))
            }
            .disabled(error != nil || countdown > 0)
            Spacer()
            Color.clear.frame(width: 52, height: 52)
            // The last shot: tap to go and edit it.
            Button { dismiss() } label: {
                Image(uiImage: lastShot ?? UIImage())
                    .resizable().scaledToFill()
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.6), lineWidth: 1))
            }
            .opacity(lastShot == nil ? 0 : 1)
            .disabled(lastShot == nil)
        }
        .padding(.horizontal, 20).padding(.vertical, 16)
    }

    private var thirds: some View {
        Canvas { ctx, size in
            var p = Path()
            for i in 1...2 {
                let x = size.width * Double(i) / 3, y = size.height * Double(i) / 3
                p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
                p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
            }
            ctx.stroke(p, with: .color(.white.opacity(0.4)), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }

    private func icon(_ name: String, on: Bool = false, size: CGFloat = 40) -> some View {
        Image(systemName: name)
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(on ? amber : .white)
            .frame(width: size, height: size)
            .glass(in: Circle())
    }

    private func shutter() {
        guard countdown == 0, error == nil else { return }
        Task {
            for s in stride(from: timer, to: 0, by: -1) {
                withAnimation { countdown = s }
                try? await Task.sleep(for: .seconds(1))
            }
            countdown = 0
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            camera.shoot()
            withAnimation(.linear(duration: 0.08)) { flash = true }
            withAnimation(.linear(duration: 0.2).delay(0.08)) { flash = false }
        }
    }

    private func bake() async {
        baking = true
        let wanted = settings
        let cube = try? await Engine.shared.bakeLUT(wanted)
        // A newer choice may have been made while this one baked.
        if wanted == settings { camera.setCube(cube) }
        baking = false
    }
}
