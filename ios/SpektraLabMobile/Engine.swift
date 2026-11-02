//  Engine.swift — the engine's C ABI for the phone: one engine, one open frame.
//
//  The Mac app's EngineClient + ImageDecoder cut to what this app uses. Same
//  conventions: float32 linear ProPhoto in, top row first, through a shared
//  MTLBuffer (`spk_open_device`); ProPhoto RGB (ROMM-encoded) RGBA16 out.

import CoreImage
import Foundation
import Metal

struct EngineError: LocalizedError {
    let errorDescription: String?
}

actor Engine {
    static let shared = Engine()

    // ponytail: input capped at 12 MP so a 48 MP ProRAW fits the phone's memory
    // limit; raise once the increased-memory-limit entitlement and striped
    // renders are measured on a device.
    static let maxInputPixels = 12_000_000.0

    let device = MTLCreateSystemDefaultDevice()!
    private lazy var context = CIContext(mtlDevice: device, options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!,
        .workingFormat: CIFormat.RGBAh,
        .cacheIntermediates: false,
        .highQualityDownsample: true,
    ])
    private var engine: OpaquePointer?
    private var session: OpaquePointer?

    /// Linear ROMM, as in the Mac app's `ImageDecoder.linearProPhoto`:
    /// Core Graphics ships ROMM only at gamma 1.8.
    private static let linearProPhoto: CGColorSpace = {
        let d50: [CGFloat] = [0.9642, 1.0000, 0.8249]
        let black: [CGFloat] = [0, 0, 0]
        let gamma: [CGFloat] = [1, 1, 1]
        let m: [CGFloat] = [0.7976749, 0.2880402, 0.0000000,
                            0.1351917, 0.7118741, 0.0000000,
                            0.0313534, 0.0000857, 0.8252100]
        return CGColorSpace(calibratedRGBWhitePoint: d50, blackPoint: black, gamma: gamma, matrix: m)!
    }()
    /// What the engine writes: ProPhoto primaries with their own transfer function.
    static let outputSpace = CGColorSpace(name: CGColorSpace.rommrgb)!

    private func fail(_ engine: OpaquePointer?) -> EngineError {
        EngineError(errorDescription: String(cString: spk_last_error(engine)))
    }

    private func started() throws -> OpaquePointer {
        if let engine { return engine }
        let path = Bundle.main.resourceURL!.appendingPathComponent("engine").path
        guard let e = spk_engine_create(path, Unmanaged.passUnretained(device).toOpaque()) else {
            throw fail(nil)
        }
        engine = e
        return e
    }

    /// Decode `data` (RAW/DNG through CIRAWFilter with Apple's tone rendering
    /// off, anything else through Core Image as-is) and open it as the session.
    func open(_ data: Data, params: [String: Any]) throws {
        let engine = try started()
        if let session { spk_session_release(session); self.session = nil }

        let image: CIImage
        if let raw = CIRAWFilter(imageData: data, identifierHint: nil) {
            raw.isDraftModeEnabled = false
            raw.boostAmount = 0
            raw.boostShadowAmount = 0
            raw.isGamutMappingEnabled = false
            raw.localToneMapAmount = 0
            raw.extendedDynamicRangeAmount = 0
            guard let out = raw.outputImage else { throw EngineError(errorDescription: "RAW decode failed") }
            image = out
        } else if let flat = CIImage(data: data, options: [.applyOrientationProperty: true]) {
            image = flat
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
        let handle = try json(params).withCString { delta in
            withUnsafePointer(to: &input) { spk_open_device(engine, $0, delta, &reply) }
        }
        if let reply { spk_string_free(reply) }
        guard let handle else { throw fail(engine) }
        session = handle
    }

    /// Apply `delta`, then print. `film` false reuses the cached negative
    /// (only the paper side changed), as the Mac app's reprint does.
    func render(_ delta: [String: Any], film: Bool) throws -> (CGImage, Double) {
        guard let session else { throw EngineError(errorDescription: "No photo open") }
        if !delta.isEmpty {
            var out: UnsafeMutablePointer<CChar>?
            let status = try json(delta).withCString { spk_set_params(session, $0, &out) }
            if let out { spk_string_free(out) }
            guard status == SPK_OK else { throw fail(engine) }
        }
        var result = spk_result()
        let status = film ? spk_render(session, "full", &result) : spk_reprint(session, "full", &result)
        guard status == SPK_OK else { throw fail(engine) }
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
        return (cg, result.elapsed_ms)
    }

    /// Display P3 HEIC for the photo library, converted once from ProPhoto.
    func heic(_ image: CGImage) throws -> Data {
        guard let data = context.heifRepresentation(of: CIImage(cgImage: image), format: .RGBA8,
                                                    colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!, options: [:])
        else { throw EngineError(errorDescription: "HEIC encode failed") }
        return data
    }

    private func json(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
}
