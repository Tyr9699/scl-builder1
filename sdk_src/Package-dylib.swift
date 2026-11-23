// swift-tools-version:5.8
// 专门用于构建成品 .dylib 的 SwiftPM 清单（动态库产物，含 OC constructor 入口）
import PackageDescription

let package = Package(
  name: "SCLAlertView",
  platforms: [.iOS(.v13)],
  products: [
    .library(name: "SCLAlertView", type: .dynamic, targets: ["SCLAlertView"]),
  ],
  targets: [
    .target(
      name: "SCLAlertView",
      path: "SCLAlertView",
      exclude: ["Info.plist"],
      publicHeadersPath: "include"
    ),
  ]
)
