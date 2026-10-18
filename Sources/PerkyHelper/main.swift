import Foundation
import PerkyHelperShared
import Darwin
import IOKit.ps
import Security

private let helperMachServiceName = "com.perky.app.lid-helper"
private let pmsetPath = "/usr/bin/pmset"
private let powerPreferencesPath = "/Library/Preferences/com.apple.PowerManagement.plist"

@main
enum PerkyLidHelperMain {
    static func main() {
        let delegate = LidPowerHelperListenerDelegate()
        let listener = NSXPCListener(machServiceName: helperMachServiceName)
        listener.delegate = delegate
        delegate.listener = listener
        delegate.recoveryManager.reconcileAfterLaunch()
        listener.resume()
        dispatchMain()
    }
}

private final class LidPowerHelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    let recoveryManager = LidPowerRecoveryManager()
    weak var listener: NSXPCListener?

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard isAuthorizedPerkyClient(connection) else { return false }
        connection.exportedInterface = NSXPCInterface(with: LidPowerHelperProtocol.self)
        connection.exportedObject = recoveryManager
        connection.invalidationHandler = {}
        connection.interruptionHandler = {}
        connection.resume()
        return true
    }
}

private func isAuthorizedPerkyClient(_ connection: NSXPCConnection) -> Bool {
    guard connection.effectiveUserIdentifier != 0,
          connection.processIdentifier > 0 else { return false }

    var helperCode: SecCode?
    guard SecCodeCopySelf(SecCSFlags(), &helperCode) == errSecSuccess,
          let helperCode,
          isAppleTrusted(helperCode),
          let helperTeam = signingTeamIdentifier(for: helperCode),
          !helperTeam.isEmpty,
          helperTeam != "-" else { return false }

    let attributes: [CFString: Any] = [
        kSecGuestAttributePid: NSNumber(value: connection.processIdentifier)
    ]
    var guestCode: SecCode?
    guard SecCodeCopyGuestWithAttributes(
        nil,
        attributes as CFDictionary,
        SecCSFlags(),
        &guestCode
    ) == errSecSuccess,
    let guestCode else { return false }

    var requirement: SecRequirement?
    let clientRequirement = "anchor apple generic and identifier \"com.perky.app\" and certificate leaf[subject.OU] = \"\(helperTeam)\""
    guard SecRequirementCreateWithString(
        clientRequirement as CFString,
        SecCSFlags(),
        &requirement
    ) == errSecSuccess,
    let requirement else { return false }

    return SecCodeCheckValidity(guestCode, SecCSFlags(), requirement) == errSecSuccess
}

private func isAppleTrusted(_ code: SecCode) -> Bool {
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(
        "anchor apple generic" as CFString,
        SecCSFlags(),
        &requirement
    ) == errSecSuccess,
    let requirement else {
        return false
    }
    return SecCodeCheckValidity(code, SecCSFlags(), requirement) == errSecSuccess
}

private func signingTeamIdentifier(for code: SecCode) -> String? {
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
    let dictionary = information as? [String: Any] else {
        return nil
    }
    return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
}

private final class LidPowerRecoveryManager: NSObject, LidPowerHelperProtocol {
    private enum Phase: String, Codable {
        case applying
        case active
        case conflict
    }

    private struct RecoveryRecord: Codable {
        var identifier: String
        var deadline: Date
        var batteryThresholdPercent: Int?
        var originalSleepDisabled: Bool
        var ownsSleepDisabled: Bool
        var phase: Phase
        var fingerprintBeforeWrite: String?
        var fingerprintAfterWrite: String?
        var message: String?
    }

    private let lock = NSRecursiveLock()
    private let recoveryFileURL = URL(fileURLWithPath: "/Library/Application Support/Perky/lid-recovery.plist")
    private var expiryTimer: DispatchSourceTimer?
    private var currentRecord: RecoveryRecord?
    private var recoveryStateError: String?

    override init() {
        super.init()
        currentRecord = loadRecord()
    }

