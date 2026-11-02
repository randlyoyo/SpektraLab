//  Engine.swift — the engine's C ABI for the phone, and where picked photos live.
//
//  The Mac app's EngineClient + ImageDecoder cut to what this app uses. Same
//  conventions: float32 linear ProPhoto in, top row first, through a shared
//  MTLBuffer (`spk_open_device`); ProPhoto RGB (ROMM-encoded) RGBA16 out.

import CoreImage
import CoreTransferable
import Foundation
import ImageIO
import Metal
import Photos
import UIKit
import UniformTypeIdentifiers

struct EngineError: LocalizedError {
    let errorDescription: String?
}

/// Picked photos are copied to tmp/photos/<id>.<ext> rather than held in
/// memory: a batch of RAWs is gigabytes. The extension is kept because
/// CIRAWFilter reads the format from it.
enum PhotoStore {
    static let dir: URL = {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("photos")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static func url(_ id: String) -> URL {
        (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .first { $0.deletingPathExtension().lastPathComponent == id } ?? dir.appendingPathComponent(id)
    }

    /// Take a file the picker handed over (it is deleted after the import closure returns).
    static func adopt(_ src: URL) throws -> URL {
        let dest = dir.appendingPathComponent(UUID().uuidString).appendingPathExtension(src.pathExtension)
        try FileManager.default.copyItem(at: src, to: dest)
        return dest
    }

    static func remove(_ id: String) { try? FileManager.default.removeItem(at: url(id)) }

    /// The file's embedded or decoded thumbnail, upright, for the filmstrip.
    static func thumbnail(_ url: URL) -> UIImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 240,
              ] as CFDictionary)
        else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// What PhotosPicker hands over: the original file, RAW preferred so a
/// RAW+JPEG pair develops from the RAW.
struct PickedFile: Transferable {
    let url: URL
    var id: String { url.deletingPathExtension().lastPathComponent }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .rawImage) { PickedFile(url: try PhotoStore.adopt($0.file)) }
        FileRepresentation(importedContentType: .image) { PickedFile(url: try PhotoStore.adopt($0.file)) }
    }
}

/// The share sheet's item: printed at full size when the sheet asks for it.
struct SharedPrint: Transferable {
    let id: String
    let settings: Settings
    let crop: Crop

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .heic) { item in
            SentTransferredFile(try await Engine.shared.heicFile(item.id, item.settings, item.crop))
        }
    }
}

struct Developed {
    let print: UIImage?
    let original: UIImage? // only on a fresh decode
    let info: String
}

