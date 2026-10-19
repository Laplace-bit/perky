import AppKit
import Foundation
import IOKit.pwr_mgt
import PerkyCore
import SwiftUI
import UserNotifications

private struct LidRecoveryHint: Codable {
    let identifier: String
    let deadline: Date?
}

@MainActor
final class PerkyModel: ObservableObject {
    static let shared = PerkyModel()

    @Published private(set) var isRunning = false
    @Published private(set) var isStopping = false
    @Published private(set) var deadline: Date?
    @Published private(set) var failureMessage: String?
    @Published private(set) var statusMessage = "合盖运行尚未启动。打开开关即可启动所选时长。"
    @Published private(set) var notificationMessage: String?
    @Published private(set) var diagnosticsMessage: String?
    @Published private(set) var notificationsEnabled = false
    @Published private(set) var isStarting = false
    @Published private(set) var isLidModeEnabled = false
    @Published private(set) var isLidModeActive = false
    @Published private(set) var isShowingBatteryConfirmation = false
    @Published private(set) var isShowingQuitConfirmation = false
    @Published private(set) var helperStatusMessage = ""
    @Published private(set) var helperIsEnabled = false
    @Published private(set) var helperCanRegister = false
    @Published private(set) var helperNeedsApproval = false
    var helperUsesLocalAdminInstall: Bool { lidPowerHelper.usesLocalAdminInstall }
    @Published private(set) var helperRecoveryMessage: String?
    @Published private(set) var helperRecoveryDeadline: Date?
    @Published private(set) var helperRecoveryIdentifier: String?
    @Published private(set) var helperHasConflict = false
    @Published private(set) var lidModeStatusMessage = "合盖运行关闭；之后由 macOS 当前电源设置决定是否睡眠。"
    @Published private(set) var lidReadinessMessage = "正在检查合盖与电源状态…"
    @Published private(set) var currentBatteryPercent: Int?
    @Published private(set) var isOnACPower = false
    @Published private(set) var currentLidClosed: Bool?
    @Published private(set) var currentClamshellWillSleep: Bool?
    @Published private(set) var brightnessStatusMessage = ""
    @Published private(set) var isBrightnessAvailable = false
    @Published private(set) var brightnessAutomationEnabled = false
    @Published private(set) var brightnessTargetPercent = 10
    @Published private(set) var batteryThresholdPercent = 15
    @Published private(set) var batteryStatusMessage = ""
    @Published var selectedMinutes: Int
    @Published var customMinutesText: String
    @Published var isCustomDurationSelected: Bool

    private var powerAssertion = PowerAssertionController()
    private var sessionID = UUID()
    private var expiryWorkItem: DispatchWorkItem?
    private var accessibilityRefreshTimer: Timer?
    @Published private var menuBarRemainingText = ""
    private var wakeObserver: NSObjectProtocol?
    private var shouldQuitAfterStop = false
    private var didNotifyStopFailure = false
    private var pendingLidStartIdentifier: String?
    private var helperRecoveryStatusLoaded = false
    private var shouldStartLidModeWhenRecoveryStatusLoads = false
    @Published private(set) var helperRecoveryStatusUncertain = false
    private var helperMayHaveRecoveryRecord = false
    private var helperRecoveryStatusGeneration = 0
    private var recoveryOperationsInFlight = 0
    private var activeLidSessionIdentifier: String?
    private var safetyMonitorTimer: Timer?
    private var clamshellObserver = ClamshellStateObserver()
    private var screenParametersObserver: NSObjectProtocol?
    private var brightnessRestoreRecord: BrightnessRestoreRecord?

    private let userDefaults = UserDefaults.standard
    private let selectedMinutesKey = "selectedMinutes"
    private let customMinutesKey = "customMinutes"
    private let customSelectedKey = "isCustomDurationSelected"
    private let notificationsEnabledKey = "notificationsEnabled"
    private let notificationIdentifier = "perky-session-end"
    private let stopFailureNotificationIdentifier = "perky-stop-failure"
    private let lidModeEnabledKey = "lidModeEnabled"
    private let brightnessAutomationEnabledKey = "brightnessAutomationEnabled"
    private let brightnessTargetPercentKey = "brightnessTargetPercent"
    private let batteryThresholdPercentKey = "batteryThresholdPercent"
    private let brightnessRestoreRecordKey = "brightnessRestoreRecord"
    private let helperRecoveryIdentifierKey = "lidPowerHelperSessionIdentifier"
    private let helperRecoveryDeadlineKey = "lidPowerHelperSessionDeadline"
    private let lidPowerHelper = LidPowerHelperClient.shared
    private let brightnessController = DisplayBrightnessController.shared

    private init() {
        let savedMinutes = userDefaults.object(forKey: selectedMinutesKey) as? Int ?? 30
        selectedMinutes = DurationPolicy.clampedStoredMinutes(savedMinutes)
        customMinutesText = String(userDefaults.object(forKey: customMinutesKey) as? Int ?? savedMinutes)
        isCustomDurationSelected = userDefaults.bool(forKey: customSelectedKey)
        notificationsEnabled = userDefaults.bool(forKey: notificationsEnabledKey)
        let savedLidModeEnabled = userDefaults.object(forKey: lidModeEnabledKey) as? Bool
        // Before the toggle started a session, this preference meant only
        // “use lid mode when the Start button is pressed.” Do not restore that
        // stale selection as an active-looking toggle after upgrading.
        isLidModeEnabled = false
        if savedLidModeEnabled == true {
            userDefaults.set(false, forKey: lidModeEnabledKey)
        }
        brightnessAutomationEnabled = userDefaults.bool(forKey: brightnessAutomationEnabledKey)
        brightnessTargetPercent = BrightnessPolicy.clampedTargetPercent(
            userDefaults.object(forKey: brightnessTargetPercentKey) as? Int ?? 10
        )
        batteryThresholdPercent = min(max(userDefaults.object(forKey: batteryThresholdPercentKey) as? Int ?? 15, 5), 50)
        helperRecoveryIdentifier = userDefaults.string(forKey: helperRecoveryIdentifierKey)
        helperRecoveryDeadline = userDefaults.object(forKey: helperRecoveryDeadlineKey) as? Date
        let recoveryHintExists = Self.recoveryHintURL().map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        if helperRecoveryIdentifier == nil, let recoveryHint = Self.loadRecoveryHint() {
            helperRecoveryIdentifier = recoveryHint.identifier
            helperRecoveryDeadline = recoveryHint.deadline
        }
        helperMayHaveRecoveryRecord = helperRecoveryIdentifier != nil || recoveryHintExists
        isBrightnessAvailable = brightnessController.isAvailable
        if brightnessAutomationEnabled && !isBrightnessAvailable {
            brightnessAutomationEnabled = false
            userDefaults.set(false, forKey: brightnessAutomationEnabledKey)
        }
        brightnessStatusMessage = brightnessController.availabilityMessage
        helperStatusMessage = lidPowerHelper.authorizationMessage
        helperIsEnabled = lidPowerHelper.isEnabled
        helperCanRegister = lidPowerHelper.hasTrustedSigningIdentity
        helperNeedsApproval = lidPowerHelper.requiresApproval
        helperMayHaveRecoveryRecord = helperMayHaveRecoveryRecord || helperIsEnabled
        helperRecoveryStatusUncertain = helperMayHaveRecoveryRecord
        if let data = userDefaults.data(forKey: brightnessRestoreRecordKey) {
            brightnessRestoreRecord = try? PropertyListDecoder().decode(BrightnessRestoreRecord.self, from: data)
        }
        refreshMenuBarRemainingText()
    }