    func reconcileAfterLaunch() {
        lock.lock()
        defer { lock.unlock() }

        guard recoveryStateError == nil else { return }
        guard var record = currentRecord else { return }
        switch record.phase {
        case .applying:
            record.phase = .conflict
            record.message = "Perky 在应用系统电源设置时中断；设置归属无法确认。请选择保留当前值或恢复启用前的值。"
            if !save(record) {
                record.message = (record.message ?? "")
                    + " 无法持久保存冲突状态；请现在完成恢复选择，helper 重启后可能再次要求处理。"
                currentRecord = record
            }
        case .conflict:
            break
        case .active:
            processActiveSession(record)
        }
    }

    func startSession(
        identifier: String,
        deadline: Date,
        batteryThresholdPercent: Int,
        reply: @escaping (Bool, String?) -> Void
    ) {
        lock.lock()
        defer { lock.unlock() }

        guard !identifier.isEmpty else {
            reply(false, "Perky 无法识别当前保持唤醒会话。")
            return
        }
        guard deadline.timeIntervalSinceNow > 0,
              deadline.timeIntervalSinceNow <= 24 * 60 * 60 else {
            reply(false, "合盖模式只支持最长 24 小时的恢复期限。")
            return
        }
        guard (5...50).contains(batteryThresholdPercent) else {
            reply(false, "电量停止阈值必须在 5% 到 50% 之间。")
            return
        }
        guard recoveryStateError == nil else {
            reply(false, recoveryStateError)
            return
        }
        if let batteryFailure = batterySafetyFailure(thresholdPercent: batteryThresholdPercent) {
            reply(false, batteryFailure)
            return
        }

        if let existing = currentRecord {
            guard existing.phase == .active, existing.identifier == identifier else {
                reply(false, existing.message ?? "另一个合盖恢复会话仍在处理；请先检查系统状态。")
                return
            }
            var renewed = existing
            renewed.deadline = deadline
            renewed.batteryThresholdPercent = batteryThresholdPercent
            guard save(renewed) else {
                reply(false, "无法写入新的独立恢复期限；原恢复期限保持不变。")
                return
            }
            scheduleExpiry(for: renewed)
            reply(true, nil)
            return
        }

        guard let originalValue = currentSleepDisabled() else {
            reply(false, "无法通过 pmset 读取当前 SleepDisabled 状态；未修改系统设置。")
            return
        }

        if originalValue {
            let record = RecoveryRecord(
                identifier: identifier,
                deadline: deadline,
                batteryThresholdPercent: batteryThresholdPercent,
                originalSleepDisabled: true,
                ownsSleepDisabled: false,
                phase: .active,
                fingerprintBeforeWrite: nil,
                fingerprintAfterWrite: nil,
                message: "SleepDisabled 在 Perky 启动前已开启；Perky 不会更改或覆盖它。"
            )
            guard save(record) else {
                reply(false, "无法持久保存恢复期限；Perky 没有启用系统级防睡眠设置。")
                return
            }
            scheduleExpiry(for: record)
            reply(true, record.message)
            return
        }

        guard let beforeFingerprint = powerPreferencesFingerprint() else {
            reply(false, "无法记录系统电源设置的所有权信息；为避免无法安全恢复，未修改系统设置。")
            return
        }

        var record = RecoveryRecord(
            identifier: identifier,
            deadline: deadline,
            batteryThresholdPercent: batteryThresholdPercent,
            originalSleepDisabled: false,
            ownsSleepDisabled: true,
            phase: .applying,
            fingerprintBeforeWrite: beforeFingerprint,
            fingerprintAfterWrite: nil,
            message: nil
        )
        guard save(record) else {
            reply(false, "无法持久保存恢复期限；Perky 没有修改系统设置。")
            return
        }

        guard runPMSet(["-a", "disablesleep", "1"]).success else {
            let currentValue = currentSleepDisabled()
            let currentFingerprint = powerPreferencesFingerprint()
            if currentValue == false, currentFingerprint == beforeFingerprint {
                guard removeRecord() else {
                    record.phase = .conflict
                    record.fingerprintAfterWrite = currentFingerprint
                    record.message = "SleepDisabled 已核实未改变，但无法删除系统恢复记录。请在恢复面板选择保留当前值以重试清理。"
                    if !save(record) { currentRecord = record }
                    reply(false, record.message)
                    return
                }
                reply(false, "pmset 未能启用系统级防睡眠设置；已核实原设置未变化。")
                return
            }
            record.phase = .conflict
            record.fingerprintAfterWrite = currentFingerprint
            record.message = "pmset 未确认完成；设置是否已更改无法安全判断。Perky 保留恢复记录，请选择保留当前值或恢复启用前的值。"
            _ = save(record)
            currentRecord = record
            reply(false, record.message)
            return
        }
        guard currentSleepDisabled() == true,
              let afterFingerprint = powerPreferencesFingerprint(),
              afterFingerprint != beforeFingerprint else {
            record.phase = .conflict
            record.message = "pmset 返回后未能验证设置变化及所有权；Perky 停止自动写入，请检查系统电源设置。"
            _ = save(record)
            currentRecord = record
            reply(false, record.message)
            return
        }

        record.phase = .active
        record.fingerprintAfterWrite = afterFingerprint
        record.message = nil
        guard save(record) else {
            record.phase = .conflict
            record.message = "SleepDisabled 已更改，但恢复记录更新失败；Perky 正尝试立即恢复原值。"
            currentRecord = record
            let restored = restoreIfStillOwned(record)
            reply(false, restored.0
                ? "恢复记录更新失败；系统设置已立即回滚，合盖模式未开启。"
                : (restored.1 ?? record.message))
            return
        }
        if expiryTimer == nil {
            scheduleExpiry(for: record)
        }
        reply(true, nil)
    }

