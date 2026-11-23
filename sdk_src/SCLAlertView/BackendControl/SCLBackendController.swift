//
//  SCLBackendController.swift
//  SCLAlertView - BackendControl
//
//  一行接入的统一门面：冷启动拉取配置 → 按优先级处理禁用 / 升级 / 公告 / 按钮。
//
//  使用示例（AppDelegate）：
//      let opts = SCLRemoteConfigOptions(
//          configURL: URL(string: "https://your.server.com/api/app/config")!,
//          activationURL: URL(string: "https://your.server.com/api/app/activate"),
//          hmacSecret: "your-hmac-secret",
//          pollInterval: 300
//      )
//      SCLBackendController.shared.configure(opts)
//      SCLBackendController.shared.bootstrap(on: window)
//

import Foundation
import UIKit

open class SCLBackendController {

    public static let shared = SCLBackendController()

    public let remote = SCLRemoteConfigManager.shared
    public let ui = SCLBackendUI.shared

    /// 业务层可注入：远程按钮里 type=custom 的处理
    public var actionHandler: SCLRemoteActionHandler? {
        set { ui.actionHandler = newValue }
        get { ui.actionHandler }
    }

    private var window: UIWindow?
    private var didBootstrap = false

    public init() {}

    public func configure(_ options: SCLRemoteConfigOptions) {
        remote.options = options
    }

    /// 从 bundle 里的 SCLConfig.plist 自动读取域名 / appId / 密钥完成配置。
    /// 客户只需把后台生成的 SCLConfig.plist 放进 App 主 bundle 或动态库 bundle，调用本方法即可。
    /// 查找顺序：主 bundle → 动态库 bundle（SCLAlertView.framework）→ 沙盒 Documents。
    @discardableResult
    public func autoConfigureFromBundle(plistName: String = "SCLConfig") -> Bool {
        // 0) 后台固化到动态库里的配置（最高优先级：客户拿到的库已内置域名/密钥）
        if SCLCustomerConfig.isEmbedded,
           let url = URL(string: SCLCustomerConfig.configURL) {
            remote.options = SCLRemoteConfigOptions(
                configURL: url,
                activationURL: URL(string: SCLCustomerConfig.activateURL),
                hmacSecret: SCLCustomerConfig.hmacSecret,
                pollInterval: SCLCustomerConfig.pollInterval,
                timeout: 15,
                appId: SCLCustomerConfig.appID
            )
            return true
        }

        var dict: [String: Any]?

        // 1) 主 bundle
        if let url = Bundle.main.url(forResource: plistName, withExtension: "plist"),
           let d = NSDictionary(contentsOf: url) as? [String: Any] {
            dict = d
        }
        // 2) SCLAlertView 所在 bundle
        if dict == nil, let url = Bundle(for: SCLAlertView.self).url(forResource: plistName, withExtension: "plist"),
           let d = NSDictionary(contentsOf: url) as? [String: Any] {
            dict = d
        }
        // 3) 沙盒 Documents（方便后台热更新配置包而无需重新打包）
        if dict == nil, let doc = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let url = doc.appendingPathComponent(plistName + ".plist")
            if let d = NSDictionary(contentsOf: url) as? [String: Any] { dict = d }
        }

        guard let d = dict,
              let urlString = d["SCLConfigURL"] as? String,
              let configURL = URL(string: urlString) else { return false }

        let activationURL: URL? = {
            if let s = d["SCLActivateURL"] as? String, !s.isEmpty { return URL(string: s) }
            return nil
        }()
        let appId = d["SCLAppID"] as? String
        let secret = (d["SCLHMACSecret"] as? String) ?? ""
        let interval: TimeInterval = {
            if let n = d["SCLPollInterval"] as? NSNumber { return n.doubleValue }
            return 300
        }()

        remote.options = SCLRemoteConfigOptions(
            configURL: configURL,
            activationURL: activationURL,
            hmacSecret: secret,
            pollInterval: interval,
            timeout: 15,
            appId: appId
        )
        return true
    }

    /// 冷启动入口：优先用缓存立即渲染，随后拉取最新配置并按优先级处理
    public func bootstrap(on window: UIWindow?) {
        self.window = window
        guard !didBootstrap else { return }
        didBootstrap = true

        // 1) 先用缓存配置快速判断禁用状态
        if let cached = remote.cachedConfig {
            apply(cached, animated: false)
        }

        // 2) 拉取最新配置
        remote.fetchConfig { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let config):
                self.apply(config, animated: true)
            case .failure:
                break // fetchConfig 内部已回退缓存
            }
        }

        if remote.options?.pollInterval ?? 0 > 0 {
            remote.startPolling()
        }

        // 3) 配置更新监听（轮询时变化实时生效）
        _ = remote.addConfigListener { [weak self] config in
            self?.apply(config, animated: true)
        }
    }

    /// 按优先级应用配置：禁用 > 强制升级 > 公告 > 远程按钮
    public func apply(_ config: SCLRemoteConfig, animated: Bool) {
        // disabled=true 时不做去重，保证每次启动都会拦截
        if !config.disabled && config.signingPayload == remote.lastAppliedConfigKey { return }
        remote.markApplied(config)

        DispatchQueue.main.async {
            if config.disabled {
                self.ui.showDisabledOverlay(config: config, window: self.window)
                return
            }
            if self.remote.isBuildBlocked(config) {
                self.ui.showForceUpdateIfNeeded(config: config, manager: self.remote, window: self.window)
                return
            }
            self.ui.showAnnouncementIfNeeded(config: config, window: self.window)
            self.ui.showRemoteButtons(config: config, manager: self.remote, window: self.window)
        }
    }

    /// 手动弹出激活码窗口
    public func presentActivation(onResult: ((Result<SCLActivationResponse, Error>) -> Void)? = nil) {
        ui.showActivationDialog(manager: remote, window: window, onResult: onResult)
    }

    /// 当前用户等级
    public var tier: SCLUserTier { remote.currentTier }

    /// 判断某功能是否对当前等级开放（业务代码可直接用）
    public func isFeatureAllowed(_ minTier: SCLUserTier) -> Bool {
        tier.rank >= minTier.rank
    }
}
