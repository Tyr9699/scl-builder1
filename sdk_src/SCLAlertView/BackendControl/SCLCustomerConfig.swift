//
//  SCLCustomerConfig.swift
//  SCLAlertView - 客户专属固化配置
//
//  本文件由后台在构建动态库时自动替换占位符，客户拿到的是已固化域名/密钥的库。
//  文件内的 SCL_ 占位标记会在构建动态库时由脚本自动替换为该客户配置。请勿手动修改。
//

import Foundation

public enum SCLCustomerConfig {
    /// 后台配置接口（已固化域名 + app_id）
    public static let configURL = "__SCL_CONFIG_URL__"
    /// 后台激活接口
    public static let activateURL = "__SCL_ACTIVATE_URL__"
    /// 客户 AppID
    public static let appID = "__SCL_APP_ID__"
    /// HMAC 密钥
    public static let hmacSecret = "__SCL_SECRET__"
    /// 轮询间隔（秒）
    public static let pollInterval: TimeInterval = __SCL_POLL__

    /// 是否已由后台固化（占位符未被替换则为 false）
    public static var isEmbedded: Bool {
        return !configURL.hasPrefix("__SCL_") && !configURL.isEmpty
    }
}
