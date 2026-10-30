// swift-tools-version: 5.10
// p2b 随手记：Mac 上的悬浮小宠物、⌃⌥空格 随手记一句、待办同步到"提醒事项"。从 Idea2do 的桌面端移植，记下的东西存在
// paper2brain 服务器的随手记里（网页侧栏「随手记」）。构建：mac/build.sh。
import PackageDescription

let package = Package(
    name: "P2BJot",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "P2BJot", path: "Sources/P2BJot")]
)