/// One engine, one open photo.
actor Engine {
    static let shared = Engine()

    // ponytail: input capped at 12 MP so a 48 MP ProRAW fits the phone's memory
    // limit; raise once the increased-memory-limit entitlement and striped
    // renders are measured on a device.
    static let maxInputPixels = 12_000_000.0
    /// Long edge of the image shown on screen; saving uses the full print.
    static let displayEdge = 2560.0

    let device = MTLCreateSystemDefaultDevice()!
    private lazy var context = CIContext(mtlDevice: device, options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!,
        .workingFormat: CIFormat.RGBAh,
        .cacheIntermediates: false,
        .highQualityDownsample: true,
    ])
    private var engine: OpaquePointer?
    private var session: OpaquePointer?
    private var openID: String?
    private var lastPrint: CGImage?
    private var lastPrintKey: String? // "<id>|<params>" of `lastPrint`

    /// Linear ROMM, as in the Mac app's `ImageDecoder.linearProPhoto`.
    private static let linearProPhoto: CGColorSpace = {
        let d50: [CGFloat] = [0.9642, 1.0000, 0.8249]
        let black: [CGFloat] = [0, 0, 0]
        let gamma: [CGFloat] = [1, 1, 1]
        let m: [CGFloat] = [0.7976749, 0.2880402, 0.0000000,
                            0.1351917, 0.7118741, 0.0000000,
                            0.0313534, 0.0000857, 0.8252100]
        return CGColorSpace(calibratedRGBWhitePoint: d50, blackPoint: black, gamma: gamma, matrix: m)!
    }()
    private static let outputSpace = CGColorSpace(name: CGColorSpace.rommrgb)!
    private static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!

    private func fail(_ engine: OpaquePointer?) -> EngineError {
        EngineError(errorDescription: String(cString: spk_last_error(engine)))
    }

    private func started() throws -> OpaquePointer {
        if let engine { return engine }
        let path = Bundle.main.resourceURL!.appendingPathComponent("engine").path
        guard let e = spk_engine_create(path, Unmanaged.passUnretained(device).toOpaque()) else { throw fail(nil) }
        engine = e
        return e
    }

    /// Print photo `id` with `settings`, decoding it first unless it is the
    /// open one. `film` false reuses the cached negative (only the paper
    /// changed), as the Mac app's reprint does. `display` false skips the
    /// on-screen images (batch export).
    func develop(_ id: String, _ settings: Settings, film: Bool, display: Bool = true) throws -> Developed {
        let params = try json(settings.params)
        var original: CIImage?
        var film = film
        if id != openID || session == nil {
            original = try open(id, params)
            film = true
        } else if let session {
            var out: UnsafeMutablePointer<CChar>?
            let status = params.withCString { spk_set_params(session, $0, &out) }
            if let out { spk_string_free(out) }
            guard status == SPK_OK else { throw fail(engine) }
        }
        guard let session else { throw EngineError(errorDescription: "No photo open") }

        var result = spk_result()
        let rendered = film ? spk_render(session, "full", &result) : spk_reprint(session, "full", &result)
        guard rendered == SPK_OK else { throw fail(engine) }
        defer { spk_result_free(&result) }

        // Copy out: `rgba16` lives only as long as the result handle.
        let rowBytes = Int(result.row_stride_px) * 8
        let pixels = Data(bytes: result.rgba16, count: rowBytes * Int(result.height))
        guard let cg = CGImage(width: Int(result.width), height: Int(result.height),
                               bitsPerComponent: 16, bitsPerPixel: 64, bytesPerRow: rowBytes,
                               space: Self.outputSpace,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue
                                                        | CGBitmapInfo.byteOrder16Little.rawValue),
                               provider: CGDataProvider(data: pixels as CFData)!,
                               decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw EngineError(errorDescription: "Could not wrap the render") }
        lastPrint = cg
        lastPrintKey = "\(id)|\(params)"

        return Developed(print: display ? screenImage(CIImage(cgImage: cg)) : nil,
                         original: display ? original.flatMap(screenImage) : nil,
                         info: "\(cg.width)×\(cg.height) · \(Int(result.elapsed_ms)) ms")
    }

    /// Decode photo `id` and open it as the session. Returns the camera's own
    /// rendering, for comparing against the print.
    private func open(_ id: String, _ params: String) throws -> CIImage {
        let engine = try started()
        if let session { spk_session_release(session); self.session = nil; openID = nil }
        let url = PhotoStore.url(id)

        let image: CIImage
        let original: CIImage
        if let raw = CIRAWFilter(imageURL: url) {
            original = raw.outputImage ?? CIImage.empty()
            raw.isDraftModeEnabled = false
            // Apple's tone rendering off: the film model wants sensor response.
            raw.boostAmount = 0
            raw.boostShadowAmount = 0
            raw.isGamutMappingEnabled = false
            raw.localToneMapAmount = 0
            raw.extendedDynamicRangeAmount = 0
            guard let out = raw.outputImage else { throw EngineError(errorDescription: "RAW decode failed") }
            image = out
        } else if let flat = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) {
            image = flat
            original = flat
        } else {
            throw EngineError(errorDescription: "Unsupported image")
        }

        let extent = image.extent.integral
        let scale = min(1, (Self.maxInputPixels / (extent.width * extent.height)).squareRoot())
        let placed = image
            .transformed(by: .init(translationX: -extent.origin.x, y: -extent.origin.y))
            .transformed(by: .init(scaleX: scale, y: scale))
        let width = Int(extent.width * scale), height = Int(extent.height * scale)
        guard let buffer = device.makeBuffer(length: width * height * 16, options: .storageModeShared) else {
            throw EngineError(errorDescription: "Out of memory for a \(width)×\(height) frame")
        }
        // render(toBitmap:) writes top row first: no flip (see the Mac decoder).
        autoreleasepool {
            context.render(placed, toBitmap: buffer.contents(), rowBytes: width * 16,
                           bounds: CGRect(x: 0, y: 0, width: width, height: height),
                           format: .RGBAf, colorSpace: Self.linearProPhoto)
        }

        var input = spk_device_image(buffer: Unmanaged.passUnretained(buffer).toOpaque(),
                                     width: UInt32(width), height: UInt32(height), channels: 4)
        var reply: UnsafeMutablePointer<CChar>?
        let handle = params.withCString { delta in
            withUnsafePointer(to: &input) { spk_open_device(engine, $0, delta, &reply) }
        }
        if let reply { spk_string_free(reply) }
        guard let handle else { throw fail(engine) }
        session = handle
        openID = id
        return original
    }

    /// The full print, cropped, as Display P3 HEIC, converted once from ProPhoto.
    private func heic(_ crop: Crop) throws -> Data {
        guard let lastPrint,
              let data = context.heifRepresentation(of: crop.apply(CIImage(cgImage: lastPrint)), format: .RGBA8,
                                                    colorSpace: Self.displayP3, options: [:])
        else { throw EngineError(errorDescription: "Nothing to save") }
        return data
    }

    /// Save the last print, cropped, to Photos.
    func save(_ crop: Crop) async throws {
        let data = try heic(crop)
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
        }
    }

    /// A HEIC file of photo `id` printed with `settings`, for the share sheet.
    /// Reuses the last print when it is exactly that.
    func heicFile(_ id: String, _ settings: Settings, _ crop: Crop) throws -> URL {
        try ensurePrint(id, settings)
        let film = Stock.byID[settings.film]?.name ?? "Print"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpektraLab \(film).heic")
        try heic(crop).write(to: url, options: .atomic)
        return url
    }

    /// Photo `id` printed with `settings` and cropped, Display P3, scaled to
    /// `longEdge` when given (the collage's preview) or full size (its export).
    func croppedPrint(_ id: String, _ settings: Settings, _ crop: Crop, longEdge: Double?) throws -> CGImage {
        try ensurePrint(id, settings)
        var image = crop.apply(CIImage(cgImage: lastPrint!))
        if let longEdge {
            let s = min(1, longEdge / max(image.extent.width, image.extent.height))
            image = image.transformed(by: .init(scaleX: s, y: s))
        }
        guard let cg = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: Self.displayP3)
        else { throw EngineError(errorDescription: "Could not crop the print") }
        return cg
    }

    /// Make `lastPrint` photo `id` with `settings`, unless it already is.
    private func ensurePrint(_ id: String, _ settings: Settings) throws {
        if lastPrintKey != "\(id)|\(try json(settings.params))" {
            _ = try develop(id, settings, film: true, display: false)
        }
    }

    /// The film and paper of `settings` as a 3D LUT for the camera's live view:
    /// `size`³ RGBA float32 entries, red fastest, input and output both ROMM
    /// RGB (ProPhoto, γ1.8) as `CIColorCubeWithColorSpace` takes them.
    ///
    /// Made by printing a picture of the LUT's own grid: each entry a block of
    /// pixels, read back at the block's centre. Everything spatial (grain,
    /// halation, glare, lens blur) and the auto exposure are off, so a block
    /// prints as its colour alone; the frame is declared 200 mm wide so the
    /// remaining diffusion stays well inside a block. The open photo is
    /// closed: the next edit reopens it.
    func bakeLUT(_ settings: Settings, size n: Int = 33) throws -> Data {
        let engine = try started()
        if let session { spk_session_release(session); self.session = nil; openID = nil; lastPrintKey = nil }

        let block = 6, width = n * n * block, height = n * block
        // ROMM decoding, so the grid is even in the encoded values the cube is indexed by.
        func linear(_ i: Int) -> Float {
            let e = Float(i) / Float(n - 1)
            return e < 16.0 / 512.0 ? e / 16 : pow(e, 1.8)
        }
        var pixels = [Float](repeating: 0, count: width * height * 3)
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let x0 = (r + n * g) * block, y0 = b * block
                    let rgb = (linear(r), linear(g), linear(b))
                    for y in y0..<(y0 + block) {
                        for x in x0..<(x0 + block) {
                            let i = (y * width + x) * 3
                            pixels[i] = rgb.0; pixels[i + 1] = rgb.1; pixels[i + 2] = rgb.2
                        }
                    }
                }
            }
        }

        var params = settings.params
        params["auto_exposure"] = false
        params["grain_active"] = false
        params["halation_active"] = false
        params["glare_active"] = false
        params["lens_blur_um"] = 0.0
        params["scanner_lens_blur"] = 0.0
        params["film_format_mm"] = 200.0
        var reply: UnsafeMutablePointer<CChar>?
        let handle: OpaquePointer? = try json(params).withCString { delta in
            pixels.withUnsafeBufferPointer { buf in
                var image = spk_image(data: buf.baseAddress, width: UInt32(width), height: UInt32(height), channels: 3)
                return spk_open(engine, &image, delta, &reply)
            }
        }
        if let reply { spk_string_free(reply) }
        guard let lutSession = handle else { throw fail(engine) }
        defer { spk_session_release(lutSession) }

        var result = spk_result()
        guard spk_render(lutSession, "full", &result) == SPK_OK else { throw fail(engine) }
        defer { spk_result_free(&result) }
        guard Int(result.width) == width, Int(result.height) == height else {
            throw EngineError(errorDescription: "LUT print is \(result.width)×\(result.height), not \(width)×\(height)")
        }

        var cube = [Float](repeating: 1, count: n * n * n * 4)
        let stride = Int(result.row_stride_px)
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let x = (r + n * g) * block + block / 2, y = b * block + block / 2
                    let px = result.rgba16 + (y * stride + x) * 4
                    let o = ((b * n + g) * n + r) * 4
                    cube[o] = Float(px[0]) / 65535
                    cube[o + 1] = Float(px[1]) / 65535
                    cube[o + 2] = Float(px[2]) / 65535
                }
            }
        }
        return cube.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private func screenImage(_ image: CIImage) -> UIImage? {
        let s = min(1, Self.displayEdge / max(image.extent.width, image.extent.height))
        let scaled = image.transformed(by: .init(scaleX: s, y: s))
        return context.createCGImage(scaled, from: scaled.extent, format: .RGBA8, colorSpace: Self.displayP3)
            .map { UIImage(cgImage: $0) }
    }

    /// Sorted keys, so equal settings give equal strings (`lastPrintKey`).
    private func json(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: .sortedKeys), as: UTF8.self)
    }
}
