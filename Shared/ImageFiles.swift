import Foundation
import ImageIO
import UniformTypeIdentifiers
import UIKit
import CoreImage

enum ImageFiles {
    static let maxInputBytes = 25 * 1024 * 1024
    static func source(_ url: URL) throws -> CGImageSource {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { throw PhotoError.message("The image cannot be decoded.") }
        return source
    }
    static func mime(_ url: URL) throws -> String {
        let source = try source(url)
        guard let type = CGImageSourceGetType(source), let mime = UTType(type as String)?.preferredMIMEType,
              ["image/jpeg", "image/png", "image/heic", "image/heif"].contains(mime) else {
            throw PhotoError.message("Only JPEG, PNG, HEIC and HEIF still photographs are supported.")
        }
        return mime
    }
    static func preview(_ url: URL) throws -> UIImage {
        let source = try source(url)
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 1400]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw PhotoError.message("Cannot prepare preview.") }
        return UIImage(cgImage: image)
    }
    static func prepareJPEG(from result: URL, to destination: URL) throws {
        let source = try source(result)
        let mime = try mime(result)
        guard mime == "image/jpeg" || mime == "image/png" else { throw PhotoError.message("The server must return PNG or JPEG.") }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.int64Value ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.int64Value ?? 0
        guard width > 0, height > 0, width * height <= 48_000_000 else {
            throw PhotoError.message("The returned image exceeds the 48 MP rendering budget. It has not been resized or saved.")
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.int32Value ?? 1
        if mime == "image/jpeg" && orientation == 1 {
            try FileManager.default.copyItem(at: result, to: destination)
        } else {
            guard let writer = CGImageDestinationCreateWithURL(destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw PhotoError.message("Cannot prepare the Photos output file.")
            }
            // Photos requires physically upright pixels, not just an EXIF rotation flag.
            if orientation == 1 {
                CGImageDestinationAddImageFromSource(writer, source, 0, [kCGImageDestinationLossyCompressionQuality: 1.0, kCGImagePropertyOrientation: 1] as CFDictionary)
            } else {
                guard let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw PhotoError.message("Cannot decode result orientation.") }
                let oriented = CIImage(cgImage: cg).oriented(forExifOrientation: orientation)
                let space = cg.colorSpace?.model == .rgb ? cg.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
                let context = CIContext(options: [.cacheIntermediates: false])
                guard let upright = context.createCGImage(oriented, from: oriented.extent, format: .RGBA8, colorSpace: space) else { throw PhotoError.message("Cannot render upright result.") }
                CGImageDestinationAddImage(writer, upright, [kCGImageDestinationLossyCompressionQuality: 1.0, kCGImagePropertyOrientation: 1] as CFDictionary)
            }
            guard CGImageDestinationFinalize(writer) else { throw PhotoError.message("Cannot encode the Photos result.") }
        }
    }
}
