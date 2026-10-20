import Foundation
import AppKit
import PerkyCore

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CheckFailure(description: message) }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) throws {
    guard actual == expected else {
        throw CheckFailure(description: "\(message) — got \(actual), expected \(expected)")
    }
}

@main
@MainActor
private enum PerkyFeatureChecks {
    static func main() {
        var checks: [(String, () throws -> Void)] = [
            ("duration selection and bounds", checkDurationPolicy),
            ("clamshell readiness", checkClamshellReadiness),
            ("battery protection", checkBatterySafetyPolicy),
            ("login item authorization routing", checkAuthorizationSettingsPolicy),
            ("brightness target bounds", checkBrightnessPolicy),
            ("read-only hardware capability probes", checkHardwareCapabilities),
            ("system sleep-disabled probe consistency", checkSleepDisabledProbe),
            ("macOS power assertion lifecycle", checkPowerAssertionLifecycle)
        ]
        if CommandLine.arguments.contains("--system-smoke") {
            checks.append(("System Settings Login Items launch", checkLoginItemsSystemSmoke))
        }

        var failures: [String] = []
        for (name, check) in checks {
            do {
                try check()
                print("PASS  \(name)")
            } catch {
                failures.append("FAIL  \(name): \(error)")
            }
        }

        for failure in failures { fputs("\(failure)\n", stderr) }
        print("\(checks.count - failures.count)/\(checks.count) feature checks passed")
        if !failures.isEmpty { exit(EXIT_FAILURE) }
    }

    private static func checkDurationPolicy() throws {
        try expectEqual(DurationPolicy.quickChoices, [15, 30, 60], "quick duration choices")
        try expectEqual(DurationPolicy.parseCustomMinutes("1"), 1, "minimum custom duration")
        try expectEqual(DurationPolicy.parseCustomMinutes("1440"), 1440, "maximum custom duration")
        try expect(DurationPolicy.parseCustomMinutes("0") == nil, "zero minutes must be rejected")
        try expect(DurationPolicy.parseCustomMinutes("1441") == nil, "values above one day must be rejected")
        try expect(DurationPolicy.parseCustomMinutes("abc") == nil, "non-integer input must be rejected")
        try expectEqual(DurationPolicy.clampedStoredMinutes(-4), 1, "stored duration lower bound")
        try expectEqual(DurationPolicy.clampedStoredMinutes(2000), 1440, "stored duration upper bound")
    }

    private static func checkClamshellReadiness() throws {
        let ready = snapshot(sensor: true, externalDisplay: true, acPower: true)
        try expect(ready.canUseAppleClamshellMode, "sensor, external display and AC power should be required")
        try expectEqual(
            ready.readinessMessage,
            "已接电源并检测到外接显示器；合盖后会话会继续运行。",
            "ready-state message"
        )

        let noSensor = snapshot(sensor: false, externalDisplay: true, acPower: true)
        try expect(!noSensor.canUseAppleClamshellMode, "clamshell mode must reject a missing lid sensor")
        try expectEqual(noSensor.readinessMessage, "无法读取合盖状态。", "missing sensor message")

        let noDisplay = snapshot(sensor: true, externalDisplay: false, acPower: true)
        try expect(!noDisplay.canUseAppleClamshellMode, "clamshell mode must reject a missing external display")
        try expectEqual(
            noDisplay.readinessMessage,
            "未检测到外接显示器 · 将启用系统级防睡眠，合盖后会话继续运行。",
            "missing display message"
        )

        let onBattery = snapshot(sensor: true, externalDisplay: true, acPower: false)
        try expect(!onBattery.canUseAppleClamshellMode, "clamshell mode must reject AC disconnection")
        try expectEqual(
            onBattery.readinessMessage,
            "电池供电 · 合盖运行会持续耗电；达到停止阈值、进入低电量模式或热压力过高时自动停止。",
            "battery message"
        )
    }

