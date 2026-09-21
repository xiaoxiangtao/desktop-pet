import Foundation
import CoreGraphics
import ImageIO

/// 雪碧图的逐像素 alpha 采样，用于命中测试：猫身上不透明的地方才吃点击，
/// 透明边角穿透到下层应用。
///
/// 放在 PetAnimation 而不是 AppKit 层，是为了让"点猫的边角会不会误吃点击"这件事
/// **可以被测试**——它是本次重构 UI 层的核心收益之一（旧版 Electron 只能整窗二选一穿透），
/// 而视觉验收又恰恰是最难自动化的部分，能测就别留给肉眼。
///
/// CoreGraphics/ImageIO 不是 AppKit，不违反 PetKit 的分层规则。
public struct SpriteAlpha: Sendable {
    public let image: CGImage
    /// alpha 低于此值视为"不在猫身上"。取 0.1 而非 0：素材边缘有羽化，
    /// 用纯 0 会让边缘出现一圈肉眼看着在猫身上、却点不中的死区。
    public static let hitThreshold: CGFloat = 0.1

    public init(image: CGImage) { self.image = image }

    public init(bundleResource name: String, in bundle: Bundle = SpriteManifest.resourceBundle) throws {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        guard let url = bundle.url(forResource: base, withExtension: ext),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CocoaError(.fileNoSuchFile)
        }
        self.image = image
    }

    /// 采样整张 sheet 上 (x, y) 处的 alpha。左上原点，越界返回 0。
    ///
    /// 每次点击只读 1 个像素，所以裁一张 1×1 再画，比自己维护整张位图缓存省事得多
    /// （整张 poses 是 1528×1548 RGBA ≈ 9.5MB，为一次点击常驻不值得）。
    public func alpha(x: Int, y: Int) -> CGFloat {
        guard x >= 0, y >= 0, x < image.width, y < image.height,
              let cropped = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return 0 }
        var pixel: [UInt8] = [0, 0, 0, 0]
        guard let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return CGFloat(pixel[3]) / 255
    }

    /// 采样某一帧内的 (fx, fy)（帧内像素坐标，左上原点）。
    public func alpha(inFrame index: Int, of sheet: SpriteManifest.Sheet, fx: Double, fy: Double) -> CGFloat {
        let origin = sheet.origin(of: index)
        return alpha(x: Int(origin.x + fx), y: Int(origin.y + fy))
    }

    public func isHit(inFrame index: Int, of sheet: SpriteManifest.Sheet, fx: Double, fy: Double) -> Bool {
        alpha(inFrame: index, of: sheet, fx: fx, fy: fy) >= Self.hitThreshold
    }
}
