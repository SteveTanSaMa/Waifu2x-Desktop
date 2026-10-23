import AppKit
import ImageIO
import UniformTypeIdentifiers

/// ImageIO applies EXIF orientation before the inference engine sees pixels.
/// The working format is 8-bit sRGB PNG; source files are never modified.
enum ImageCodec {
    static let maxOutputPixels = 900_000_000

    /// Divide the budget instead of multiplying untrusted dimensions, avoiding
    /// overflow while accepting images exactly at the output limit.
    static func validateOutputDimensions(width: Int, height: Int, scale: Int) throws {
        guard width > 0, height > 0, scale > 0,
              width <= maxOutputPixels / height / scale / scale else {
            throw AppFailure.message(L("输出将超过 9 亿像素。请降低放大倍数，或先裁小原图。"))
        }
    }

    static func load(_ url: URL, workingDirectory: URL) throws -> ImageAsset {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            throw AppFailure.message(L("无法打开这张图片。请选择 PNG、JPEG、HEIC、TIFF 或 WebP 静态图片。"))
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let oriented = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let context = CGContext(data: nil, width: oriented.width, height: oriented.height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AppFailure.message(L("无法解码图片。"))
        }
        context.draw(oriented, in: CGRect(x: 0, y: 0, width: oriented.width, height: oriented.height))
        guard let image = context.makeImage() else { throw AppFailure.message(L("无法读取图片像素。")) }
        let normalized = workingDirectory.appendingPathComponent("input-\(UUID().uuidString).png")
        try writePNG(image, to: normalized)
        return ImageAsset(url: normalized, image: image, name: url.lastPathComponent)
    }

    static func flattenToWhite(_ image: CGImage) throws -> CGImage {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw AppFailure.message(L("无法创建白色背景图片。"))
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.fill(rect); context.draw(image, in: rect)
        return context.makeImage()!
    }

    static func readPNG(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw AppFailure.message(L("处理引擎未生成有效图片。请重新尝试。"))
        }
        return image
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw AppFailure.message(L("无法创建 PNG 文件。"))
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw AppFailure.message(L("保存图片失败，请检查磁盘空间与文件权限。")) }
    }
}
