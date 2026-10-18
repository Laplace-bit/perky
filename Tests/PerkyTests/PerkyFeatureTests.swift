import XCTest
@testable import Perky

final class PerkyFeatureTests: XCTestCase {
    func testLidModeReadinessRequiresSensorExternalDisplayAndPower() {
        let ready = LidModeSnapshot(
            hasLidSensor: true,
            isLidClosed: false,
            clamshellWillSleep: false,
            systemSleepDisabled: false,
            hasExternalDisplay: true,
            isOnACPower: true,
            batteryPercent: 100,
            isLowPowerModeEnabled: false
        )
        XCTAssertTrue(ready.canUseAppleClamshellMode)

        let onBattery = LidModeSnapshot(
            hasLidSensor: true,
            isLidClosed: false,
            clamshellWillSleep: false,
            systemSleepDisabled: false,
            hasExternalDisplay: true,
            isOnACPower: false,
            batteryPercent: 80,
            isLowPowerModeEnabled: false
        )
        XCTAssertFalse(onBattery.canUseAppleClamshellMode)
        XCTAssertEqual(onBattery.readinessMessage, "电池供电 · 低电量时自动停止。")
    }

    func testPowerAssertionLifecycleAgainstMacOS() {
        var controller = PowerAssertionController()
        XCTAssertFalse(controller.hasAssertion)

        switch controller.start(timeoutSeconds: 20) {
        case .success:
            break
        case .failure(let error):
            XCTFail("Could not create the macOS power assertion: \(error)")
            return
        }

        XCTAssertTrue(controller.hasAssertion)
        XCTAssertTrue(controller.isActive)

        if case .failure(let error) = controller.updateTimeout(seconds: 25) {
            XCTFail("Could not update assertion timeout: \(error)")
        }
        XCTAssertTrue(controller.isActive)

        if case .failure(let error) = controller.stop() {
            XCTFail("Could not release the macOS power assertion: \(error)")
        }
        XCTAssertFalse(controller.hasAssertion)
    }
}
