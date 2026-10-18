import CoreGraphics
import CoreImage
import Foundation

/// QR rendering with CoreImage. Modules are scaled by an integer factor with nearest-neighbour sampling so
/// edges stay crisp, and a four-module quiet zone is added. Always black on white so it scans in dark mode.
public enum QRCode {
    public struct Rendered: Sendable {
        public let image: CGImage
        /// Modules per side including the quiet zone.
        public let modules: Int
        /// Pixels per module.
        public let scale: Int
    }

    public static let quietZone = 4

    /// Renders `text` so that the image is at most `maxPixels` wide, using the largest integer module scale.
    public static func render(_ text: String, maxPixels: Int = 400) -> Rendered? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let raw = filter.outputImage else { return nil }
        let side = Int(raw.extent.width.rounded())
        guard side > 0 else { return nil }
        let modules = side + 2 * quietZone
        let scale = max(1, maxPixels / modules)
        let pixels = modules * scale
        let big = raw
            .samplingNearest()
            .transformed(by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
            .transformed(by: CGAffineTransform(translationX: CGFloat(quietZone * scale), y: CGFloat(quietZone * scale)))
        let white = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        let composed = big.composited(over: white).cropped(to: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        let context = CIContext(options: [.useSoftwareRenderer: true])
        guard let cg = context.createCGImage(composed, from: composed.extent, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        else { return nil }
        return Rendered(image: cg, modules: modules, scale: scale)
    }

    /// Decodes the first QR code found in `image`; used to prove a rendering round-trips.
    public static func decode(_ image: CGImage) -> String? {
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        let features = detector?.features(in: CIImage(cgImage: image)) ?? []
        return features.compactMap { ($0 as? CIQRCodeFeature)?.messageString }.first
    }
}
