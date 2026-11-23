//
//  SCLRemoteConfigManager.swift
//  SCLAlertView - BackendControl
//
//  后台配置拉取 / 缓存 / HMAC 验签 / 激活码校验 / 本地等级状态。
//  纯 Foundation 实现，主线程回调，可直接在 AppDelegate / SceneDelegate 使用。
//

import Foundation

// MARK: - 管理器配置

public struct SCLRemoteConfigOptions {
    public var configURL: URL
    public var activationURL: URL?
    public var hmacSecret: String          // 为空则跳过验签（方便调试）
    public var pollInterval: TimeInterval  // 后台轮询间隔，0 表示不自动轮询
    public var timeout: TimeInterval
    public var appId: String?
    public var customHeaders: [String: String]

    public init(configURL: URL,
                activationURL: URL? = nil,
                hmacSecret: String = "",
                pollInterval: TimeInterval = 0,
                timeout: TimeInterval = 15,
                appId: String? = nil,
                customHeaders: [String: String] = [:]) {
        self.configURL = configURL
        self.activationURL = activationURL
        self.hmacSecret = hmacSecret
        self.pollInterval = pollInterval
        self.timeout = timeout
        self.appId = appId
        self.customHeaders = customHeaders
    }
}

// MARK: - 回调类型

public typealias SCLConfigResult = (Result<SCLRemoteConfig, Error>) -> Void
public typealias SCLActivationResult = (Result<SCLActivationResponse, Error>) -> Void

public enum SCLBackendError: LocalizedError {
    case invalidURL
    case badStatus(Int)
    case emptyData
    case decodeFailed(String)
    case signatureMismatch
    case noActivationURL
    case staleConfig            // 拉取失败且没有可用缓存
    case serverMessage(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:            return "远程地址无效"
        case .badStatus(let c):      return "服务端返回 \(c)"
        case .emptyData:             return "服务端返回空数据"
        case .decodeFailed(let m):   return "配置解析失败: \(m)"
        case .signatureMismatch:     return "配置签名校验失败"
        case .noActivationURL:       return "未配置激活码校验地址"
        case .staleConfig:           return "配置不可用且无本地缓存"
        case .serverMessage(let m):  return m
        }
    }
}

// MARK: - 管理器

open class SCLRemoteConfigManager {
    /// 最近一次 apply 过的配置签名串，用于去重（避免缓存与最新配置重复弹窗）
    public private(set) var lastAppliedConfigKey: String?

    public static let shared = SCLRemoteConfigManager()

    public var options: SCLRemoteConfigOptions?
    public var deviceInfo: SCLDeviceInfo = .current

    private let session: URLSession
    private let cache = SCLConfigCache()
    private var pollTimer: Timer?
    private var configListeners: [UUID: (SCLRemoteConfig) -> Void] = [:]
    private let queue = DispatchQueue(label: "com.sclalertview.config.queue", qos: .utility)

