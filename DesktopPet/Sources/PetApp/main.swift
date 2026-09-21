import AppKit

// 单实例由 macOS 保证，不需要旧版 Electron 那套 requestSingleInstanceLock。
let app = NSApplication.shared
let coordinator = AppCoordinator()
app.delegate = coordinator
app.run()
