//
//  SCLDeviceIdentity.swift
//  SCLAlertView - BackendControl
//
//  设备标识：取 bundle id / 版本 / build / 系统版本 / 机型，优先使用业务层注入。
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

public struct SCLDeviceInfo {
    public let deviceId: String
    public let appId: String
    public let bundleId: String
    public let appVersion: String
    public let build: Int
    public let model: String
    public let osVersion: String

    public init(deviceId: String,
                appId: String,
                bundleId: String,
                appVersion: String,
                build: Int,
                model: String,
                osVersion: String) {
        self.deviceId = deviceId
        self.appId = appId
        self.bundleId = bundleId
        self.appVersion = appVersion
        self.build = build
        self.model = model
        self.osVersion = osVersion
    }

    public static var current: SCLDeviceInfo {
        let bundle = Bundle.main
        let bundleId = bundle.bundleIdentifier ?? "unknown.bundle"
        let appId = bundle.object(forInfoDictionaryKey: "SCLAppID") as? String ?? bundleId
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let buildString = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let deviceId = (UserDefaults.standard.string(forKey: "com.sclalertview.device_id") ?? {
            let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            UserDefaults.standard.set(id, forKey: "com.sclalertview.device_id")
            return id
        }())

        #if canImport(UIKit)
        let model = UIDevice.current.model
        let os = UIDevice.current.systemVersion
        #else
        let model = "unknown"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        #endif

        return SCLDeviceInfo(deviceId: deviceId,
                             appId: appId,
                             bundleId: bundleId,
                             appVersion: version,
                             build: Int(buildString) ?? 0,
                             model: model,
                             osVersion: os)
    }
}
