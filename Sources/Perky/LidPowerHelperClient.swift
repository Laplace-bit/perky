import Foundation
import PerkyCore
import PerkyHelperShared
import Security
import ServiceManagement

@MainActor
final class LidPowerHelperClient {
    static let shared = LidPowerHelperClient()

    private let service = SMAppService.daemon(plistName: "com.perky.app.lid-helper.plist")
    private let machServiceName = "com.perky.app.lid-helper"
    private let localInstallBundlePath = "/Applications/Perky.app"
    private let launchDaemonLabel = "com.perky.app.lid-helper"
    private lazy var cachedTrustedTeamIdentifier = Self.readTrustedTeamIdentifier()
    private var queuedMutations: [(@escaping () -> Void) -> Void] = []
    private var mutationInFlight = false
    private var cachedLocalHelperStatus: (checkedAt: Date, isRunning: Bool)?

    var usesLocalAdminInstall: Bool {
        Bundle.main.infoDictionary?["PerkyLocalAdminInstall"] as? Bool == true
            && Bundle.main.bundleURL.standardizedFileURL.path == localInstallBundlePath
    }

    var authorizationMessage: String {
        if usesLocalAdminInstall {
            return localAdminHelperIsRunning
                ? "本机恢复 helper 已安装并加载。"
                : "本机恢复 helper 未运行。请重新安装 Perky 本机安装包后再试。"
        }
        guard hasTrustedSigningIdentity else {
            return "当前构建未使用 Apple 信任的签名；合盖运行需要 Apple Development 或 Developer ID 签名后才能安装恢复助手。"
        }
        switch service.status {
        case .enabled:
            return "恢复 helper 已获准运行。"
        case .requiresApproval:
            return "需要在系统设置中允许 Perky 恢复 helper。"
        case .notRegistered:
            return "恢复 helper 尚未安装。"
        case .notFound:
            return "macOS 找不到 Perky 恢复 helper。请重新安装 Perky。"
        @unknown default:
            return "无法确认恢复 helper 的系统授权状态。"
        }
    }

    var isEnabled: Bool {
        usesLocalAdminInstall ? localAdminHelperIsRunning : service.status == .enabled && hasTrustedSigningIdentity
    }
    var requiresApproval: Bool { !usesLocalAdminInstall && service.status == .requiresApproval }
    var hasTrustedSigningIdentity: Bool { cachedTrustedTeamIdentifier != nil }

    func register() -> String {
        if usesLocalAdminInstall {
            return authorizationMessage
        }
        guard hasTrustedSigningIdentity else {
            if HelperAuthorizationSettingsPolicy.shouldOpenLoginItems(
                state: authorizationState,
                hasTrustedSigningIdentity: false,
                initiatedByUser: true
            ) {
                LoginItemsSettingsOpener.open()
                return untrustedSettingsMessage
            }
            return authorizationMessage
        }
        if service.status == .enabled {
            return "恢复 helper 已获准运行。"
        }
        do {
            try service.register()
        } catch {
            if service.status != .requiresApproval {
                return "无法注册恢复 helper：\(error.localizedDescription)"
            }
        }

        if HelperAuthorizationSettingsPolicy.shouldOpenLoginItems(
            state: authorizationState,
            hasTrustedSigningIdentity: true,
            initiatedByUser: true
        ) {
            LoginItemsSettingsOpener.open()
            return "已登记恢复 helper。请在系统设置 > 通用 > 登录项中允许 Perky。"
        }
        return authorizationMessage
    }

    func openLoginItemsSettings() -> String {
        if usesLocalAdminInstall {
            return authorizationMessage
        }
        LoginItemsSettingsOpener.open()
        return hasTrustedSigningIdentity ? trustedSettingsMessage : untrustedSettingsMessage
    }

    private var localAdminHelperIsRunning: Bool {
        if let cachedLocalHelperStatus,
           Date().timeIntervalSince(cachedLocalHelperStatus.checkedAt) < 2 {
            return cachedLocalHelperStatus.isRunning
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "system/\(launchDaemonLabel)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let isRunning: Bool
        do {
            try process.run()
            process.waitUntilExit()
            isRunning = process.terminationStatus == 0
        } catch {
            isRunning = false
        }
        cachedLocalHelperStatus = (Date(), isRunning)
        return isRunning
    }

    private var authorizationState: HelperServiceAuthorizationState {
        switch service.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .notFound
        @unknown default: return .unknown
        }
    }

    private var untrustedSettingsMessage: String {
        "已打开系统设置 > 通用 > 登录项。当前构建没有 Apple 信任签名，无法安装恢复 helper，Perky 不会出现在可批准列表中。"
    }

    private var trustedSettingsMessage: String {
        "已打开系统设置 > 通用 > 登录项。若 Perky 显示在后台活动中，请允许恢复 helper。"
    }

