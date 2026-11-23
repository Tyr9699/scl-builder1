//
//  SCLBackendUI.swift
//  SCLAlertView - BackendControl
//
//  基于 SCLAlertView 本体的弹窗封装：公告 / 激活码输入 / 远程按钮 / 禁用 App 遮罩。
//  所有 UI 操作均切回主线程执行。
//

import Foundation
import UIKit

// MARK: - 样式工具

public extension SCLAlertViewStyle {
    init(_ string: String?) {
        switch (string ?? "").lowercased() {
        case "success", "ok":        self = .success
        case "error", "danger":      self = .error
        case "notice":               self = .notice
        case "warning", "warn":      self = .warning
        case "edit", "input":        self = .edit
        case "wait", "loading":      self = .wait
        case "question":             self = .question
        default:                     self = .info
        }
    }
}

// MARK: - 远程按钮回调

public enum SCLRemoteActionResult {
    case handled
    case needsActivation
    case custom(String)
}

public typealias SCLRemoteActionHandler = (SCLRemoteAction, SCLRemoteConfigManager) -> SCLRemoteActionResult

// MARK: - 公告已读记录

private let kShownAnnouncements = "com.sclalertview.shown_announcements"

// MARK: - 主封装

open class SCLBackendUI {

    public static let shared = SCLBackendUI()

    /// 远程按钮点击后的自定义处理器；未设置时走默认行为（打开 URL / deeplink）
    public var actionHandler: SCLRemoteActionHandler?

    public init() {}

    // MARK: 公告

    /// 展示后台公告；show_once=true 的公告同一个 id 只弹一次
    @discardableResult
    public func showAnnouncement(_ ann: SCLAnnouncement,
                                 from window: UIWindow? = nil) -> SCLAlertViewResponder? {
        guard !ann.id.isEmpty else { return nil }
        if ann.showOnce {
            var shown = UserDefaults.standard.stringArray(forKey: kShownAnnouncements) ?? []
            if shown.contains(ann.id) { return nil }
            shown.append(ann.id)
            UserDefaults.standard.set(shown, forKey: kShownAnnouncements)
        }

        let appearance = SCLAlertView.SCLAppearance(
            showCloseButton: false,
            hideWhenBackgroundViewIsTapped: false,
            buttonsLayout: .vertical
        )
        let alert = SCLAlertView(appearance: appearance)
        alert.addButton(ann.confirmTitle ?? "我知道了") {}
        return alert.showTitle(ann.title,
                               subTitle: ann.body,
                               style: SCLAlertViewStyle(ann.style),
                               animationStyle: .topToBottom,
                               window: window)
    }

    /// 按配置展示公告（内部判断是否需要弹）
    @discardableResult
    public func showAnnouncementIfNeeded(config: SCLRemoteConfig,
                                         window: UIWindow? = nil) -> SCLAlertViewResponder? {
        guard let ann = config.announcement else { return nil }
        return showAnnouncement(ann, from: window)
    }

    // MARK: 激活码输入

    /// 弹出激活码输入框，调用后台校验，按结果区分免费 / 收费
    public func showActivationDialog(manager: SCLRemoteConfigManager,
                                     window: UIWindow? = nil,
                                     onResult: ((Result<SCLActivationResponse, Error>) -> Void)? = nil) {
        let appearance = SCLAlertView.SCLAppearance(
            kTitleFont: UIFont.boldSystemFont(ofSize: 19),
            showCloseButton: true,
            shouldAutoDismiss: false,
            hideWhenBackgroundViewIsTapped: false,
            buttonsLayout: .vertical
        )
        let alert = SCLAlertView(appearance: appearance)
        let field = alert.addTextField("请输入激活码")
        field.autocapitalizationType = .allCharacters
        field.autocorrectionType = .no
        field.returnKeyType = .done

        var responder: SCLAlertViewResponder?
        let cached = manager.cachedActivation?.tier.displayName ?? "未激活"
        alert.addButton("激活（当前：\(cached)）") {
            let code = field.text ?? ""
            if code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                responder?.setSubTitle("激活码不能为空")
                return
            }
            responder?.setSubTitle("正在校验激活码…")
            manager.activate(code: code) { result in
                switch result {
                case .success(let resp):
                    if resp.valid {
                        responder?.setTitle("激活成功")
                        let expireText: String
                        if let exp = resp.expiresAt, exp > 0 {
                            let d = Date(timeIntervalSince1970: exp)
                            let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
                            expireText = "有效期至 \(f.string(from: d))"
                        } else {
                            expireText = "永久有效"
                        }
                        responder?.setSubTitle("等级：\(resp.tier.displayName)\n\(expireText)\n\(resp.message ?? "")")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { responder?.close() }
                    } else {
                        responder?.setTitle("激活失败")
                        responder?.setSubTitle(resp.message ?? "激活码无效或已过期")
                    }
                case .failure(let err):
                    responder?.setTitle("校验失败")
                    responder?.setSubTitle(err.localizedDescription)
                }
                onResult?(result)
            }
        }
        alert.addButton("取消") {
            responder?.close()
        }