    var selectedDuration: Int? {
        guard isCustomDurationSelected else { return selectedMinutes }
        return DurationPolicy.parseCustomMinutes(customMinutesText)
    }

    var customDurationError: String? {
        guard isCustomDurationSelected else { return nil }
        return DurationPolicy.parseCustomMinutes(customMinutesText) == nil
            ? "请输入 1–1440 分钟的整数。"
            : nil
    }

    var batteryConfirmationMessage: String {
        let batteryText = currentBatteryPercent.map { String(format: "当前电量 %d%%", $0) } ?? "当前电量无法读取"
        return "\(batteryText)。达到 \(batteryThresholdPercent)% 或进入低电量模式时，Perky 会停止合盖运行。电池供电会增加耗电和发热。"
    }

    var quitConfirmationMessage: String {
        "Perky 会停止计时，并尝试恢复自己改动过的系统电源状态和屏幕亮度。"
    }

    var customDurationStepperValue: Binding<Int> {
        Binding(
            get: { Int(self.customMinutesText) ?? 30 },
            set: { self.customMinutesText = String(min(max($0, 1), 1440)) }
        )
    }

    var durationChoice: Binding<String> {
        Binding(
            get: { self.isCustomDurationSelected ? "custom" : String(self.selectedMinutes) },
            set: { choice in
                if choice == "custom" {
                    self.selectCustomDuration()
                } else if let minutes = Int(choice) {
                    self.selectQuickDuration(minutes)
                }
            }
        )
    }

    var menuBarSymbol: String {
        if isRunning {
            return isLidModeActive ? "laptopcomputer.and.arrow.down" : "sun.max.fill"
        }
        return "moon.zzz"
    }

    var menuBarAccessibilityLabel: String {
        if isStopping {
            return "Perky，正在停止保持唤醒"
        }
        if isRunning {
            let mode = isLidModeActive ? "合盖运行中" : "保持唤醒中"
            return "Perky，\(mode)，剩余 \(menuBarRemainingText)"
        }
        return "Perky，合盖运行未启动"
    }

    func selectQuickDuration(_ minutes: Int) {
        guard DurationPolicy.quickChoices.contains(minutes) else { return }
        selectedMinutes = minutes
        isCustomDurationSelected = false
        persistDurationPreferences()
    }

    func selectCustomDuration() {
        isCustomDurationSelected = true
        persistDurationPreferences()
    }

    func enableLidMode() {
        isLidModeEnabled = true
        userDefaults.set(true, forKey: lidModeEnabledKey)
        helperStatusMessage = lidPowerHelper.register()
        helperIsEnabled = lidPowerHelper.isEnabled
        helperCanRegister = lidPowerHelper.hasTrustedSigningIdentity
        helperNeedsApproval = lidPowerHelper.requiresApproval
        lidModeStatusMessage = "正在启动限时合盖运行；停止、到期或触发安全条件时会恢复系统策略。"
        refreshHelperRecoveryStatus()
        start()
    }

    func disableLidMode() {
        shouldStartLidModeWhenRecoveryStatusLoads = false
        isLidModeEnabled = false
        userDefaults.set(false, forKey: lidModeEnabledKey)
        if isStarting {
            lidModeStatusMessage = "正在启动合盖模式；启动完成后会恢复合盖睡眠策略，基础保持唤醒会继续。"
            return
        }
        guard isLidModeActive else {
            lidModeStatusMessage = "合盖运行关闭；之后由 macOS 当前电源设置决定是否睡眠。"
            return
        }
        stopLidModeOnly()
    }

    func registerLidHelper() {
        helperStatusMessage = lidPowerHelper.register()
        helperIsEnabled = lidPowerHelper.isEnabled
        helperCanRegister = lidPowerHelper.hasTrustedSigningIdentity
        helperNeedsApproval = lidPowerHelper.requiresApproval
        refreshHelperRecoveryStatus()
    }

    func recheckHelperRecoveryStatus() {
        helperStatusMessage = lidPowerHelper.authorizationMessage
        helperIsEnabled = lidPowerHelper.isEnabled
        helperCanRegister = lidPowerHelper.hasTrustedSigningIdentity
        helperNeedsApproval = lidPowerHelper.requiresApproval
        if helperIsEnabled,
           let failureMessageText = failureMessage,
           failureMessageText.contains("已打开系统设置")
            || failureMessageText.contains("合盖恢复 helper 尚未获准运行") {
            failureMessage = nil
        }
        refreshHelperRecoveryStatus()
    }

    func openLidHelperSettings() {
        helperStatusMessage = lidPowerHelper.openLoginItemsSettings()
    }

    func setBrightnessAutomationEnabled(_ enabled: Bool) {
        if enabled && !brightnessController.isAvailable {
            brightnessAutomationEnabled = false
            userDefaults.set(false, forKey: brightnessAutomationEnabledKey)
            brightnessStatusMessage = brightnessController.availabilityMessage
            return
        }

        brightnessAutomationEnabled = enabled
        userDefaults.set(enabled, forKey: brightnessAutomationEnabledKey)
        if enabled {
            brightnessStatusMessage = "仅在确认合盖运行后将内建屏幕调到目标亮度；外接显示器不受控制。"
            if isLidModeActive, currentLidClosed == true { applyClosedLidBrightness() }
        } else {
            restoreBrightnessIfAppropriate()
            if brightnessRestoreRecord == nil {
                brightnessStatusMessage = "亮度自动调节已关闭。"
            }
        }
    }

    func setBrightnessTargetPercent(_ value: Int) {
        brightnessTargetPercent = BrightnessPolicy.clampedTargetPercent(value)
        userDefaults.set(brightnessTargetPercent, forKey: brightnessTargetPercentKey)
        if brightnessRestoreRecord != nil, isLidModeActive {
            applyClosedLidBrightness()
        }
    }

    func setBatteryThresholdPercent(_ value: Int) {
        guard !isLidModeActive, !isStarting, !isStopping,
              helperRecoveryIdentifier == nil,
              !helperRecoveryStatusUncertain else { return }
        batteryThresholdPercent = min(max(value, 5), 50)
        userDefaults.set(batteryThresholdPercent, forKey: batteryThresholdPercentKey)
        refreshBatteryStatus()
    }