    func stopSession(identifier: String, reply: @escaping (Bool, String?) -> Void) {
        lock.lock()
        defer { lock.unlock() }

        guard recoveryStateError == nil else {
            reply(false, recoveryStateError)
            return
        }
        guard let record = currentRecord else {
            reply(true, nil)
            return
        }
        guard record.identifier == identifier else {
            reply(false, "系统恢复任务的会话标识不匹配；Perky 未更改系统设置。")
            return
        }
        guard record.phase == .active else {
            reply(false, record.message ?? "系统电源设置的归属无法确认。")
            return
        }
        let result = restoreIfStillOwned(record)
        reply(result.0, result.1)
    }

    func resolveConflict(identifier: String, restoreOriginal: Bool, reply: @escaping (Bool, String?) -> Void) {
        lock.lock()
        defer { lock.unlock() }

        guard recoveryStateError == nil,
              let record = currentRecord,
              record.identifier == identifier,
              record.phase == .conflict else {
            reply(false, "没有待处理的系统设置冲突。")
            return
        }

        if restoreOriginal {
            guard runPMSet(["-a", "disablesleep", record.originalSleepDisabled ? "1" : "0"]).success,
                  currentSleepDisabled() == record.originalSleepDisabled else {
                reply(false, "macOS 未确认系统设置已恢复；Perky 会保留此恢复记录并允许重试。")
                return
            }
            guard removeRecord() else {
                var retained = record
                retained.message = "SleepDisabled 已按选择恢复，但无法删除恢复记录；请重试清理。"
                if !save(retained) { currentRecord = retained }
                reply(false, retained.message)
                return
            }
            reply(true, "已按你的选择恢复 Perky 启用前的 SleepDisabled 值。")
        } else {
            guard removeRecord() else {
                var retained = record
                retained.message = "已保留当前系统设置，但无法删除恢复记录；请重试清理。"
                if !save(retained) { currentRecord = retained }
                reply(false, retained.message)
                return
            }
            reply(true, "已按你的选择保留当前系统电源设置。")
        }
    }

    func discardUnreadableRecoveryRecord(reply: @escaping (Bool, String?) -> Void) {
        lock.lock()
        defer { lock.unlock() }

        guard recoveryStateError != nil else {
            reply(false, "没有无法读取的恢复记录。")
            return
        }
        guard unlink(recoveryFileURL.path) == 0 || errno == ENOENT else {
            reply(false, "无法移除损坏的恢复记录；SleepDisabled 没有被更改。")
            return
        }
        expiryTimer?.cancel()
        expiryTimer = nil
        currentRecord = nil
        recoveryStateError = nil
        reply(true, "已按你的选择保留当前 SleepDisabled 值，并清除无法读取的恢复记录。")
    }