        responder = alert.showEdit("激活码",
                                   subTitle: "免费用户可使用基础功能，输入激活码解锁专业版。",
                                   closeButtonTitle: nil,
                                   animationStyle: .topToBottom,
                                   window: window)
    }

    // MARK: 远程按钮弹窗

    /// 根据后台配置展示一组按钮，按 min_tier 过滤
    @discardableResult
    public func showRemoteButtons(config: SCLRemoteConfig,
                                  manager: SCLRemoteConfigManager,
                                  title: String = "功能菜单",
                                  body: String? = nil,
                                  window: UIWindow? = nil) -> SCLAlertViewResponder? {
        let tier = manager.currentTier
        let visible = config.buttons.filter { $0.visible(for: tier) }
        guard !visible.isEmpty else { return nil }

        let appearance = SCLAlertView.SCLAppearance(
            showCloseButton: true,
            buttonsLayout: .vertical
        )
        let alert = SCLAlertView(appearance: appearance)

        for action in visible {
            alert.addButton(action.title) { [weak self, weak manager] in
                guard let self = self, let manager = manager else { return }
                self.handle(action: action, manager: manager)
            }
        }
        return alert.showTitle(title,
                               subTitle: body ?? "当前身份：\(tier.displayName)",
                               style: .info,
                               animationStyle: .topToBottom,
                               window: window)
    }

    /// 处理按钮点击的默认行为
    public func handle(action: SCLRemoteAction, manager: SCLRemoteConfigManager) {
        if let custom = actionHandler?(action, manager) {
            switch custom {
            case .handled: return
            case .needsActivation:
                showActivationDialog(manager: manager)
                return
            case .custom:
                return
            }
        }

        switch action.type {
        case .activateDialog:
            showActivationDialog(manager: manager)

        case .close:
            break

        case .url, .deepLink:
            guard let value = action.value, let url = URL(string: value) else { return }
            if action.type == .url {
                if UIApplication.shared.canOpenURL(url) {
                    UIApplication.shared.open(url, options: [:], completionHandler: nil)
                }
            } else {
                // DeepLink: iOS 9+ 需要 LSApplicationQueriesSchemes 白名单
                if UIApplication.shared.canOpenURL(url) {
                    UIApplication.shared.open(url, options: [:], completionHandler: nil)
                } else {
                    let tip = SCLAlertView()
                    tip.showWarning("提示", subTitle: "无法打开：\(value)")
                }
            }

        case .custom:
            break
        }
    }

    // MARK: 禁用 App

    /// 后台禁用 App：全屏遮罩，禁止点击背景关闭，无关闭按钮
    /// 每次启动都会弹，直到后台把 disabled 改回 false
    @discardableResult
    public func showDisabledOverlay(config: SCLRemoteConfig,
                                    window: UIWindow? = nil) -> SCLAlertViewResponder? {
        let appearance = SCLAlertView.SCLAppearance(
            showCloseButton: false,
            showCircularIcon: true,
            shouldAutoDismiss: false,
            hideWhenBackgroundViewIsTapped: false,
            disableTapGesture: true,
            dynamicAnimatorActive: false,
            buttonsLayout: .vertical
        )
        let alert = SCLAlertView(appearance: appearance)
        return alert.showTitle(
            config.disabledTitle ?? "服务已暂停",
            subTitle: config.disabledMessage ?? "本应用已被管理员禁用，请联系客服。",
            style: .error,
            animationStyle: .noAnimation,
            window: window
        )
    }

    /// 强制升级提示（min_build 不满足时）
    @discardableResult
    public func showForceUpdateIfNeeded(config: SCLRemoteConfig,
                                        manager: SCLRemoteConfigManager,
                                        window: UIWindow? = nil) -> SCLAlertViewResponder? {
        guard manager.isBuildBlocked(config) else { return nil }
        let appearance = SCLAlertView.SCLAppearance(
            showCloseButton: false,
            shouldAutoDismiss: false,
            hideWhenBackgroundViewIsTapped: false,
            disableTapGesture: true
        )
        let alert = SCLAlertView(appearance: appearance)
        if let urlString = config.forceUpdateURL, let url = URL(string: urlString) {
            alert.addButton("前往更新") {
                if UIApplication.shared.canOpenURL(url) {
                    UIApplication.shared.open(url, options: [:], completionHandler: nil)
                }
            }
        }
        return alert.showTitle("需要更新",
                               subTitle: "当前版本过低，请升级到最新版本后继续使用。",
                               style: .warning,
                               animationStyle: .noAnimation,
                               window: window)
    }
}
