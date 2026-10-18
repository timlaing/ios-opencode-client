import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// W08 photo pipeline (docs/implementation-defaults.md): Balanced copies
/// fit to the 2048-pixel longest edge WITHOUT upscaling, JPEG quality
/// 0.85 for opaque photographic images, alpha preserved as PNG. Location
/// metadata is stripped from generated copies unless explicitly kept —
/// re-encoding carries GPS only when asked to. Original mode returns the
/// picked bytes untouched (no stripping is ever claimed for them).
enum PhotoPreparation {
    enum PipelineError: Error {
        case unreadable
        case encodeFailed
    }

    static func prepare(
        data: Data,
        mode: AttachmentLibrary.PhotoCopy,
        includeLocation: Bool
    ) throws -> (bytes: Data, mimeType: String) {
        if mode == .original {
            // Byte-for-byte as picked; the mime is sniffed from the real
            // bytes, never trusted from the picker's label.
            return (data, MimeType.sniff(data))
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  // Bake the EXIF orientation into the pixels: encode
                  // writes no orientation tag, so without the transform
                  // portrait captures would reach the host rotated.
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 2048,
              ] as CFDictionary)
        else {
            throw PipelineError.unreadable
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        return try encode(image: image, sourceProperties: properties, includeLocation: includeLocation)
    }

    /// Camera captures arrive as an already-decoded image (their JPEG is
    /// the "original"); the same Balanced/Original rules apply.
    static func prepare(
        image: UIImage,
        mode: AttachmentLibrary.PhotoCopy,
        includeLocation: Bool
    ) throws -> (bytes: Data, mimeType: String) {
        // `cgImage` pixels are stored UNROTATED — the orientation lives
        // only in `imageOrientation`, which encoding would drop. Drawing
        // the image bakes the orientation into the pixels first.
        guard image.size.width > 0, image.size.height > 0 else { throw PipelineError.unreadable }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        let oriented = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        guard let cgImage = oriented.cgImage else { throw PipelineError.unreadable }
        if mode == .original {
            return try encode(image: cgImage, sourceProperties: [:], includeLocation: false)
        }
        let longest = max(cgImage.width, cgImage.height)
        let scaled: CGImage
        if longest > 2048 {
            let ratio = 2048.0 / Double(longest)
            let target = CGSize(width: CGFloat(cgImage.width) * ratio, height: CGFloat(cgImage.height) * ratio)
            let renderer = UIGraphicsImageRenderer(size: target)
            let rendered = renderer.image { _ in
                UIImage(cgImage: cgImage).draw(in: CGRect(origin: .zero, size: target))
            }
            guard let downscaled = rendered.cgImage else { throw PipelineError.encodeFailed }
            scaled = downscaled
        } else {
            scaled = cgImage
        }
        return try encode(image: scaled, sourceProperties: [:], includeLocation: false)
    }

    private static func encode(
        image: CGImage,
        sourceProperties: [CFString: Any],
        includeLocation: Bool
    ) throws -> (bytes: Data, mimeType: String) {
        // Preserve transparency: alpha-bearing images re-encode as PNG.
        let hasAlpha: Bool = switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
        let mimeType = hasAlpha ? "image/png" : "image/jpeg"
        let type = (hasAlpha ? UTType.png : UTType.jpeg).identifier as CFString
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else {
            throw PipelineError.encodeFailed
        }
        var properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.85,
        ]
        // The destination carries ONLY the properties passed here, so
        // GPS is stripped by default and re-attached only on request.
        if includeLocation, let gps = sourceProperties[kCGImagePropertyGPSDictionary] {
            properties[kCGImagePropertyGPSDictionary] = gps
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PipelineError.encodeFailed }
        return (data as Data, mimeType)
    }
}

/// Magic-byte MIME sniffing: the routing rule keys on the REAL content —
/// a label from a picker or the filesystem can lie, the bytes cannot.
enum MimeType {
    static func sniff(_ data: Data) -> String {
        guard data.count >= 4 else { return "application/octet-stream" }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if data.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "image/gif" }
        if data.starts(with: [0x25, 0x50, 0x44, 0x46]) { return "application/pdf" }
        if data.count >= 12,
           data.starts(with: [0x52, 0x49, 0x46, 0x46]),
           data[8] == 0x57, data[9] == 0x45, data[10] == 0x42, data[11] == 0x50 {
            return "image/webp"
        }
        return "application/octet-stream"
    }
}
