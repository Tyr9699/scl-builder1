//
//  SCLRemoteModels.swift
//  SCLAlertView - BackendControl
//
//  后台远程配置 / 激活码协议的数据模型。
//  所有模型均使用 snake_case 与服务端对接，未知字段会被 JSONDecoder 忽略。
//

import Foundation

// MARK: - 用户等级（免费 / 收费）

public enum SCLUserTier: String, Codable {
    case unknown = "unknown"
    case free    = "free"   // 免费用户
    case paid    = "paid"   // 收费 / 专业用户

    public var rank: Int {
        switch self {
        case .paid:    return 2
        case .free:    return 1
        case .unknown: return 0
        }
    }

    public var displayName: String {
        switch self {
        case .paid:    return "专业版"
        case .free:    return "免费版"
        case .unknown: return "未激活"
        }
    }
}

// MARK: - 后台下发的按钮

public struct SCLRemoteAction: Codable {
    public enum ActionType: String, Codable {
        case url            // 打开外部网页
        case deepLink       // 打开 App 内 Deeplink / URL Scheme
        case activateDialog // 弹出激活码输入框
        case close          // 仅关闭弹窗
        case custom         // 交给业务层自定义处理
    }

    public let id: String
    public let title: String
    public let type: ActionType
    public let value: String?
    public let style: String?          // success / info / warning / error / notice / edit
    public let minTier: SCLUserTier?   // 仅 >= 该等级的用户可见

    enum CodingKeys: String, CodingKey {
        case id, title, type, value, style
        case minTier = "min_tier"
    }

    public init(id: String,
                title: String,
                type: ActionType,
                value: String? = nil,
                style: String? = nil,
                minTier: SCLUserTier? = nil) {
        self.id = id
        self.title = title
        self.type = type
        self.value = value
        self.style = style
        self.minTier = minTier
    }

    public func visible(for tier: SCLUserTier) -> Bool {
        guard let minTier = minTier else { return true }
        return tier.rank >= minTier.rank
    }
}

// MARK: - 公告

public struct SCLAnnouncement: Codable {
    public let id: String
    public let title: String
    public let body: String
    public let style: String?
    public let showOnce: Bool
    public let confirmTitle: String?

    enum CodingKeys: String, CodingKey {
        case id, title, body, style
        case showOnce = "show_once"
        case confirmTitle = "confirm_title"
    }

    public init(id: String,
                title: String,
                body: String,
                style: String? = nil,
                showOnce: Bool = true,
                confirmTitle: String? = nil) {
        self.id = id
        self.title = title
        self.body = body
        self.style = style
        self.showOnce = showOnce
        self.confirmTitle = confirmTitle
    }
}

// MARK: - 远程总配置

public struct SCLRemoteConfig: Codable {
    public let schemaVersion: Int
    public let generatedAt: TimeInterval
    public let disabled: Bool
    public let disabledTitle: String?
    public let disabledMessage: String?
    public let announcement: SCLAnnouncement?
    public let buttons: [SCLRemoteAction]
    public let minBuild: Int?
    public let forceUpdateURL: String?
    public let signature: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "v"
        case generatedAt   = "ts"
        case disabled
        case disabledTitle = "disabled_title"
        case disabledMessage = "disabled_message"
        case announcement
        case buttons
        case minBuild      = "min_build"
        case forceUpdateURL = "force_update_url"
        case signature
    }

    public init(schemaVersion: Int,
                generatedAt: TimeInterval,
                disabled: Bool,
                disabledTitle: String? = nil,
                disabledMessage: String? = nil,
                announcement: SCLAnnouncement? = nil,
                buttons: [SCLRemoteAction] = [],
                minBuild: Int? = nil,
                forceUpdateURL: String? = nil,
                signature: String? = nil) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.disabled = disabled
        self.disabledTitle = disabledTitle
        self.disabledMessage = disabledMessage
        self.announcement = announcement
        self.buttons = buttons
        self.minBuild = minBuild
        self.forceUpdateURL = forceUpdateURL
        self.signature = signature
    }
}

// MARK: - 激活码

public struct SCLActivationRequest: Codable {
    public let code: String
    public let deviceId: String
    public let appId: String
    public let bundleId: String
    public let appVersion: String
    public let build: Int
    public let ts: TimeInterval
    public let nonce: String

    enum CodingKeys: String, CodingKey {
        case code
        case deviceId = "device_id"
        case appId    = "app_id"
        case bundleId = "bundle_id"
        case appVersion = "app_version"
        case build, ts, nonce
    }
}

public struct SCLActivationResponse: Codable {
    public let valid: Bool
    public let tier: SCLUserTier
    public let expiresAt: TimeInterval?
    public let message: String?
    public let features: [String]
    public let ts: TimeInterval?
    public let signature: String?

    enum CodingKeys: String, CodingKey {
        case valid, tier, message, features, ts, signature
        case expiresAt = "expires_at"
    }

    public init(valid: Bool,
                tier: SCLUserTier,
                expiresAt: TimeInterval? = nil,
                message: String? = nil,
                features: [String] = [],
                ts: TimeInterval? = nil,
                signature: String? = nil) {
        self.valid = valid
        self.tier = tier
        self.expiresAt = expiresAt
        self.message = message
        self.features = features
        self.ts = ts
        self.signature = signature
    }

    public var isExpired: Bool {
        guard let expiresAt = expiresAt, expiresAt > 0 else { return false }
        return Date().timeIntervalSince1970 > expiresAt
    }
}

// MARK: - 签名规范化串（服务端必须使用完全相同的规则）

extension SCLRemoteConfig {
    /// 参与 HMAC 签名的规范化字符串；服务端以此生成 signature 字段
    public var signingPayload: String {
        let ann = announcement?.id ?? ""
        let btnList = buttons.map { "\($0.id):\($0.type.rawValue):\($0.minTier?.rawValue ?? "")" }
                             .joined(separator: ",")
        return [
            "v=\(schemaVersion)",
            "ts=\(Int(generatedAt))",
            "disabled=\(disabled ? 1 : 0)",
            "dt=\(disabledTitle ?? "")",
            "dm=\(disabledMessage ?? "")",
            "ann=\(ann)",
            "at=\(announcement?.title ?? "")",
            "ab=\(announcement?.body ?? "")",
            "as=\(announcement?.style ?? "")",
            "btns=\(btnList)",
            "mb=\(minBuild ?? 0)",
            "fu=\(forceUpdateURL ?? "")"
        ].joined(separator: "|")
    }
}

extension SCLActivationResponse {
    /// 参与 HMAC 签名的规范化字符串
    public var signingPayload: String {
        return [
            "valid=\(valid ? 1 : 0)",
            "tier=\(tier.rawValue)",
            "exp=\(Int(expiresAt ?? 0))",
            "msg=\(message ?? "")",
            "ts=\(Int(ts ?? 0))",
            "features=\(features.sorted().joined(separator: ","))"
        ].joined(separator: "|")
    }
}
