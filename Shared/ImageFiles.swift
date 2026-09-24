import Foundation
import ImageIO
import UniformTypeIdentifiers
import UIKit
import CoreImage
import os

enum ImageFiles {
    struct PixelDimensions: Equatable {
        let width: Int64
        let height: Int64

        var megapixels: Double { Double(width) * Double(height) / 1_000_000 }
        func isSmallerThan(_ source: PixelDimensions) -> Bool {
            width < source.width || height < source.height
        }
    }
    static let maxInputBytes = 25 * 1024 * 1024
    // PNG conversion and EXIF bake-in decode pixels. Keep that allocation suitable for an extension.
    // A 24 MP decode can require ~96 MB for one RGBA buffer. Upright JPEGs
    // take the byte-for-byte copy path below and do not consume this budget.
    static let maxRenderedPixels: Int64 = 24_000_000
    private static let logger = Logger(subsystem: "PhotoServer", category: "ImagePipeline")

    static func pixelDimensions(_ url: URL) throws -> PixelDimensions {
        let properties = CGImageSourceCopyPropertiesAtIndex(try source(url), 0, nil) as? [CFString: Any] ?? [:]
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.int64Value ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.int64Value ?? 0
        guard width > 0, height > 0, width <= Int64(Int.max) / height else {
            throw PhotoError.message("The image has invalid pixel dimensions.")
        }
        return PixelDimensions(width: width, height: height)
    }

    static func orientedPixelDimensions(_ url: URL, orientation: Int32) throws -> PixelDimensions {
        let dimensions = try pixelDimensions(url)
        guard (1...8).contains(orientation) else { throw PhotoError.message("The source image has an invalid orientation.") }
        if (5...8).contains(orientation) {
            return PixelDimensions(width: dimensions.height, height: dimensions.width)
        }
        return dimensions
    }

    static func logDimensions(_ boundary: String, at url: URL) {
        guard let dimensions = try? pixelDimensions(url) else {
            logger.debug("Image boundary \(boundary, privacy: .public): dimensions unavailable")
            return
        }
        logger.debug("Image boundary \(boundary, privacy: .public): \(dimensions.width, privacy: .public)x\(dimensions.height, privacy: .public)")
    }
    static func source(_ url: URL) throws -> CGImageSource {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { throw PhotoError.message("The image cannot be decoded completely.") }
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
    static func prepareUprightJPEG(from image: URL, orientation: Int32, to destination: URL) throws {
        logDimensions("Photos source", at: image)
        guard (1...8).contains(orientation) else { throw PhotoError.message("The source image has an invalid orientation.") }
        let source = try source(image)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.int64Value ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.int64Value ?? 0
        guard width > 0, height > 0, width <= Int64(Int.max) / height else {
            throw PhotoError.message("The source image has invalid pixel dimensions.")
        }
        guard let cg = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw PhotoError.message("The source image cannot be rendered for upload.")
        }
        let oriented = CIImage(cgImage: cg).oriented(forExifOrientation: orientation)
        let extent = oriented.extent.integral
        guard extent.width > 0, extent.height > 0 else { throw PhotoError.message("The source image has invalid oriented dimensions.") }
        guard let space = cg.colorSpace.flatMap({ $0.model == .rgb ? $0 : nil }) ?? CGColorSpace(name: CGColorSpace.sRGB) else {
            throw PhotoError.message("Cannot determine a color space for the source photograph.")
        }
        let context = CIContext(options: [.cacheIntermediates: false])
        let flattened = oriented.composited(over: CIImage(color: .white)).cropped(to: extent)
        guard let upright = context.createCGImage(flattened, from: extent, format: .RGBX8, colorSpace: space),
              let writer = CGImageDestinationCreateWithURL(destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw PhotoError.message("Cannot prepare an upright source photograph for upload.")
        }
        CGImageDestinationAddImage(writer, upright, [kCGImageDestinationLossyCompressionQuality: 0.92, kCGImagePropertyOrientation: 1] as CFDictionary)
        guard CGImageDestinationFinalize(writer) else { throw PhotoError.message("Cannot encode the upright source photograph.") }
        logDimensions("Normalized upload", at: destination)
        let bytes = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard bytes > 0, bytes <= maxInputBytes else { throw PhotoError.message("The upright source must be at most 25 MiB.") }
    }
    static func prepareJPEG(from result: URL, to destination: URL) throws {
        let source = try source(result)
        let mime = try mime(result)
        guard mime == "image/jpeg" || mime == "image/png" else { throw PhotoError.message("The server must return PNG or JPEG.") }
        let dimensions = try pixelDimensions(result)
        let width = dimensions.width, height = dimensions.height
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.int32Value ?? 1
        logDimensions("Gemini response", at: result)
        if mime == "image/jpeg" && orientation == 1 {
            try FileManager.default.copyItem(at: result, to: destination)
        } else {
            guard width <= maxRenderedPixels / height else {
                throw PhotoError.message("The returned image exceeds the 24 MP extension rendering budget. It has not been resized or saved.")
            }
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
        logDimensions("Prepared Photos output", at: destination)
    }
}