    private static func checkBatterySafetyPolicy() throws {
        let acWithLowBattery = snapshot(sensor: true, externalDisplay: true, acPower: true, battery: 1, lowPower: true)
        try expect(BatterySafetyPolicy.failureMessage(for: acWithLowBattery, thresholdPercent: 15) == nil,
                   "AC power should not be blocked by battery percentage or Low Power Mode")

        let healthyBattery = snapshot(sensor: true, externalDisplay: true, acPower: false, battery: 80)
        try expect(BatterySafetyPolicy.failureMessage(for: healthyBattery, thresholdPercent: 15) == nil,
                   "healthy battery should pass the safety threshold")

        let atThreshold = snapshot(sensor: true, externalDisplay: true, acPower: false, battery: 15)
        try expect(BatterySafetyPolicy.failureMessage(for: atThreshold, thresholdPercent: 15) != nil,
                   "battery at threshold must stop")
        let startMessage = BatterySafetyPolicy.failureMessage(
            for: atThreshold,
            thresholdPercent: 15,
            whileRunning: false
        )
        try expect(
            startMessage?.contains("当前电量为") == true && startMessage?.contains("已停止") == false,
            "start-time message must describe the current battery without claiming a session stopped"
        )
        let runningMessage = BatterySafetyPolicy.failureMessage(for: atThreshold, thresholdPercent: 15)
        try expect(runningMessage?.contains("已停止") == true, "runtime safety message should report automatic stop")

        let unknownBattery = snapshot(sensor: true, externalDisplay: true, acPower: false, battery: nil)
        try expect(BatterySafetyPolicy.failureMessage(for: unknownBattery, thresholdPercent: 15) != nil,
                   "unknown battery level must fail safe")

        let lowPower = snapshot(sensor: true, externalDisplay: true, acPower: false, battery: 80, lowPower: true)
        try expect(BatterySafetyPolicy.failureMessage(for: lowPower, thresholdPercent: 15) != nil,
                   "Low Power Mode on battery must stop")
    }

    private static func checkAuthorizationSettingsPolicy() throws {
        try expect(
            HelperAuthorizationSettingsPolicy.shouldOpenLoginItems(
                state: .notRegistered,
                hasTrustedSigningIdentity: false,
                initiatedByUser: true
            ),
            "an explicit request should open Login Items even when this build cannot register"
        )
        try expect(
            HelperAuthorizationSettingsPolicy.shouldOpenLoginItems(
                state: .enabled,
                hasTrustedSigningIdentity: false,
                initiatedByUser: true
            ),
            "an explicit request from an untrusted build should still reveal the relevant settings panel"
        )
        try expect(
            !HelperAuthorizationSettingsPolicy.shouldOpenLoginItems(
                state: .notRegistered,
                hasTrustedSigningIdentity: false,
                initiatedByUser: false
            ),
            "settings must not open without user intent when the helper is not registered"
        )
        try expect(
            HelperAuthorizationSettingsPolicy.shouldOpenLoginItems(
                state: .requiresApproval,
                hasTrustedSigningIdentity: true,
                initiatedByUser: false
            ),
            "a trusted helper requiring approval should route to Login Items"
        )
        try expect(
            !HelperAuthorizationSettingsPolicy.shouldOpenLoginItems(
                state: .notRegistered,
                hasTrustedSigningIdentity: true,
                initiatedByUser: true
            ),
            "trusted but unregistered helper must register before requesting approval"
        )
        try expect(
            !HelperAuthorizationSettingsPolicy.shouldOpenLoginItems(
                state: .enabled,
                hasTrustedSigningIdentity: true,
                initiatedByUser: true
            ),
            "enabled helper should not be routed back to settings"
        )
    }

    private static func checkBrightnessPolicy() throws {
        try expectEqual(BrightnessPolicy.clampedTargetPercent(0), 5, "brightness lower bound")
        try expectEqual(BrightnessPolicy.clampedTargetPercent(100), 30, "brightness upper bound")
        try expectEqual(BrightnessPolicy.normalizedTarget(10), 0.1, "brightness normalization")
    }

