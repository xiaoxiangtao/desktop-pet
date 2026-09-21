import Foundation

/// 自己找资源 bundle，不用 SwiftPM 生成的 `Bundle.module`。
///
/// **为什么不能用 `Bundle.module`**：它是每个 target 编译期生成的一小段代码，
/// 而**不同版本的工具链生成的查找顺序不一样**。实测 Swift 6.3 的版本只看
/// `Bundle.main.bundleURL`（也就是 `.app` 目录本身）和编译期写死的构建目录，
/// 不看 `Bundle.main.resourceURL`（`.app/Contents/Resources/`）。于是：
///
/// - 用新工具链在本机构建 → 正常；
/// - 用旧工具链在 CI 构建 → 装好的 app **一启动就 fatalError**（"could not load
///   resource bundle"），而 CI 全绿、DMG 照出。
///
/// 而把 bundle 挪到 `.app` 根目录去迎合旧访问器是不行的：那会让 codesign 报
/// `unsealed contents present in the bundle root`，签名直接失效。
///
/// 所以资源按 macOS 的规矩放在 `Contents/Resources/`，查找逻辑自己写。
/// 这段代码不随工具链变化，也就不会再出现"本机好好的、发出去就崩"。
public enum ResourceBundle {
    /// 按 bundle 名找，找不到返回 nil——**不 fatalError**。
    /// 调用方自己决定怎么降级：精灵素材缺了确实没法继续，但词表缺了只是判定退化，
    /// 这个决定不该由一段生成代码替所有人做。
    public static func named(_ name: String, anchor: AnyClass) -> Bundle? {
        let fileName = name.hasSuffix(".bundle") ? name : name + ".bundle"
        // 顺序有意：先 .app/Contents/Resources（我们组装 .app 时放的位置），
        // 再 framework 内嵌，最后才是裸二进制旁边（`swift run` 的情形）。
        let roots: [URL?] = [
            Bundle.main.resourceURL,
            Bundle(for: anchor).resourceURL,
            Bundle(for: anchor).bundleURL.deletingLastPathComponent(),
            Bundle.main.bundleURL,
            Bundle.main.executableURL?.deletingLastPathComponent(),
        ]
        for root in roots.compactMap({ $0 }) {
            if let bundle = Bundle(url: root.appendingPathComponent(fileName)) { return bundle }
        }
        // 同一个 target 的资源也可能直接摊在宿主 bundle 里（没有单独打成 .bundle），
        // 这时宿主自己就是答案。
        return Bundle(for: anchor)
    }
}

/// `Bundle(for:)` 要一个类，而这几个 target 里全是 struct / enum。
/// 每个带资源的 target 各自建一个这样的标记类，用来定位"我这段代码在哪个 bundle 里"。
open class ResourceAnchor {}