    func confirmStartOnBattery() {
        isShowingBatteryConfirmation = false
        guard let minutes = selectedDuration else {
            failureMessage = customDurationError ?? "请选择有效时长。"
            return
        }
        let snapshot = LidModeSnapshot.current()
        updateSnapshot(snapshot)
        if let failure = BatterySafetyPolicy.failureMessage(
            for: snapshot,
            thresholdPercent: batteryThresholdPercent,
            whileRunning: false
        ) {
            failureMessage = failure
            return
        }
        beginSession(minutes: minutes, withLidMode: true)
    }

    func cancelStartOnBattery() {
        isShowingBatteryConfirmation = false
    }

    func resolvePowerSettingConflict(restoreOriginal: Bool) {
        guard recoveryOperationsInFlight == 0,
              let identifier = helperRecoveryIdentifier else { return }
        recoveryOperationsInFlight += 1
        lidPowerHelper.resolveConflict(identifier: identifier, restoreOriginal: restoreOriginal) { [weak self] success, message in
            guard let self else { return }
            self.recoveryOperationsInFlight = max(0, self.recoveryOperationsInFlight - 1)
            if let message { self.lidModeStatusMessage = message }
            if !success {
                self.failureMessage = message ?? "未能处理系统设置冲突。"
                if self.shouldQuitAfterStop { self.shouldQuitAfterStop = false }
            }
            if success { self.clearHelperRecoveryStatus() }
            self.refreshHelperRecoveryStatus()
            if success, self.shouldQuitAfterStop {
                self.shouldQuitAfterStop = false
                NSApp.terminate(nil)
            }
        }
    }

    func restoreInterruptedLidSessionNow() {
        guard !isRunning, !isStarting, !isStopping,
              recoveryOperationsInFlight == 0,
              let identifier = helperRecoveryIdentifier else { return }
        recoveryOperationsInFlight += 1
        lidPowerHelper.stopSession(identifier: identifier) { [weak self] success, message in
            guard let self else { return }
            self.recoveryOperationsInFlight = max(0, self.recoveryOperationsInFlight - 1)
            if let message { self.lidModeStatusMessage = message }
            if !success {
                self.failureMessage = message ?? "未能恢复系统电源设置。"
                if self.shouldQuitAfterStop { self.shouldQuitAfterStop = false }
            }
            if success { self.clearHelperRecoveryStatus() }
            self.refreshHelperRecoveryStatus()
            if success, self.shouldQuitAfterStop {
                self.shouldQuitAfterStop = false
                NSApp.terminate(nil)
            }
        }
    }

    func keepCurrentSystemSettingAndClearUnreadableRecord() {
        guard recoveryOperationsInFlight == 0 else { return }
        recoveryOperationsInFlight += 1
        lidPowerHelper.discardUnreadableRecoveryRecord { [weak self] success, message in
            guard let self else { return }
            self.recoveryOperationsInFlight = max(0, self.recoveryOperationsInFlight - 1)
            if let message { self.lidModeStatusMessage = message }
            if !success {
                self.failureMessage = message ?? "无法处理系统恢复记录。"
                if self.shouldQuitAfterStop { self.shouldQuitAfterStop = false }
            }
            if success { self.clearHelperRecoveryStatus() }
            self.refreshHelperRecoveryStatus()
            if success, self.shouldQuitAfterStop {
                self.shouldQuitAfterStop = false
                NSApp.terminate(nil)
            }
        }
    }

    func customDurationDidChange() {
        guard let value = Int(customMinutesText), (1...1440).contains(value) else { return }
        selectedMinutes = value
        persistDurationPreferences()
    }

    func start() {
        guard !isRunning, !isStopping, !isStarting else { return }
        if !helperRecoveryStatusLoaded && helperIsEnabled {
            shouldStartLidModeWhenRecoveryStatusLoads = true
            refreshHelperRecoveryStatus()
            statusMessage = "正在检查独立恢复助手的状态…"
            return
        }
        guard helperRecoveryIdentifier == nil,
              !helperHasConflict,
              !helperRecoveryStatusUncertain else {
            failureMessage = "有尚未确认的系统恢复会话。请先恢复或处理该会话，再启动新的计时。"
            return
        }
        guard let minutes = selectedDuration else {
            failureMessage = customDurationError ?? "请选择有效时长。"
            return
        }

        if isLidModeEnabled {
            let snapshot = LidModeSnapshot.current()
            guard snapshot.hasLidSensor else {
                failureMessage = "此 Mac 没有可读取的合盖传感器，合盖模式无法确认。基础保持唤醒仍可单独使用。"
                lidModeStatusMessage = failureMessage ?? ""
                return
            }
            guard lidPowerHelper.isEnabled else {
                helperStatusMessage = lidPowerHelper.register()
                helperCanRegister = lidPowerHelper.hasTrustedSigningIdentity
                helperNeedsApproval = lidPowerHelper.requiresApproval
                failureMessage = "\(helperStatusMessage)基础保持唤醒仍可单独使用。"
                return
            }
            if let safetyFailure = BatterySafetyPolicy.failureMessage(
                for: snapshot,
                thresholdPercent: batteryThresholdPercent,
                whileRunning: false
            ) {
                failureMessage = safetyFailure
                return
            }
            if !snapshot.isOnACPower {
                isShowingBatteryConfirmation = true
                return
            }
        }

        beginSession(minutes: minutes, withLidMode: isLidModeEnabled)
    }