    private static func checkHardwareCapabilities() throws {
        let snapshot = LidModeSnapshot.current()
        if let battery = snapshot.batteryPercent {
            try expect((0...100).contains(battery), "reported battery percentage must be within 0–100")
        }
        print("INFO  hardware: lidSensor=\(snapshot.hasLidSensor), externalDisplay=\(snapshot.hasExternalDisplay), acPower=\(snapshot.isOnACPower), battery=\(snapshot.batteryPercent.map(String.init) ?? "unknown")%")

        let brightness = DisplayBrightnessController.shared
        if let record = brightness.captureCurrentBrightness() {
            try expect((0...1).contains(record.originalValue), "read brightness must be normalized")
            let reread = brightness.currentBrightness(displayID: record.displayID)
            try expect(reread != nil && (0...1).contains(reread!), "built-in display brightness should be safely readable")
            print("INFO  brightness: read-only probe available at \(Int((record.originalValue * 100).rounded()))%")
        } else {
            try expect(!brightness.isAvailable, "brightness capability and read result must agree")
            print("INFO  brightness: \(brightness.availabilityMessage)")
        }
    }

    private static func checkSleepDisabledProbe() throws {
        let snapshot = LidModeSnapshot.current()
        guard let snapshotValue = snapshot.systemSleepDisabled else {
            throw CheckFailure(description: "SleepDisabled is not readable from IOPMrootDomain; lid-mode verification would be unreliable")
        }
        guard let pmsetValue = pmsetSleepDisabled() else {
            throw CheckFailure(description: "pmset did not report SleepDisabled")
        }
        try expectEqual(snapshotValue, pmsetValue, "IORegistry SleepDisabled must match pmset")
        print("INFO  sleep disabled: \(snapshotValue ? "enabled" : "disabled")")
    }

    private static func pmsetSleepDisabled() -> Bool? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.first == "SleepDisabled", parts.count > 1 else { continue }
            if parts[1] == "1" { return true }
            if parts[1] == "0" { return false }
        }
        return nil
    }

    private static func checkPowerAssertionLifecycle() throws {
        var controller = PowerAssertionController()
        try expect(!controller.hasAssertion, "new controller should have no assertion")

        if case .failure(let error) = controller.start(timeoutSeconds: 20) {
            throw CheckFailure(description: "create assertion: \(error.localizedDescription)")
        }
        defer { _ = controller.stop() }
        try expect(controller.hasAssertion && controller.isActive, "created assertion should be active")

        if case .failure(let error) = controller.updateTimeout(seconds: 25) {
            throw CheckFailure(description: "update assertion timeout: \(error.localizedDescription)")
        }
        try expect(controller.isActive, "updated assertion should remain active")

        if case .failure(let error) = controller.resume(timeoutSeconds: 25) {
            throw CheckFailure(description: "resume assertion: \(error.localizedDescription)")
        }
        try expect(controller.isActive, "resumed assertion should remain active")

        if case .failure(let error) = controller.stop() {
            throw CheckFailure(description: "release assertion: \(error.localizedDescription)")
        }
        try expect(!controller.hasAssertion && !controller.isActive, "released assertion should be inactive")
    }

    private static func checkLoginItemsSystemSmoke() throws {
        LoginItemsSettingsOpener.open()
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.systempreferences" {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
        throw CheckFailure(description: "System Settings did not become active (frontmost: \(frontmost))")
    }

    private static func snapshot(
        sensor: Bool,
        externalDisplay: Bool,
        acPower: Bool,
        battery: Int? = 80,
        lowPower: Bool = false
    ) -> LidModeSnapshot {
        LidModeSnapshot(
            hasLidSensor: sensor,
            isLidClosed: false,
            clamshellWillSleep: false,
            systemSleepDisabled: false,
            hasExternalDisplay: externalDisplay,
            isOnACPower: acPower,
            batteryPercent: battery,
            isLowPowerModeEnabled: lowPower
        )
    }
}
