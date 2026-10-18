import AppKit
import CoreFoundation
import CoreGraphics
import IOKit
import IOKit.pwr_mgt
import IOKit.ps

public struct LidModeSnapshot: Equatable {
    public let hasLidSensor: Bool
    public let isLidClosed: Bool?
    public let clamshellWillSleep: Bool?
    public let systemSleepDisabled: Bool?
    public let hasExternalDisplay: Bool
    public let isOnACPower: Bool
    public let batteryPercent: Int?
    public let isLowPowerModeEnabled: Bool

    public init(
        hasLidSensor: Bool,
        isLidClosed: Bool?,
        clamshellWillSleep: Bool?,
        systemSleepDisabled: Bool?,
        hasExternalDisplay: Bool,
        isOnACPower: Bool,
        batteryPercent: Int?,
        isLowPowerModeEnabled: Bool
    ) {
        self.hasLidSensor = hasLidSensor
        self.isLidClosed = isLidClosed
        self.clamshellWillSleep = clamshellWillSleep
        self.systemSleepDisabled = systemSleepDisabled
        self.hasExternalDisplay = hasExternalDisplay
        self.isOnACPower = isOnACPower
        self.batteryPercent = batteryPercent
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
    }

    public var canUseAppleClamshellMode: Bool {
        hasLidSensor && hasExternalDisplay && isOnACPower
    }

    public var readinessMessage: String {
        if !hasLidSensor {
            return "无法读取合盖状态。"
        }
        if !isOnACPower {
            return "电池供电 · 低电量或热压力过高时自动停止；Apple 原生合盖桌面模式需接电源。"
        }
        if !hasExternalDisplay {
            return "未检测到外接显示器 · 将尝试软件合盖策略；此路径需按机型验证。"
        }
        return "已接电源并检测到外接显示器；还需连接外接键盘和鼠标或触控板。"
    }

    public static func current() -> LidModeSnapshot {
        let rootDomain = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPMrootDomain")
        )
        let isLidClosed = booleanProperty(rootDomain, key: "AppleClamshellState")
        let clamshellWillSleep = booleanProperty(rootDomain, key: "AppleClamshellCausesSleep")
        let systemSleepDisabled = booleanProperty(rootDomain, key: "SleepDisabled")
        let hasLidSensor = isLidClosed != nil || clamshellWillSleep != nil
        if rootDomain != IO_OBJECT_NULL {
            IOObjectRelease(rootDomain)
        }

        let isOnACPower = powerSourceType() == (kIOPMACPowerKey as String)
        return LidModeSnapshot(
            hasLidSensor: hasLidSensor,
            isLidClosed: isLidClosed,
            clamshellWillSleep: clamshellWillSleep,
            systemSleepDisabled: systemSleepDisabled,
            hasExternalDisplay: hasExternalDisplay(),
            isOnACPower: isOnACPower,
            batteryPercent: batteryPercent(),
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }

    private static func booleanProperty(_ service: io_service_t, key: String) -> Bool? {
        guard service != IO_OBJECT_NULL,
              let value = IORegistryEntryCreateCFProperty(
                service,
                key as CFString,
                kCFAllocatorDefault,
                0
              )?.takeRetainedValue() as? NSNumber else {
            return nil
        }
        return value.boolValue
    }

    private static func powerSourceType() -> String? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return nil }
        return IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String?
    }

    private static func batteryPercent() -> Int? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }

        for source in sources {
            guard let rawDescription = IOPSGetPowerSourceDescription(snapshot, source),
                  let description = rawDescription.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey as String] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey as String] as? NSNumber,
                  let maximum = description[kIOPSMaxCapacityKey as String] as? NSNumber,
                  maximum.intValue > 0 else {
                continue
            }
            return min(100, max(0, Int((Double(current.intValue) / Double(maximum.intValue) * 100).rounded())))
        }
        return nil
    }

    private static func hasExternalDisplay() -> Bool {
        let maximumDisplays: UInt32 = 32
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(maximumDisplays))
        var displayCount: UInt32 = 0
        guard CGGetOnlineDisplayList(maximumDisplays, &displays, &displayCount) == .success else {
            return false
        }
        return displays.prefix(Int(displayCount)).contains { CGDisplayIsBuiltin($0) == 0 }
    }
}

public enum DurationPolicy {
    public static let validMinutes = 1...1440
    public static let quickChoices = [15, 30, 60]

    public static func parseCustomMinutes(_ text: String) -> Int? {
        guard let value = Int(text), validMinutes.contains(value) else { return nil }
        return value
    }

    public static func clampedStoredMinutes(_ value: Int) -> Int {
        min(max(value, validMinutes.lowerBound), validMinutes.upperBound)
    }
}

public enum BatterySafetyPolicy {
    public static func failureMessage(
        for snapshot: LidModeSnapshot,
        thresholdPercent: Int,
        whileRunning: Bool = true
    ) -> String? {
        guard !snapshot.isOnACPower else { return nil }
        guard let battery = snapshot.batteryPercent else {
            return whileRunning
                ? "无法读取电池电量，已停止合盖模式以保护电池。"
                : "无法确认当前电量。为保护电池，Perky 没有启动合盖模式。"
        }
        if snapshot.isLowPowerModeEnabled {
            return whileRunning
                ? "电池供电时进入低电量模式，已停止保持唤醒并恢复系统睡眠。"
                : "电池供电时已启用低电量模式。请接入电源或关闭低电量模式后再启动。"
        }
        if battery <= thresholdPercent {
            return whileRunning
                ? String(format: "电量达到 %d%%，已停止保持唤醒并恢复系统睡眠。", thresholdPercent)
                : String(format: "当前电量为 %d%%，已达到自动停止阈值 %d%%。请接入电源后再启动。", battery, thresholdPercent)
        }
        return nil
    }
}

public enum BrightnessPolicy {
    public static func clampedTargetPercent(_ value: Int) -> Int {
        min(max(value, 5), 30)
    }

    public static func normalizedTarget(_ percent: Int) -> Float {
        Float(clampedTargetPercent(percent)) / 100
    }
}

public enum HelperServiceAuthorizationState: Equatable {
    case enabled
    case requiresApproval
    case notRegistered
    case notFound
    case unknown
}

public enum HelperAuthorizationSettingsPolicy {
    public static func shouldOpenLoginItems(
        state: HelperServiceAuthorizationState,
        hasTrustedSigningIdentity: Bool,
        initiatedByUser: Bool
    ) -> Bool {
        if initiatedByUser && !hasTrustedSigningIdentity { return true }
        guard state != .enabled else { return false }
        return hasTrustedSigningIdentity && state == .requiresApproval
    }
}
