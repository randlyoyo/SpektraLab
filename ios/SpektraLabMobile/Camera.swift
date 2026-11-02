//  Camera.swift — a viewfinder that shows the film live, and a shutter that
//  keeps the RAW for the full engine.
//
//  The live view is the camera's video frames through a 3D LUT the engine
//  bakes for the chosen film and paper (Engine.bakeLUT): the same colour, but
//  without grain or halation, which are spatial and need the real print. The
//  shutter saves Apple ProRAW where the phone has it, else Bayer RAW, else
//  HEIC, into the library with the film it was shot on.

import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import MetalKit
import SwiftUI

/// The capture session, the live LUT and the shutter. Video frames arrive on
/// `videoQueue`; `cube` and the preview's image are handed across with locks.
@Observable
final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate {
    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored private let photoOutput = AVCapturePhotoOutput()
    @ObservationIgnored private let videoOutput = AVCaptureVideoDataOutput()
    @ObservationIgnored private let sessionQueue = DispatchQueue(label: "camera.session")
    @ObservationIgnored private let videoQueue = DispatchQueue(label: "camera.video")
    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private var cube: Data?

    @ObservationIgnored weak var preview: PreviewView?
    @ObservationIgnored var onCapture: (@MainActor (URL) -> Void)?
    @ObservationIgnored var onError: (@MainActor (String) -> Void)?
    private(set) var format = "" // "ProRAW", "RAW" or "HEIC", once configured

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
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
        session.addInput(input)

        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        // ProRAW can only be switched on once the output is in the session.
        if photoOutput.isAppleProRAWSupported { photoOutput.isAppleProRAWEnabled = true }
        let format = photoOutput.isAppleProRAWEnabled ? "ProRAW"
            : photoOutput.availableRawPhotoPixelFormatTypes.isEmpty ? "HEIC" : "RAW"
        DispatchQueue.main.async { self.format = format }

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        // Portrait frames, and portrait photos.
        for connection in [videoOutput.connection(with: .video), photoOutput.connection(with: .video)] {
            if let connection, connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
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
        sessionQueue.async {
            let raw = self.photoOutput.availableRawPhotoPixelFormatTypes.first {
                self.photoOutput.isAppleProRAWEnabled
                    ? AVCapturePhotoOutput.isAppleProRAWPixelFormat($0)
                    : AVCapturePhotoOutput.isBayerRAWPixelFormat($0)
            }
            let settings = raw.map { AVCapturePhotoSettings(rawPixelFormatType: $0) }
                ?? AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
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
        let placed = scaled
            .transformed(by: .init(translationX: (size.width - scaled.extent.width) / 2 - scaled.extent.minX,
                                   y: (size.height - scaled.extent.height) / 2 - scaled.extent.minY))
            // Core Image's origin is bottom-left, a Metal texture's top-left.
            .transformed(by: CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -size.height))
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
    @State private var shots = 0
    @State private var flash = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: 44, height: 44)
                }
                .glass(in: Circle())
                Spacer()
                VStack(spacing: 0) {
                    Text(Stock.byID[settings.film]?.name ?? "").font(.subheadline.weight(.semibold))
                    Text(settings.isPositive ? "反转片 · 直接扫描" : Stock.byID[settings.paper]?.name ?? "")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
                .glass(in: Capsule())
                Spacer()
                Text(camera.format.isEmpty ? "  " : camera.format)
                    .font(.caption.weight(.bold)).foregroundStyle(amber)
                    .frame(width: 60, height: 44)
                    .glass(in: Capsule())
            }
            .padding(.horizontal, 16).padding(.vertical, 8)

            CameraPreview(camera: camera)
                .aspectRatio(3 / 4, contentMode: .fit)
                .overlay { if flash { Color.black } }
                .overlay(alignment: .topTrailing) {
                    if baking { ProgressView().padding(10).glass(in: Circle()).padding(10) }
                }
                .overlay {
                    if let error {
                        Text(error).font(.footnote).multilineTextAlignment(.center)
                            .padding().glass(in: RoundedRectangle(cornerRadius: 14)).padding()
                    }
                }

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

            HStack {
                Menu {
                    Picker("相纸", selection: $settings.paper) {
                        ForEach(Stock.papers) { Text($0.name).tag($0.id) }
                    }
                } label: {
                    Image(systemName: "doc.plaintext").font(.title3).frame(width: 52, height: 52)
                }
                .glass(in: Circle())
                .disabled(settings.isPositive)
                Spacer()
                Button {
                    camera.shoot()
                    withAnimation(.linear(duration: 0.08)) { flash = true }
                    withAnimation(.linear(duration: 0.2).delay(0.08)) { flash = false }
                } label: {
                    Circle().fill(.white).frame(width: 66, height: 66)
                        .padding(5).overlay(Circle().stroke(.white, lineWidth: 3))
                }
                .disabled(error != nil)
                Spacer()
                Text(shots == 0 ? "" : "\(shots)")
                    .font(.headline.monospacedDigit())
                    .frame(width: 52, height: 52)
                    .glass(in: Circle())
                    .opacity(shots == 0 ? 0 : 1)
            }
            .padding(.horizontal, 32).padding(.vertical, 16)
        }
        .background(.black)
        .task {
            settings = lib.current?.settings ?? Settings()
            camera.onCapture = { url in
                lib.addCaptured(url, settings: settings)
                shots += 1
            }
            camera.onError = { error = $0 }
            await camera.start()
            await bake()
        }
        .onChange(of: settings) { Task { await bake() } }
        .onDisappear { camera.stop() }
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