    private func beginSession(minutes: Int, withLidMode: Bool) {
        guard !isRunning, !isStopping, !isStarting else { return }

        let durationSeconds = minutes * 60
        let requestedDeadline = Date().addingTimeInterval(TimeInterval(durationSeconds))
        failureMessage = nil
        switch powerAssertion.start(timeoutSeconds: durationSeconds) {
        case .failure(let error):
            isRunning = false
            deadline = nil
            failureMessage = error.localizedDescription
            statusMessage = "保持唤醒未开启。请检查错误原因后重试。"
            if powerAssertion.hasAssertion {
                isStopping = true
                statusMessage = "正在清理未确认的防睡眠断言。"
                sessionID = UUID()
                scheduleStopRetry(reason: .startFailure, additionalFailure: error.localizedDescription)
            }
        case .success:
            guard withLidMode else {
                finishStart(deadline: requestedDeadline)
                return
            }

            updateSnapshot(LidModeSnapshot.current())
            if brightnessAutomationEnabled { prepareBrightnessRecordForLidSession() }
            isStarting = true
            statusMessage = "正在申请限时系统电源设置…"
            let helperIdentifier = UUID().uuidString
            pendingLidStartIdentifier = helperIdentifier
            rememberHelperRecoveryStatus(identifier: helperIdentifier, deadline: requestedDeadline)
            lidPowerHelper.startSession(
                identifier: helperIdentifier,
                deadline: requestedDeadline,
                batteryThresholdPercent: batteryThresholdPercent
            ) { [weak self] success, message in
                guard let self else { return }
                guard self.pendingLidStartIdentifier == helperIdentifier else {
                    if success {
                        LidPowerHelperClient.shared.stopSession(identifier: helperIdentifier) { _, _ in }
                    }
                    return
                }
                self.pendingLidStartIdentifier = nil
                self.isStarting = false
                if success {
                    self.activeLidSessionIdentifier = helperIdentifier
                    self.isLidModeActive = true
                    self.rememberHelperRecoveryStatus(identifier: helperIdentifier, deadline: requestedDeadline)
                }
                if !self.isLidModeEnabled {
                    if success {
                        self.stopLidModeOnly {
                            guard self.powerAssertion.isActive else {
                                self.finishSession(message: "防睡眠断言已结束；合盖设置已清理。", cancelNotification: true)
                                self.failureMessage = "保持唤醒未能继续，请重新启动。"
                                return
                            }
                            self.finishStart(deadline: requestedDeadline)
                            if self.isLidModeActive { self.startSafetyMonitor() }
                        }
                    } else {
                        guard self.powerAssertion.isActive else {
                            self.finishSession(message: "保持唤醒未能启动。", cancelNotification: true)
                            self.failureMessage = message ?? "防睡眠断言已失效。"
                            return
                        }
                        self.restoreBrightnessIfAppropriate()
                        self.lidModeStatusMessage = message ?? "合盖模式已关闭；基础保持唤醒已启动。"
                        if message != nil { self.failureMessage = message }
                        self.refreshHelperRecoveryStatus()
                        self.finishStart(deadline: requestedDeadline)
                    }
                    return
                }
                guard success, self.powerAssertion.isActive else {
                    let startFailure = message ?? "macOS 未能确认系统级防睡眠设置。"
                    self.failureMessage = startFailure
                    self.lidModeStatusMessage = startFailure
                    self.statusMessage = "合盖模式未开启；正在清理已启动的电源保护。"
                    self.refreshHelperRecoveryStatus()
                    if !success { self.restoreBrightnessIfAppropriate() }
                    self.isStopping = true
                    self.stop(reason: .startFailure, additionalFailure: startFailure)
                    return
                }

                self.lidModeStatusMessage = message ?? "合盖模式已启用；系统电源设置将在计时结束时恢复。"
                self.finishStart(deadline: requestedDeadline)
                self.startSafetyMonitor()
                self.refreshLidModeSnapshot()
            }
        }
    }

    private func finishStart(deadline requestedDeadline: Date) {
        isRunning = true
        didNotifyStopFailure = false
        deadline = requestedDeadline
        statusMessage = isLidModeActive
            ? "合盖运行中 · 到期自动恢复 macOS 睡眠策略"
            : "保持唤醒中 · 仅防止空闲睡眠"
        sessionID = UUID()
        scheduleExpiry()
        scheduleEndNotification()
        startAccessibilityRefreshTimer()
        refreshMenuBarRemainingText()
        if shouldQuitAfterStop {
            stop(reason: .quit)
        }
    }

    func extend(by minutes: Int = 15) {
        guard isRunning, !isStopping, let deadline else { return }
        let now = Date()
        guard deadline > now else {
            stop(reason: .expired)
            return
        }

        let newDeadline = deadline.addingTimeInterval(TimeInterval(minutes * 60))
        commitDeadline(newDeadline, previousDeadline: deadline, status: nil)
    }

    private func commitDeadline(_ newDeadline: Date, previousDeadline: Date, status: String?) {
        let newTimeout = max(1, Int(ceil(newDeadline.timeIntervalSinceNow)))
        switch powerAssertion.updateTimeout(seconds: newTimeout) {
        case .failure(let error):
            failureMessage = error.localizedDescription
        case .success:
            guard isLidModeActive, let identifier = activeLidSessionIdentifier else {
                finalizeDeadlineChange(newDeadline, status: status)
                return
            }
            recoveryOperationsInFlight += 1
            lidPowerHelper.startSession(
                identifier: identifier,
                deadline: newDeadline,
                batteryThresholdPercent: batteryThresholdPercent
            ) { [weak self] success, message in
                guard let self else { return }
                guard self.activeLidSessionIdentifier == identifier,
                      self.isRunning,
                      !self.isStopping,
                      self.isLidModeEnabled else {
                    self.recoveryOperationsInFlight = max(0, self.recoveryOperationsInFlight - 1)
                    return
                }
                guard success else {
                    let oldTimeout = max(1, Int(ceil(previousDeadline.timeIntervalSinceNow)))
                    _ = self.powerAssertion.updateTimeout(seconds: oldTimeout)
                    self.lidPowerHelper.startSession(
                        identifier: identifier,
                        deadline: previousDeadline,
                        batteryThresholdPercent: self.batteryThresholdPercent
                    ) { rollbackSuccess, rollbackMessage in
                        guard self.activeLidSessionIdentifier == identifier else {
                            self.recoveryOperationsInFlight = max(0, self.recoveryOperationsInFlight - 1)
                            return
                        }
                        self.recoveryOperationsInFlight = max(0, self.recoveryOperationsInFlight - 1)
                        guard !self.isStopping, self.isLidModeEnabled else { return }
                        if rollbackSuccess {
                            self.rememberHelperRecoveryStatus(identifier: identifier, deadline: previousDeadline)
                            self.refreshHelperRecoveryStatus()
                        } else {
                            let recoveryFailure = rollbackMessage ?? "独立恢复期限未能回滚；Perky 正停止本次计时并尝试恢复系统设置。"
                            self.failureMessage = recoveryFailure
                            self.stop(reason: .safety(recoveryFailure))
                        }
                    }
                    self.failureMessage = message ?? "未能同步更新独立恢复期限；原计时保持不变。"
                    return
                }
                self.recoveryOperationsInFlight = max(0, self.recoveryOperationsInFlight - 1)
                self.rememberHelperRecoveryStatus(identifier: identifier, deadline: newDeadline)
                self.finalizeDeadlineChange(newDeadline, status: status)
            }
        }
    }

    private func finalizeDeadlineChange(_ newDeadline: Date, status: String?) {
        failureMessage = nil
        deadline = newDeadline
        sessionID = UUID()
        scheduleExpiry()
        scheduleEndNotification()
        refreshMenuBarRemainingText()
        if let status { statusMessage = status }
    }

