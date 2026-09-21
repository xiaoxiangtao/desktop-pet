import Foundation
import PetCore

/// 定位本 target 所在 bundle 用的标记类，见 `ResourceBundle`。
final class PetAnimationAnchor: ResourceAnchor {}
import CoreGraphics

/// `cat-anim.json` 的模型。由 `code/调试脚本/build_cat_sprite_sheets.py` 生成，不要手改。
///
/// 两张雪碧图共用一个画布盒（`petBox` 382×387）：`poses` 是 16 个手绘关键姿势
/// （坐/眨眼/wink/哈欠/坐→睡那串），`sleepBreath` 是呼吸循环，裁到睡着的猫占的那条下半带，
/// 因此它自带 `offsetX/offsetY`，渲染时要按这个偏移贴回画布盒里。
///
/// **渲染端按帧名索引，不按下标**——素材重新生成时帧顺序可能变，按名字取才不会错位。
public struct SpriteManifest: Codable, Sendable {
    public struct Box: Codable, Sendable {
        public let width: Double
        public let height: Double
    }

    public struct Sheet: Codable, Sendable {
        public let image: String          // 相对路径，如 "sprites/cat-poses.webp"
        public let frameWidth: Double
        public let frameHeight: Double
        public let columns: Int
        public let offsetX: Double
        public let offsetY: Double
        public let frames: [String]

        /// 第 `index` 帧在雪碧图里的左上角像素坐标。
        public func origin(of index: Int) -> (x: Double, y: Double) {
            let row = index / columns, col = index % columns
            return (Double(col) * frameWidth, Double(row) * frameHeight)
        }

        public func index(of frame: String) -> Int? { frames.firstIndex(of: frame) }

        public var rows: Int { Int(ceil(Double(frames.count) / Double(columns))) }

        /// 第 `index` 帧在整张 sheet 里的归一化矩形，供 `CALayer.contentsRect` 使用。
        ///
        /// **`contentsRect` 的 y 轴是下原点**，而雪碧图的行是从上往下数的，两者相反，
        /// 必须翻一次：`y = (rows - 1 - row) / rows`。
        ///
        /// 这条搞反的后果不是"差一点"，而是整张图上下镜像——4 行的 poses 图里
        /// 第 0 行(sit 端坐)会被画成第 3 行(lying-head-up 趴着抬头)，
        /// 于是**每一个动作看起来都不对**，而状态机日志一切正常，极难从代码上看出来。
        /// 2026-09-14 实测踩到：用户截图里气泡开着而猫趴着，对照裁图才定位。
        public func unitRect(of index: Int) -> CGRect {
            let row = index / columns, col = index % columns
            let w = 1.0 / Double(columns), h = 1.0 / Double(rows)
            return CGRect(x: Double(col) * w, y: Double(rows - 1 - row) * h, width: w, height: h)
        }

        /// 文件名（不含目录），用于从 bundle 里取资源——manifest 里的 `image` 带着
        /// 前端的 `sprites/` 目录前缀，SwiftPM 的 bundle 是扁平的。
        public var imageName: String { (image as NSString).lastPathComponent }
    }

    public struct Sheets: Codable, Sendable {
        public let poses: Sheet
        public let sleepBreath: Sheet
    }

    public let petBox: Box
    public let sheets: Sheets

    /// 源画布到屏幕的缩放。猫本体在 387 的盒子里约 379px 高，0.42 让它在桌面上约 160px。
    /// 与前端 `sprite-pet.tsx` 的 `SCALE` 必须一致，否则气泡锚点和拖拽夹取都会偏。
    public static let scale: Double = 0.42

    public var displayWidth: Double { petBox.width * Self.scale }
    public var displayHeight: Double { petBox.height * Self.scale }

    /// 素材所在的 bundle。
    ///
    /// **不用 `Bundle.module`**：它的查找顺序随工具链变，旧工具链生成的那版不看
    /// `.app/Contents/Resources/`，结果是本机构建正常、CI 构建的包一启动就
    /// fatalError。理由详见 `ResourceBundle`。
    public static let resourceBundle: Bundle =
        ResourceBundle.named("DesktopPet_PetAnimation", anchor: PetAnimationAnchor.self)
        ?? Bundle(for: PetAnimationAnchor.self)

    public static func load() throws -> SpriteManifest { try load(from: resourceBundle) }

    public static func load(from bundle: Bundle) throws -> SpriteManifest {
        guard let url = bundle.url(forResource: "cat-anim", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(SpriteManifest.self, from: Data(contentsOf: url))
    }
}
