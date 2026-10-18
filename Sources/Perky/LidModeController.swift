import AppKit
import CoreFoundation
import IOKit
import IOKit.pwr_mgt
import IOKit.ps

struct LidModeSnapshot: Equatable {
    let hasLidSensor: Bool
    let isLidClosed: Bool?
    let clamshellWillSleep: Bool?
    let systemSleepDisabled: Bool?
    let hasExternalDisplay: Bool
    let isOnACPower: Bool
    let batteryPercent: Int?
    let isLowPowerModeEnabled: Bool

    var canUseAppleClamshellMode: Bool {
        hasLidSensor && hasExternalDisplay && isOnACPower
    }

    var readinessMessage: String {
        if !hasLidSensor {
            return "无法读取合盖状态。"
        }
        if !isOnACPower {
            return "电池供电 · 低电量时自动停止。"
        }
        if !hasExternalDisplay {
            return "未检测到外接显示器。"
        }
        return "电源与外接显示器已就绪。"
    }

    static func current() -> LidModeSnapshot {
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

@MainActor
final class ClamshellStateObserver {
    private var notificationPort: IONotificationPortRef?
    private var service: io_service_t = IO_OBJECT_NULL
    private var notification: io_object_t = IO_OBJECT_NULL
    var onChange: (() -> Void)?

    func start(onChange: @escaping () -> Void) {
        guard notificationPort == nil else { return }
        self.onChange = onChange

        service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPMrootDomain")
        )
        guard service != IO_OBJECT_NULL,
              let port = IONotificationPortCreate(kIOMainPortDefault) else {
            stop()
            return
        }
        notificationPort = port

        let result = IOServiceAddInterestNotification(
            port,
            service,
            "IOGeneralInterest",
            clamshellInterestCallback,
            Unmanaged.passUnretained(self).toOpaque(),
            &notification
        )
        guard result == kIOReturnSuccess,
              let unmanagedSource = IONotificationPortGetRunLoopSource(port) else {
            stop()
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), unmanagedSource.takeUnretainedValue(), .commonModes)
    }

    func stop() {
        if notification != IO_OBJECT_NULL {
            IOObjectRelease(notification)
            notification = IO_OBJECT_NULL
        }
        if service != IO_OBJECT_NULL {
            IOObjectRelease(service)
            service = IO_OBJECT_NULL
        }
        if let notificationPort {
            IONotificationPortDestroy(notificationPort)
            self.notificationPort = nil
        }
        onChange = nil
    }

}

private let clamshellInterestCallback: IOServiceInterestCallback = { refcon, _, _, _ in
    guard let refcon else { return }
    let observer = Unmanaged<ClamshellStateObserver>.fromOpaque(refcon).takeUnretainedValue()
    DispatchQueue.main.async {
        observer.onChange?()
    }
}