    func getStatus(reply: @escaping (String?, Date?, Bool, String?) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        if let recoveryStateError {
            reply(nil, nil, true, recoveryStateError)
            return
        }
        guard let record = currentRecord else {
            reply(nil, nil, false, nil)
            return
        }
        reply(record.identifier, record.deadline, record.phase == .conflict, record.message)
    }

    private func restoreIfStillOwned(_ record: RecoveryRecord) -> (Bool, String?) {
        guard record.ownsSleepDisabled else {
            guard removeRecord() else {
                let updated = scheduleImmediateRestoreRetry(
                    for: record,
                    message: "Perky 未修改 SleepDisabled，但无法清除系统恢复记录；独立 helper 会继续重试。"
                )
                return (false, updated.message)
            }
            return (true, record.message)
        }

        guard let currentValue = currentSleepDisabled() else {
            let updated = scheduleImmediateRestoreRetry(
                for: record,
                message: "暂时无法读取 SleepDisabled；恢复记录仍有效，Perky 会继续重试。"
            )
            return (false, updated.message)
        }
        if currentValue == record.originalSleepDisabled {
            guard removeRecord() else {
                let updated = scheduleImmediateRestoreRetry(
                    for: record,
                    message: "SleepDisabled 已是原值，但无法清除系统恢复记录；独立 helper 会继续重试。"
                )
                return (false, updated.message)
            }
            return (true, nil)
        }

        guard let expectedFingerprint = record.fingerprintAfterWrite,
              let currentFingerprint = powerPreferencesFingerprint() else {
            let updated = scheduleImmediateRestoreRetry(
                for: record,
                message: "暂时无法验证系统电源设置归属；恢复记录仍有效，Perky 会继续重试。"
            )
            return (false, updated.message)
        }
        guard currentValue, currentFingerprint == expectedFingerprint else {
            let message = "系统电源设置在 Perky 运行期间发生变化。Perky 没有覆盖新状态；请明确选择保留或恢复 Perky 启用前的 SleepDisabled 值。"
            markConflict(record, message: message)
            return (false, message)
        }

        let restoreValue = record.originalSleepDisabled ? "1" : "0"
        let writeResult = runPMSet(["-a", "disablesleep", restoreValue])
        let verifiedValue = currentSleepDisabled()
        if verifiedValue == record.originalSleepDisabled {
            guard removeRecord() else {
                let updated = scheduleImmediateRestoreRetry(
                    for: record,
                    message: "SleepDisabled 已恢复，但无法清除系统恢复记录；独立 helper 会继续重试。"
                )
                return (false, updated.message)
            }
            return (true, nil)
        }
        if verifiedValue == true,
           powerPreferencesFingerprint() == expectedFingerprint {
            let message = writeResult.success
                ? "macOS 暂未确认 SleepDisabled 已恢复；Perky 会继续尝试恢复。"
                : "pmset 暂时未能恢复 SleepDisabled；Perky 会在独立 helper 中继续尝试。"
            let updated = scheduleImmediateRestoreRetry(for: record, message: message)
            return (false, updated.message)
        }

        if verifiedValue == nil {
            let updated = scheduleImmediateRestoreRetry(
                for: record,
                message: "暂时无法确认 SleepDisabled 是否已恢复；Perky 保留恢复记录并继续重试。"
            )
            return (false, updated.message)
        }

        let message = "恢复期间系统电源设置发生变化。Perky 没有覆盖新状态；请明确选择保留当前值或恢复启用前的值。"
        markConflict(record, message: message)
        return (false, message)
    }