    func applySelectedDurationAsRemainingTime() {
        guard isRunning, !isStopping, let currentDeadline = deadline else { return }
        guard let minutes = selectedDuration else {
            failureMessage = customDurationError ?? "请选择有效时长。"
            return
        }

        let now = Date()
        let previousRemaining = max(0, Int(ceil(currentDeadline.timeIntervalSince(now))))
        let newDeadline = now.addingTimeInterval(TimeInterval(minutes * 60))
        commitDeadline(
            newDeadline,
            previousDeadline: currentDeadline,
            status: "剩余时间已从 \(Self.formatDuration(previousRemaining)) 重设为 \(minutes) 分钟。"
        )
    }

    func stopManually() {
        stop(reason: .manual)
    }

    func retryStop() {
        stop(reason: .manual)
    }

    func requestQuit() {
        if !helperRecoveryStatusLoaded && helperIsEnabled {
            refreshHelperRecoveryStatus()
            failureMessage = "正在检查独立恢复助手的状态，请检查完成后再退出。"
            return
        }
        if helperRecoveryStatusUncertain && !isRunning && !isStarting && !isStopping {
            failureMessage = "无法确认系统恢复状态。请检查恢复助手连接后再退出 Perky。"
            return
        }
        if helperHasConflict {
            failureMessage = "请先处理系统电源设置冲突，再退出 Perky。"
            return
        }
        if isLidModeActive || isStarting || helperRecoveryIdentifier != nil {
            isShowingQuitConfirmation = true
            return
        }
        quitAfterStoppingIfNeeded()
    }

    func confirmQuit() {
        isShowingQuitConfirmation = false
        guard !helperHasConflict else {
            failureMessage = "请先处理系统电源设置冲突，再退出 Perky。"
            return
        }
        guard !helperRecoveryStatusUncertain || isRunning || isStarting || isStopping else {
            failureMessage = "无法确认系统恢复状态。请检查恢复助手连接后再退出 Perky。"
            return
        }
        shouldQuitAfterStop = true
        if isRunning || isStarting || isStopping {
            if !isStarting && !isStopping { stop(reason: .quit) }
        } else if helperRecoveryIdentifier != nil {
            restoreInterruptedLidSessionNow()
        } else {
            shouldQuitAfterStop = false
            NSApp.terminate(nil)
        }
    }

    func cancelQuit() {
        isShowingQuitConfirmation = false
    }

    @discardableResult
    func prepareForTermination() -> Bool {
        if !helperRecoveryStatusLoaded && helperIsEnabled {
            refreshHelperRecoveryStatus()
            failureMessage = "正在检查独立恢复助手的状态，请稍后再次退出。"
            return false
        }
        if helperHasConflict {
            failureMessage = "请先处理系统电源设置冲突，再退出 Perky。"
            return false
        }
        if helperRecoveryStatusUncertain && !isRunning && !isStarting && !isStopping {
            failureMessage = "无法确认系统恢复状态。请检查恢复助手连接后再退出 Perky。"
            return false
        }
        guard isRunning || isStarting || isStopping else {
            guard helperRecoveryIdentifier != nil else { return true }
            shouldQuitAfterStop = true
            restoreInterruptedLidSessionNow()
            return false
        }
        shouldQuitAfterStop = true
        if !isStarting && !isStopping { stop(reason: .quit) }
        return false
    }

