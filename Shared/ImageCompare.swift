import CoreGraphics
import Foundation
import ImageIO

/// Compares two images at low resolution in grayscale. Returns similarity 0...1
/// (1 = identical), robust to scaling and compression noise.
public enum ImageCompare {
    public static func similarity(_ a: String, _ b: String, width: Int = 160, height: Int = 100) -> Double? {
        guard let pa = gray(a, width, height), let pb = gray(b, width, height) else { return nil }
        var diff = 0
        for i in 0..<pa.count { diff += abs(Int(pa[i]) - Int(pb[i])) }
        return 1 - Double(diff) / Double(pa.count * 255)
    }

    static func gray(_ path: String, _ w: Int, _ h: Int) -> [UInt8]? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        var px = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return px
    }
}