    private func scheduleImmediateRestoreRetry(for record: RecoveryRecord, message: String) -> RecoveryRecord {
        var updated = record
        updated.phase = .active
        updated.deadline = Date()
        updated.message = message
        if !save(updated) {
            updated.message = (updated.message ?? message)
                + " 当前恢复期限未能写入系统恢复记录；运行中的 helper 仍每 3 秒重试，但若 helper 重启，恢复可能延迟到原截止时间。"
        }
        currentRecord = updated
        scheduleExpiry(for: updated)
        return updated
    }

    private func scheduleExpiry(for record: RecoveryRecord) {
        expiryTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(
            deadline: .now() + min(3, max(0, record.deadline.timeIntervalSinceNow)),
            repeating: .seconds(3),
            leeway: .seconds(1)
        )
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard let latest = self.currentRecord,
                  latest.identifier == record.identifier,
                  latest.phase == .active else { return }
            self.processActiveSession(latest)
        }
        expiryTimer = timer
        timer.resume()
    }

    private func processActiveSession(_ record: RecoveryRecord) {
        guard record.phase == .active else { return }
        if let failure = batterySafetyFailure(thresholdPercent: record.batteryThresholdPercent ?? 15) {
            var stopping = record
            stopping.deadline = Date()
            stopping.message = failure
            _ = save(stopping)
            _ = restoreIfStillOwned(stopping)
            return
        }
        if record.deadline <= Date() {
            _ = restoreIfStillOwned(record)
            return
        }
        if expiryTimer == nil {
            scheduleExpiry(for: record)
        }
    }

    private func batterySafetyFailure(thresholdPercent: Int) -> String? {
        guard currentPowerSourceType() != (kIOPMACPowerKey as String) else { return nil }
        guard let battery = currentBatteryPercent() else {
            return "无法读取电池电量；Perky 的独立 helper 已触发安全恢复。"
        }
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            return "电池供电时已进入低电量模式；Perky 的独立 helper 已触发安全恢复。"
        }
        if battery <= thresholdPercent {
            return String(format: "电量达到 %d%%；Perky 的独立 helper 已触发安全恢复。", thresholdPercent)
        }
        return nil
    }

    private func currentPowerSourceType() -> String? {
        guard let powerSourceInfo = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return nil }
        return IOPSGetProvidingPowerSourceType(powerSourceInfo)?.takeUnretainedValue() as String?
    }

    private func currentBatteryPercent() -> Int? {
        guard let powerSourceInfo = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let powerSources = IOPSCopyPowerSourcesList(powerSourceInfo)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }
        for powerSource in powerSources {
            guard let rawDescription = IOPSGetPowerSourceDescription(powerSourceInfo, powerSource),
                  let description = rawDescription.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey as String] as? String == kIOPSInternalBatteryType,
                  let currentCapacity = description[kIOPSCurrentCapacityKey as String] as? NSNumber,
                  let maximumCapacity = description[kIOPSMaxCapacityKey as String] as? NSNumber,
                  maximumCapacity.intValue > 0 else {
                continue
            }
            return min(100, max(0, Int((Double(currentCapacity.intValue) / Double(maximumCapacity.intValue) * 100).rounded())))
        }
        return nil
    }

    private func markConflict(_ record: RecoveryRecord, message: String) {
        var updated = record
        updated.phase = .conflict
        updated.message = message
        if !save(updated) {
            currentRecord = updated
        }
        expiryTimer?.cancel()
        expiryTimer = nil
    }

    private func currentSleepDisabled() -> Bool? {
        let result = runPMSet(["-g"])
        guard result.success else { return nil }
        for line in result.output.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.first == "SleepDisabled", let value = parts.dropFirst().first else { continue }
            if value == "1" || value.lowercased() == "yes" { return true }
            if value == "0" || value.lowercased() == "no" { return false }
        }
        return nil
    }

    private func runPMSet(_ arguments: [String]) -> (success: Bool, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pmsetPath)
        process.arguments = arguments
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }

        do {
            try process.run()
            if terminated.wait(timeout: .now() + 10) == .timedOut {
                process.terminate()
                if terminated.wait(timeout: .now() + 1) == .timedOut {
                    _ = kill(process.processIdentifier, SIGKILL)
                    _ = terminated.wait(timeout: .now() + 1)
                }
                process.waitUntilExit()
                return (false, "pmset timed out")
            }
        } catch {
            return (false, error.localizedDescription)
        }
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        let error = String(data: errorData, encoding: .utf8) ?? ""
        return (process.terminationStatus == 0, output + error)
    }

    private func powerPreferencesFingerprint() -> String? {
        var information = stat()
        guard lstat(powerPreferencesPath, &information) == 0 else { return nil }
        return [
            String(information.st_dev),
            String(information.st_ino),
            String(information.st_size),
            String(information.st_mtimespec.tv_sec),
            String(information.st_mtimespec.tv_nsec)
        ].joined(separator: ":")
    }

    private func loadRecord() -> RecoveryRecord? {
        let directoryURL = recoveryFileURL.deletingLastPathComponent()
        var directoryInformation = stat()
        guard lstat(directoryURL.path, &directoryInformation) == 0 else {
            if errno == ENOENT { return nil }
            recoveryStateError = "无法检查 Perky 的系统恢复目录；helper 不会修改 SleepDisabled。"
            return nil
        }
        guard directoryInformation.st_mode & S_IFMT == S_IFDIR,
              directoryInformation.st_uid == 0 else {
            recoveryStateError = "Perky 的系统恢复目录权限异常；helper 不会修改 SleepDisabled。"
            return nil
        }
        var information = stat()
        guard lstat(recoveryFileURL.path, &information) == 0 else {
            if errno == ENOENT { return nil }
            recoveryStateError = "无法检查 Perky 的系统恢复记录；为保护当前设置，helper 不会修改 SleepDisabled。"
            return nil
        }
        guard information.st_mode & S_IFMT == S_IFREG, information.st_uid == 0,
              let data = try? Data(contentsOf: recoveryFileURL),
              let record = try? PropertyListDecoder().decode(RecoveryRecord.self, from: data) else {
            recoveryStateError = "Perky 的系统恢复记录损坏或权限异常；helper 不会猜测原设置，也不会修改 SleepDisabled。"
            return nil
        }
        return record
    }

    @discardableResult
    private func save(_ record: RecoveryRecord) -> Bool {
        do {
            guard geteuid() == 0 else { return false }
            let directoryURL = recoveryFileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            var directoryInformation = stat()
            guard lstat(directoryURL.path, &directoryInformation) == 0,
                  directoryInformation.st_mode & S_IFMT == S_IFDIR,
                  chown(directoryURL.path, 0, 0) == 0,
                  chmod(directoryURL.path, 0o700) == 0 else {
                return false
            }
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .xml
            try encoder.encode(record).write(to: recoveryFileURL, options: .atomic)
            var fileInformation = stat()
            guard lstat(recoveryFileURL.path, &fileInformation) == 0,
                  fileInformation.st_mode & S_IFMT == S_IFREG,
                  fileInformation.st_uid == 0,
                  chmod(recoveryFileURL.path, 0o600) == 0 else { return false }
            let fileDescriptor = open(recoveryFileURL.path, O_RDONLY | O_NOFOLLOW)
            guard fileDescriptor >= 0 else {
                return false
            }
            defer { _ = close(fileDescriptor) }
            guard fsync(fileDescriptor) == 0 else { return false }
            let directoryDescriptor = open(recoveryFileURL.deletingLastPathComponent().path, O_RDONLY)
            guard directoryDescriptor >= 0 else { return false }
            defer { _ = close(directoryDescriptor) }
            guard fsync(directoryDescriptor) == 0 else { return false }
            currentRecord = record
            recoveryStateError = nil
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    private func removeRecord() -> Bool {
        guard unlink(recoveryFileURL.path) == 0 || errno == ENOENT else { return false }
        let directoryDescriptor = open(recoveryFileURL.deletingLastPathComponent().path, O_RDONLY)
        guard directoryDescriptor >= 0 else { return false }
        defer { _ = close(directoryDescriptor) }
        guard fsync(directoryDescriptor) == 0 else { return false }
        expiryTimer?.cancel()
        expiryTimer = nil
        currentRecord = nil
        recoveryStateError = nil
        return true
    }
}