    func startSession(
        identifier: String,
        deadline: Date,
        batteryThresholdPercent: Int,
        completion: @escaping (Bool, String?) -> Void
    ) {
        withHelper(completion: completion) { proxy, reply in
            proxy.startSession(
                identifier: identifier,
                deadline: deadline,
                batteryThresholdPercent: batteryThresholdPercent,
                reply: reply
            )
        }
    }

    func stopSession(identifier: String, completion: @escaping (Bool, String?) -> Void) {
        withHelper(completion: completion) { proxy, reply in
            proxy.stopSession(identifier: identifier, reply: reply)
        }
    }

    func resolveConflict(
        identifier: String,
        restoreOriginal: Bool,
        completion: @escaping (Bool, String?) -> Void
    ) {
        withHelper(completion: completion) { proxy, reply in
            proxy.resolveConflict(identifier: identifier, restoreOriginal: restoreOriginal, reply: reply)
        }
    }

    func discardUnreadableRecoveryRecord(completion: @escaping (Bool, String?) -> Void) {
        withHelper(completion: completion) { proxy, reply in
            proxy.discardUnreadableRecoveryRecord(reply: reply)
        }
    }

    func getStatus(completion: @escaping (String?, Date?, Bool, String?) -> Void) {
        guard isEnabled else {
            completion(nil, nil, false, authorizationMessage)
            return
        }
        let connection = makeConnection()
        let lock = NSLock()
        var didComplete = false
        let finish: (String?, Date?, Bool, String?) -> Void = { identifier, deadline, conflict, message in
            lock.lock()
            guard !didComplete else {
                lock.unlock()
                return
            }
            didComplete = true
            lock.unlock()
            connection.invalidationHandler = nil
            connection.interruptionHandler = nil
            connection.invalidate()
            DispatchQueue.main.async {
                completion(identifier, deadline, conflict, message)
            }
        }
        connection.invalidationHandler = {
            finish(nil, nil, false, "无法连接恢复 helper。请检查系统设置中的 Perky 授权。")
        }
        connection.interruptionHandler = {
            finish(nil, nil, false, "恢复 helper 连接中断。")
        }
        connection.resume()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
            finish(nil, nil, false, "无法连接恢复 helper。")
        }) as? LidPowerHelperProtocol else {
            finish(nil, nil, false, "无法连接恢复 helper。")
            return
        }
        proxy.getStatus(reply: finish)
    }

    private func withHelper(
        completion: @escaping (Bool, String?) -> Void,
        perform: @escaping (LidPowerHelperProtocol, @escaping (Bool, String?) -> Void) -> Void
    ) {
        enqueueMutation { [weak self] finishMutation in
            guard let self else {
                finishMutation()
                return
            }
            self.performWithHelper(
                completion: { success, message in
                    completion(success, message)
                    finishMutation()
                },
                perform: perform
            )
        }
    }

    private func performWithHelper(
        completion: @escaping (Bool, String?) -> Void,
        perform: (LidPowerHelperProtocol, @escaping (Bool, String?) -> Void) -> Void
    ) {
        guard isEnabled else {
            completion(false, authorizationMessage)
            return
        }

        let connection = makeConnection()
        let lock = NSLock()
        var didComplete = false
        let finish: (Bool, String?) -> Void = { success, message in
            lock.lock()
            guard !didComplete else {
                lock.unlock()
                return
            }
            didComplete = true
            lock.unlock()

            connection.invalidationHandler = nil
            connection.interruptionHandler = nil
            connection.invalidate()
            DispatchQueue.main.async {
                completion(success, message)
            }
        }

        connection.invalidationHandler = { finish(false, "macOS 已停止 Perky 恢复 helper。请重新检查系统设置授权。") }
        connection.interruptionHandler = { finish(false, "Perky 恢复 helper 连接中断。") }
        connection.resume()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            finish(false, "无法连接恢复 helper：\(error.localizedDescription)")
        }) as? LidPowerHelperProtocol else {
            finish(false, "无法连接恢复 helper。")
            return
        }
        perform(proxy, finish)
    }

    private func enqueueMutation(_ mutation: @escaping (@escaping () -> Void) -> Void) {
        queuedMutations.append(mutation)
        runNextMutation()
    }

    private func runNextMutation() {
        guard !mutationInFlight, !queuedMutations.isEmpty else { return }
        mutationInFlight = true
        let mutation = queuedMutations.removeFirst()
        mutation { [weak self] in
            guard let self else { return }
            self.mutationInFlight = false
            self.runNextMutation()
        }
    }

    private func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: LidPowerHelperProtocol.self)
        return connection
    }

    private static func readTrustedTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess,
              let code else { return nil }

        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            "anchor apple generic and identifier \"com.perky.app\"" as CFString,
            SecCSFlags(),
            &requirement
        ) == errSecSuccess,
        let requirement,
        SecCodeCheckValidity(code, SecCSFlags(), requirement) == errSecSuccess else {
            return nil
        }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else { return nil }

        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
        let information,
        let dictionary = information as? [String: Any],
        let teamIdentifier = dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
        !teamIdentifier.isEmpty,
        teamIdentifier != "-" else {
            return nil
        }
        return teamIdentifier
    }
}
