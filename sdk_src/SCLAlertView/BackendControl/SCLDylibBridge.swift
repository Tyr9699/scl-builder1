//
//  SCLDylibBridge.swift
//  SCLAlertView - dylib 自动运行桥接
//
//  dylib 被加载/注入后，由 SCLDylibEntry.m 的 constructor 调用本桥接，
//  自动完成后台对接并按配置弹窗，客户无需写任何代码。
//

import Foundation
import UIKit

@objc public class SCLDylibBridge: NSObject {

    private static let shared = SCLDylibBridge()
    private var started = false
    private var didFinishObserver: NSObjectProtocol?

    /// 供 Objective-C constructor 调用
    @objc public class func sharedInstance() -> SCLDylibBridge {
        return shared
    }

    @objc public func start() {
        // 等 App 启动完成后再弹窗，避免 window 尚未就绪
        if let app = UIApplication.sharedOptional,
           app.windows.contains(where: { $0.isKeyWindow }) {
            self.go()
            return
        }

        didFinishObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didFinishLaunchingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.go()
        }

        // 兜底：某些注入时机收不到通知，延时再试一次
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.go()
        }
    }

    private func go() {
        guard !started else { return }
        guard NSClassFromString("UIApplication") != nil else { return }
        started = true

        if let obs = didFinishObserver {
            NotificationCenter.default.removeObserver(obs)
            didFinishObserver = nil
        }

        // 1) 读取固化在 dylib 里的客户配置（域名/AppID/密钥）
        SCLBackendController.shared.autoConfigureFromBundle()

        // 2) 找 keyWindow
        let win: UIWindow? = {
            if let app = UIApplication.sharedOptional {
                return app.windows.first(where: { $0.isKeyWindow }) ?? app.windows.first
            }
            return nil
        }()

        // 3) 拉配置并按优先级弹窗（禁用/升级/公告/按钮）
        SCLBackendController.shared.bootstrap(on: win)
    }
}

// iOS 13+ 场景：兼容 UIApplication.shared 的可选访问
private extension UIApplication {
    static var sharedOptional: UIApplication? {
        let sel = NSSelectorFromString("sharedApplication")
        guard UIApplication.responds(to: sel) else { return nil }
        return UIApplication.perform(sel)?.takeUnretainedValue() as? UIApplication
    }
}