    func updateNotifications(_ enabled: Bool) {
        notificationMessage = nil
        if !enabled {
            notificationsEnabled = false
            userDefaults.set(false, forKey: notificationsEnabledKey)
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notificationIdentifier])
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notificationIdentifier])
            return
        }

        Task {
            do {
                let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                guard allowed else {
                    notificationsEnabled = false
                    notificationMessage = "通知权限未开启。你仍可在面板中查看到期状态。"
                    return
                }
                notificationsEnabled = true
                userDefaults.set(true, forKey: notificationsEnabledKey)
                notificationMessage = "到期和安全停止时会发送通知。"
                scheduleEndNotification()
            } catch {
                notificationsEnabled = false
                notificationMessage = "无法启用通知：\(error.localizedDescription)"
            }
        }
    }

    func runDiagnostics() {
        let basicStatus = isRunning && powerAssertion.isActive
            ? "基础断言：已由 macOS 确认生效。"
            : "基础断言：当前未开启。"
        let helperStatus = helperHasConflict
            ? "合盖 helper：检测到系统设置冲突，需要你选择恢复或保留。"
            : (lidPowerHelper.isEnabled ? "合盖 helper：已获准运行。" : "合盖 helper：尚未获准运行。")
        let lidStatus = isLidModeActive
            ? "合盖模式：已启用，helper 会按期限恢复合盖策略。"
            : "合盖模式：\(lidReadinessMessage)"
        let brightnessStatus = brightnessController.isAvailable
            ? "内建屏幕亮度：接口可用（macOS 26 使用非公开 DisplayServices 接口）。"
            : "内建屏幕亮度：\(brightnessController.availabilityMessage)"
        diagnosticsMessage = [basicStatus, helperStatus, lidStatus, brightnessStatus].joined(separator: " ")
    }

    func remainingSeconds(at date: Date) -> Int {
        guard let deadline else { return 0 }
        return max(0, Int(ceil(deadline.timeIntervalSince(date))))
    }

    func formattedRemaining(at date: Date) -> String {
        Self.formatDuration(remainingSeconds(at: date))
    }

    func startObservingSystemPowerEvents() {
        guard wakeObserver == nil else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notificationIdentifier])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [stopFailureNotificationIdentifier])
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.resumeSessionAfterWake()
            }
        }
        clamshellObserver.start { [weak self] in
            self?.refreshLidModeSnapshot()
        }
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshLidModeSnapshot() }
        }
        refreshHelperRecoveryStatus()
        refreshLidModeSnapshot()
        refreshBatteryStatus()
        if notificationsEnabled {
            Task {
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                guard settings.authorizationStatus == .authorized else {
                    notificationsEnabled = false
                    userDefaults.set(false, forKey: notificationsEnabledKey)
                    notificationMessage = "系统通知权限已关闭。需要时可在设置中重新开启。"
                    return
                }
            }
        }
    }

    private func resumeSessionAfterWake() {
        refreshLidModeSnapshot()
        refreshHelperRecoveryStatus()
        guard isRunning, !isStopping, let deadline else { return }
        let remaining = Int(ceil(deadline.timeIntervalSinceNow))
        guard remaining > 0 else {
            stop(reason: .expired)
            return
        }

        if powerAssertion.isActive {
            statusMessage = "系统唤醒后已确认保持唤醒仍然生效。"
            if isLidModeActive { startSafetyMonitor() }
            scheduleEndNotification()
            refreshMenuBarRemainingText()
            return
        }

        switch powerAssertion.resume(timeoutSeconds: remaining) {
        case .success:
            failureMessage = nil
            statusMessage = "系统唤醒后，保持唤醒已继续。"
            sessionID = UUID()
            scheduleExpiry()
            scheduleEndNotification()
            refreshMenuBarRemainingText()
            if isLidModeActive { startSafetyMonitor() }
        case .failure(let error):
            failureMessage = error.localizedDescription
            switch powerAssertion.stop() {
            case .success:
                completeStopAfterAssertion(reason: .wakeRecovery, additionalFailure: error.localizedDescription)
            case .failure:
                isStopping = true
                statusMessage = "正在清理唤醒后的防睡眠断言。"
                notifyStopFailureIfAllowed(error.localizedDescription)
                scheduleStopRetry(reason: .wakeRecovery, additionalFailure: error.localizedDescription)
            }
        }
    }

    private func stop(reason: StopReason, additionalFailure: String? = nil) {
        guard isRunning || isStopping else { return }
        isStopping = true
        safetyMonitorTimer?.invalidate()
        safetyMonitorTimer = nil
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notificationIdentifier])
        switch powerAssertion.stop() {
        case .success:
            completeStopAfterAssertion(reason: reason, additionalFailure: additionalFailure)
        case .failure(let error):
            failureMessage = error.localizedDescription
            statusMessage = "正在重试释放防睡眠断言。"
            notifyStopFailureIfAllowed(error.localizedDescription)
            scheduleStopRetry(reason: reason, additionalFailure: additionalFailure)
        }
    }

    private func finishSession(message: String, cancelNotification: Bool) {
        expiryWorkItem?.cancel()
        expiryWorkItem = nil
        accessibilityRefreshTimer?.invalidate()
        accessibilityRefreshTimer = nil
        isRunning = false
        isStopping = false
        isStarting = false
        isLidModeEnabled = false
        isLidModeActive = false
        shouldStartLidModeWhenRecoveryStatusLoads = false
        userDefaults.set(false, forKey: lidModeEnabledKey)
        activeLidSessionIdentifier = nil
        safetyMonitorTimer?.invalidate()
        safetyMonitorTimer = nil
        restoreBrightnessIfAppropriate()
        didNotifyStopFailure = false
        deadline = nil
        failureMessage = nil
        statusMessage = message
        sessionID = UUID()
        refreshMenuBarRemainingText()
        if cancelNotification {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notificationIdentifier])
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [stopFailureNotificationIdentifier])
        }
    }

    private func quitAfterStoppingIfNeeded() {
        guard isRunning || isStarting || isStopping else {
            NSApp.terminate(nil)
            return
        }
        shouldQuitAfterStop = true
        if !isStarting { stop(reason: .quit) }
    }

    private func completeStopAfterAssertion(reason: StopReason, additionalFailure: String? = nil) {
        safetyMonitorTimer?.invalidate()
        safetyMonitorTimer = nil
        restoreBrightnessIfAppropriate()

        let message: String
        switch reason {
        case .expired:
            message = "计时结束，已恢复原有睡眠行为。"
        case .startFailure:
            message = "未确认的防睡眠断言已清理。"
        case .wakeRecovery:
            message = "唤醒后的防睡眠断言已清理。"
        case .manual, .quit:
            message = "已停止保持唤醒。"
        case .safety(let reason):
            message = reason
        }

        let helperIdentifier = activeLidSessionIdentifier ?? helperRecoveryIdentifier
        guard let helperIdentifier else {
            finishSession(message: message, cancelNotification: true)
            if let additionalFailure {
                failureMessage = additionalFailure
                notifyStopFailureIfAllowed(additionalFailure)
            }
            if case .safety = reason { sendSafetyStopNotification(message) }
            terminateAfterSuccessfulStopIfRequested()
            return
        }
        recoveryOperationsInFlight += 1

        lidPowerHelper.stopSession(identifier: helperIdentifier) { [weak self] success, helperMessage in
            guard let self else { return }
            self.recoveryOperationsInFlight = max(0, self.recoveryOperationsInFlight - 1)
            self.isLidModeActive = false
            self.safetyMonitorTimer?.invalidate()
            self.safetyMonitorTimer = nil
            if success {
                self.activeLidSessionIdentifier = nil
                self.clearHelperRecoveryStatus()
                self.lidModeStatusMessage = helperMessage ?? "系统级睡眠设置已恢复。"
                self.finishSession(message: message, cancelNotification: true)
                if let additionalFailure {
                    self.failureMessage = additionalFailure
                    self.notifyStopFailureIfAllowed(additionalFailure)
                }
                if case .safety = reason { self.sendSafetyStopNotification(message) }
                self.terminateAfterSuccessfulStopIfRequested()
            } else {
                let recoveryMessage = helperMessage ?? "系统电源设置仍待恢复。"
                self.lidModeStatusMessage = recoveryMessage
                self.refreshHelperRecoveryStatus()
                self.finishSession(message: "保持唤醒已停止；系统电源设置仍待处理。", cancelNotification: true)
                self.failureMessage = [additionalFailure, recoveryMessage].compactMap { $0 }.joined(separator: " ")
                self.notifyStopFailureIfAllowed(self.failureMessage ?? recoveryMessage)
                if self.shouldQuitAfterStop { self.shouldQuitAfterStop = false }
                if case .safety = reason { self.sendSafetyStopNotification(message) }
            }
        }
    }

    private func terminateAfterSuccessfulStopIfRequested() {
        guard shouldQuitAfterStop else { return }
        shouldQuitAfterStop = false
        NSApp.terminate(nil)
    }

    private func stopLidModeOnly() {
        stopLidModeOnly(completion: nil)
    }

    private func stopLidModeOnly(completion: (() -> Void)?) {
        safetyMonitorTimer?.invalidate()
        safetyMonitorTimer = nil
        restoreBrightnessIfAppropriate()
        guard let identifier = activeLidSessionIdentifier else {
            isLidModeActive = false
            lidModeStatusMessage = "合盖模式已关闭。"
            completion?()
            return
        }
        recoveryOperationsInFlight += 1
        lidPowerHelper.stopSession(identifier: identifier) { [weak self] success, message in
            guard let self else { return }
            self.recoveryOperationsInFlight = max(0, self.recoveryOperationsInFlight - 1)
            if success {
                self.activeLidSessionIdentifier = nil
                self.isLidModeActive = false
                self.failureMessage = nil
                self.clearHelperRecoveryStatus()
                self.lidModeStatusMessage = message ?? "合盖模式已关闭，系统电源设置已恢复。"
            } else {
                self.failureMessage = message ?? "未能安全关闭合盖模式。"
                self.lidModeStatusMessage = self.failureMessage ?? ""
                self.refreshHelperRecoveryStatus()
            }
            completion?()
        }
    }

    private func refreshHelperRecoveryStatus() {
        helperStatusMessage = lidPowerHelper.authorizationMessage
        helperIsEnabled = lidPowerHelper.isEnabled
        helperCanRegister = lidPowerHelper.hasTrustedSigningIdentity
        helperNeedsApproval = lidPowerHelper.requiresApproval
        let requestGeneration = helperRecoveryStatusGeneration
        lidPowerHelper.getStatus { [weak self] identifier, deadline, conflict, message in
            guard let self,
                  self.helperRecoveryStatusGeneration == requestGeneration else { return }
            if let identifier {
                self.rememberHelperRecoveryStatus(identifier: identifier, deadline: deadline)
                self.helperHasConflict = conflict
                self.helperRecoveryMessage = message
                self.helperRecoveryStatusLoaded = true
                self.helperRecoveryStatusUncertain = false
            } else if message == nil {
                if self.pendingLidStartIdentifier != nil || self.isStarting {
                    self.helperRecoveryStatusLoaded = false
                    self.helperRecoveryStatusUncertain = true
                } else {
                    self.clearHelperRecoveryStatus()
                    self.helperRecoveryStatusLoaded = true
                }
            } else {
                self.helperStatusMessage = message ?? self.lidPowerHelper.authorizationMessage
                self.helperIsEnabled = self.lidPowerHelper.isEnabled
                self.helperRecoveryMessage = message
                self.helperHasConflict = conflict
                self.helperRecoveryStatusLoaded = true
                self.helperRecoveryStatusUncertain = self.helperIsEnabled
                    || self.helperMayHaveRecoveryRecord
                    || self.helperRecoveryIdentifier != nil
                    || self.isLidModeActive
                    || self.isStarting
            }
            if self.shouldStartLidModeWhenRecoveryStatusLoads {
                self.shouldStartLidModeWhenRecoveryStatusLoads = false
                if self.isLidModeEnabled { self.start() }
            }
        }
    }

    private func rememberHelperRecoveryStatus(identifier: String, deadline: Date?) {
        helperRecoveryStatusGeneration &+= 1
        helperRecoveryIdentifier = identifier
        helperRecoveryDeadline = deadline
        helperRecoveryStatusLoaded = true
        helperRecoveryStatusUncertain = false
        helperMayHaveRecoveryRecord = true
        userDefaults.set(identifier, forKey: helperRecoveryIdentifierKey)
        if let deadline {
            userDefaults.set(deadline, forKey: helperRecoveryDeadlineKey)
        } else {
            userDefaults.removeObject(forKey: helperRecoveryDeadlineKey)
        }
        guard let hintURL = Self.recoveryHintURL() else { return }
        do {
            let directoryURL = hintURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
            let data = try PropertyListEncoder().encode(LidRecoveryHint(identifier: identifier, deadline: deadline))
            try data.write(to: hintURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: hintURL.path)
        } catch {
            helperStatusMessage = "应用恢复提示暂时无法写入；独立 helper 仍持有系统恢复记录。"
        }
    }

    private func clearHelperRecoveryStatus() {
        helperRecoveryStatusGeneration &+= 1
        helperRecoveryIdentifier = nil
        helperRecoveryDeadline = nil
        helperHasConflict = false
        helperRecoveryMessage = nil
        helperRecoveryStatusLoaded = true
        helperRecoveryStatusUncertain = false
        helperMayHaveRecoveryRecord = false
        userDefaults.removeObject(forKey: helperRecoveryIdentifierKey)
        userDefaults.removeObject(forKey: helperRecoveryDeadlineKey)
        if let hintURL = Self.recoveryHintURL() {
            try? FileManager.default.removeItem(at: hintURL)
        }
    }

    private static func recoveryHintURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Perky", isDirectory: true)
            .appendingPathComponent("lid-recovery-hint.plist", isDirectory: false)
    }

    private static func loadRecoveryHint() -> LidRecoveryHint? {
        guard let hintURL = recoveryHintURL(),
              let data = try? Data(contentsOf: hintURL),
              let hint = try? PropertyListDecoder().decode(LidRecoveryHint.self, from: data),
              !hint.identifier.isEmpty else {
            return nil
        }
        return hint
    }

    private func updateSnapshot(_ snapshot: LidModeSnapshot) {
        currentBatteryPercent = snapshot.batteryPercent
        isOnACPower = snapshot.isOnACPower
        currentLidClosed = snapshot.isLidClosed
        currentClamshellWillSleep = snapshot.clamshellWillSleep
        lidReadinessMessage = snapshot.readinessMessage
        if !snapshot.isOnACPower {
            if let battery = snapshot.batteryPercent {
                batteryStatusMessage = String(format: "电池 %d%%，自动停止阈值 %d%%。", battery, batteryThresholdPercent)
            } else {
                batteryStatusMessage = "无法读取电池电量；合盖模式会安全停止。"
            }
        } else {
            batteryStatusMessage = "交流电源已连接；若改用电池，Perky 会继续监测电量和低电量模式。"
        }
    }

    private func refreshLidModeSnapshot() {
        let snapshot = LidModeSnapshot.current()
        updateSnapshot(snapshot)
        if isLidModeActive {
            if snapshot.isLidClosed == true {
                if snapshot.clamshellWillSleep == true {
                    lidModeStatusMessage = "macOS 仍报告合盖会触发睡眠；请开盖检查，Perky 无法确认本机合盖运行已生效。"
                }
                if brightnessAutomationEnabled { applyClosedLidBrightness() }
            } else if snapshot.isLidClosed == false {
                restoreBrightnessIfAppropriate()
                if brightnessRestoreRecord == nil, brightnessAutomationEnabled {
                    brightnessStatusMessage = "已开盖；内建屏幕亮度已恢复。"
                }
            }
        } else if snapshot.isLidClosed != true {
            restoreBrightnessIfAppropriate()
        }
    }

    private func refreshBatteryStatus() {
        let snapshot = LidModeSnapshot.current()
        updateSnapshot(snapshot)
        guard isLidModeActive, !isStopping, !snapshot.isOnACPower else { return }
        if let reason = batteryStartFailure(for: snapshot) {
            stop(reason: .safety(reason))
        }
    }

    private func batteryStartFailure(for snapshot: LidModeSnapshot) -> String? {
        BatterySafetyPolicy.failureMessage(for: snapshot, thresholdPercent: batteryThresholdPercent)
    }

    private func startSafetyMonitor() {
        safetyMonitorTimer?.invalidate()
        refreshBatteryStatus()
        safetyMonitorTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isLidModeActive, !self.isStopping else { return }
                self.refreshBatteryStatus()
                self.refreshLidModeSnapshot()
            }
        }
    }

    private func applyClosedLidBrightness() {
        guard brightnessAutomationEnabled, isLidModeActive, currentLidClosed == true else { return }
        let target = BrightnessPolicy.normalizedTarget(brightnessTargetPercent)
        var record = brightnessRestoreRecord
        if record == nil {
            guard var captured = brightnessController.captureCurrentBrightness() else {
                brightnessStatusMessage = "无法在合盖前保存内建屏幕原亮度。请开盖后重新启动合盖模式。"
                return
            }
            captured.targetValue = target
            guard persistBrightnessRestoreRecord(captured) else {
                brightnessStatusMessage = "无法保存亮度恢复记录；Perky 没有更改屏幕亮度。"
                return
            }
            record = captured
        } else if var existing = record, abs(existing.targetValue - target) > 0.005 {
            existing.targetValue = target
            guard persistBrightnessRestoreRecord(existing) else {
                brightnessStatusMessage = "无法保存亮度恢复记录；Perky 没有更改屏幕亮度。"
                return
            }
            record = existing
        }

        guard var record else { return }
        if let current = brightnessController.currentBrightness(displayID: record.displayID),
           abs(current - target) <= 0.025 {
            record.lastAppliedValue = target
            _ = persistBrightnessRestoreRecord(record)
            brightnessStatusMessage = String(format: "合盖时内建屏幕亮度已设为 %d%%；开盖或停止时会尝试恢复。", brightnessTargetPercent)
        } else if brightnessController.setBrightness(target, displayID: record.displayID) {
            record.lastAppliedValue = target
            _ = persistBrightnessRestoreRecord(record)
            brightnessStatusMessage = String(format: "合盖时内建屏幕亮度已设为 %d%%；开盖或停止时会尝试恢复。", brightnessTargetPercent)
        } else {
            brightnessStatusMessage = "系统未确认亮度已调整；已保留原亮度恢复记录，Perky 会在开盖后检查。"
        }
    }

    private func prepareBrightnessRecordForLidSession() {
        guard brightnessAutomationEnabled, currentLidClosed != true else { return }
        restoreBrightnessIfAppropriate()
        guard var record = brightnessController.captureCurrentBrightness() else {
            brightnessStatusMessage = "无法保存内建屏幕原亮度；亮度自动调节会保持未应用。"
            return
        }
        record.targetValue = BrightnessPolicy.normalizedTarget(brightnessTargetPercent)
        guard persistBrightnessRestoreRecord(record) else {
            brightnessStatusMessage = "无法保存亮度恢复记录；Perky 不会更改屏幕亮度。"
            return
        }
        brightnessStatusMessage = "已保存内建屏幕原亮度；合盖确认后才会调暗。"
    }

    private func restoreBrightnessIfAppropriate() {
        guard let record = brightnessRestoreRecord else { return }
        guard let current = brightnessController.currentBrightness(displayID: record.displayID) else {
            brightnessStatusMessage = "无法读取内建屏幕亮度；恢复记录已保存，开盖后会重试。"
            return
        }

        if abs(current - record.originalValue) <= 0.025 {
            clearBrightnessRestoreRecord()
            brightnessStatusMessage = "内建屏幕亮度保持原值。"
            return
        }
        let wasSetByPerky = abs(current - record.targetValue) <= 0.035
            || record.lastAppliedValue.map { abs(current - $0) <= 0.035 } == true
        guard wasSetByPerky else {
            clearBrightnessRestoreRecord()
            brightnessStatusMessage = "检测到你手动调整了亮度；Perky 保留了你的最新设置。"
            return
        }
        guard brightnessController.setBrightness(record.originalValue, displayID: record.displayID) else {
            brightnessStatusMessage = "未能恢复原亮度；恢复记录已保存，可开盖后重试。"
            return
        }
        clearBrightnessRestoreRecord()
        brightnessStatusMessage = "内建屏幕已恢复到原亮度。"
    }

    private func persistBrightnessRestoreRecord(_ record: BrightnessRestoreRecord) -> Bool {
        guard let data = try? PropertyListEncoder().encode(record) else { return false }
        userDefaults.set(data, forKey: brightnessRestoreRecordKey)
        guard userDefaults.synchronize() else { return false }
        brightnessRestoreRecord = record
        return true
    }

    private func clearBrightnessRestoreRecord() {
        brightnessRestoreRecord = nil
        userDefaults.removeObject(forKey: brightnessRestoreRecordKey)
        userDefaults.synchronize()
    }

    private func sendSafetyStopNotification(_ message: String) {
        guard notificationsEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "Perky 已按电量保护停止"
        content.body = message
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: stopFailureNotificationIdentifier,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func scheduleExpiry() {
        expiryWorkItem?.cancel()
        guard let deadline else { return }
        let expectedSession = sessionID
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.sessionID == expectedSession, self.isRunning else { return }
            self.stop(reason: .expired)
        }
        expiryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline.timeIntervalSinceNow), execute: workItem)
    }

    private func scheduleStopRetry(reason: StopReason, additionalFailure: String? = nil) {
        let expectedSession = sessionID
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.sessionID == expectedSession, self.isStopping else { return }
            self.stop(reason: reason, additionalFailure: additionalFailure)
        }
    }

    private func startAccessibilityRefreshTimer() {
        accessibilityRefreshTimer?.invalidate()
        accessibilityRefreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshMenuBarRemainingText() }
        }
    }

    private func refreshMenuBarRemainingText() {
        menuBarRemainingText = Self.formatCompactDuration(remainingSeconds(at: Date()))
    }

    private func scheduleEndNotification() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notificationIdentifier])
        guard notificationsEnabled, let deadline else { return }

        let content = UNMutableNotificationContent()
        content.title = "Perky 已结束保持唤醒"
        content.body = "计时结束，Mac 已恢复原有睡眠行为。"
        content.sound = .default
        let interval = max(1, deadline.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(identifier: notificationIdentifier, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                self?.notificationMessage = "无法安排到期通知：\(error.localizedDescription)"
            }
        }
    }

    private func notifyStopFailureIfAllowed(_ message: String) {
        guard notificationsEnabled, !didNotifyStopFailure else { return }
        didNotifyStopFailure = true
        let content = UNMutableNotificationContent()
        content.title = "Perky 正在重试停止"
        content.body = message
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(
            identifier: stopFailureNotificationIdentifier,
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                self?.notificationMessage = "无法发送停止失败通知：\(error.localizedDescription)"
            }
        }
    }

    private func persistDurationPreferences() {
        userDefaults.set(selectedMinutes, forKey: selectedMinutesKey)
        userDefaults.set(isCustomDurationSelected, forKey: customSelectedKey)
        if let customMinutes = Int(customMinutesText), (1...1440).contains(customMinutes) {
            userDefaults.set(customMinutes, forKey: customMinutesKey)
        }
    }

    private static func formatDuration(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }

    private static func formatCompactDuration(_ seconds: Int) -> String {
        let minutes = max(0, Int(ceil(Double(seconds) / 60)))
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if hours > 0 {
            return "\(hours) 小时 \(remainingMinutes) 分"
        }
        return "\(remainingMinutes) 分钟"
    }

    private enum StopReason {
        case manual
        case expired
        case startFailure
        case wakeRecovery
        case quit
        case safety(String)
    }
}