    public init() {
        let conf = URLSessionConfiguration.default
        conf.timeoutIntervalForRequest = 15
        conf.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: conf)
    }

    deinit {
        pollTimer?.invalidate()
    }

    // MARK: 缓存读取

    /// 同步取最近一次成功拉取的配置（含磁盘缓存），用于冷启动先渲染
    public var cachedConfig: SCLRemoteConfig? {
        return cache.loadConfig()
    }

    /// 当前生效用户等级：没有激活码 / 激活过期 => 免费用户
    public var currentTier: SCLUserTier {
        guard let state = cache.loadActivation(), !state.response.isExpired else { return .free }
        return state.response.tier
    }

    public var cachedActivation: SCLActivationResponse? {
        guard let state = cache.loadActivation(), !state.response.isExpired else { return nil }
        return state.response
    }

    // MARK: 拉取配置

    @discardableResult
    public func fetchConfig(completion: SCLConfigResult? = nil) -> URLSessionDataTask? {
        guard let options = options else {
            completion?(.failure(SCLBackendError.invalidURL))
            return nil
        }
        var request = URLRequest(url: options.configURL)
        request.timeoutInterval = options.timeout
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        options.customHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            if let error = error {
                self.finishConfigFromCache(error, completion: completion)
                return
            }
            guard let http = response as? HTTPURLResponse else {
                self.finishConfigFromCache(SCLBackendError.emptyData, completion: completion)
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                self.finishConfigFromCache(SCLBackendError.badStatus(http.statusCode), completion: completion)
                return
            }
            guard let data = data, !data.isEmpty else {
                self.finishConfigFromCache(SCLBackendError.emptyData, completion: completion)
                return
            }

            do {
                let config = try JSONDecoder().decode(SCLRemoteConfig.self, from: data)
                guard SCLHMAC.verify(key: options.hmacSecret,
                                     message: config.signingPayload,
                                     signature: config.signature) else {
                    self.finishConfigFromCache(SCLBackendError.signatureMismatch, completion: completion)
                    return
                }
                self.cache.saveConfig(data)
                DispatchQueue.main.async { completion?(.success(config)) }
                self.notifyListeners(config)
            } catch let decodeError {
                self.finishConfigFromCache(SCLBackendError.decodeFailed(decodeError.localizedDescription),
                                           completion: completion)
            }
        }
        task.resume()
        return task
    }

    private func finishConfigFromCache(_ error: Error, completion: SCLConfigResult?) {
        // 网络失败时回退到上一次成功缓存，保证弱网/离线仍能打开 App
        if let cached = cache.loadConfig() {
            DispatchQueue.main.async { completion?(.success(cached)) }
        } else {
            DispatchQueue.main.async { completion?(.failure(error)) }
        }
    }

    // MARK: 激活码校验

    @discardableResult
    public func activate(code: String, completion: SCLActivationResult? = nil) -> URLSessionDataTask? {
        guard let options = options, let url = options.activationURL else {
            completion?(.failure(SCLBackendError.noActivationURL))
            return nil
        }
        let payload = SCLActivationRequest(
            code: code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
            deviceId: deviceInfo.deviceId,
            appId: options.appId ?? deviceInfo.appId,
            bundleId: deviceInfo.bundleId,
            appVersion: deviceInfo.appVersion,
            build: deviceInfo.build,
            ts: Date().timeIntervalSince1970,
            nonce: UUID().uuidString
        )

        var request = URLRequest(url: url)
        request.timeoutInterval = options.timeout
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        options.customHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.httpBody = try? JSONEncoder().encode(payload)

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            if let error = error {
                DispatchQueue.main.async { completion?(.failure(error)) }
                return
            }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                DispatchQueue.main.async { completion?(.failure(SCLBackendError.badStatus(status))) }
                return
            }
            guard let data = data, !data.isEmpty else {
                DispatchQueue.main.async { completion?(.failure(SCLBackendError.emptyData)) }
                return
            }
            do {
                let result = try JSONDecoder().decode(SCLActivationResponse.self, from: data)
                guard SCLHMAC.verify(key: options.hmacSecret,
                                     message: result.signingPayload,
                                     signature: result.signature) else {
                    DispatchQueue.main.async { completion?(.failure(SCLBackendError.signatureMismatch)) }
                    return
                }
                if result.valid && !result.isExpired {
                    self.cache.saveActivation(result, code: payload.code)
                }
                DispatchQueue.main.async { completion?(.success(result)) }
            } catch let decodeError {
                DispatchQueue.main.async {
                    completion?(.failure(SCLBackendError.decodeFailed(decodeError.localizedDescription)))
                }
            }
        }
        task.resume()
        return task
    }

    /// 清除本地激活状态（退出登录 / 换设备时用）
    public func clearActivation() {
        cache.clearActivation()
    }

    // MARK: 版本号 / 监听

    /// 记录已应用的配置（供门面层去重调用）
    public func markApplied(_ config: SCLRemoteConfig) {
        lastAppliedConfigKey = config.signingPayload
    }

    public func isBuildBlocked(_ config: SCLRemoteConfig) -> Bool {
        guard let minBuild = config.minBuild else { return false }
        return deviceInfo.build < minBuild
    }

    public func addConfigListener(_ listener: @escaping (SCLRemoteConfig) -> Void) -> UUID {
        let id = UUID()
        DispatchQueue.main.async { self.configListeners[id] = listener }
        return id
    }

    public func removeConfigListener(_ id: UUID) {
        DispatchQueue.main.async { self.configListeners[id] = nil }
    }

    private func notifyListeners(_ config: SCLRemoteConfig) {
        DispatchQueue.main.async {
            self.configListeners.values.forEach { $0(config) }
        }
    }

    // MARK: 自动轮询

    public func startPolling() {
        guard let interval = options?.pollInterval, interval > 0 else { return }
        stopPolling()
        fetchConfig()
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.fetchConfig()
        }
        RunLoop.main.add(pollTimer!, forMode: .common)
    }

    public func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}

// MARK: - 本地缓存（UserDefaults）

private final class SCLConfigCache {
    private let defaults = UserDefaults.standard
    private let configKey = "com.sclalertview.remote_config"
    private let activationKey = "com.sclalertview.activation"

    func saveConfig(_ data: Data) {
        defaults.set(data, forKey: configKey)
    }

    func loadConfig() -> SCLRemoteConfig? {
        guard let data = defaults.data(forKey: configKey) else { return nil }
        return try? JSONDecoder().decode(SCLRemoteConfig.self, from: data)
    }

    func saveActivation(_ response: SCLActivationResponse, code: String) {
        let state = SCLActivationState(response: response, code: code, activatedAt: Date().timeIntervalSince1970)
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: activationKey)
        }
    }

    func loadActivation() -> SCLActivationState? {
        guard let data = defaults.data(forKey: activationKey) else { return nil }
        return try? JSONDecoder().decode(SCLActivationState.self, from: data)
    }

    func clearActivation() {
        defaults.removeObject(forKey: activationKey)
    }
}

private struct SCLActivationState: Codable {
    let response: SCLActivationResponse
    let code: String
    let activatedAt: TimeInterval
}
