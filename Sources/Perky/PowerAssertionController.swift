import CoreFoundation
import Foundation
import IOKit.pwr_mgt

enum PowerAssertionFailure: LocalizedError {
    case createFailed(IOReturn)
    case verificationFailed
    case timeoutUpdateFailed(IOReturn)
    case releaseFailed(IOReturn)

    var errorDescription: String? {
        switch self {
        case .createFailed(let status):
            return "macOS 无法创建防睡眠断言（\(Self.statusCode(status))）。请稍后重试。"
        case .verificationFailed:
            return "macOS 未确认防睡眠断言已生效。Perky 没有开始计时，请重试。"
        case .timeoutUpdateFailed(let status):
            return "macOS 未能更新断言的到期时间（\(Self.statusCode(status))）。当前计时保持不变。"
        case .releaseFailed(let status):
            return "macOS 尚未确认防睡眠断言已释放（\(Self.statusCode(status))）。Perky 会继续尝试停止。"
        }
    }

    private static func statusCode(_ status: IOReturn) -> String {
        String(format: "0x%08x", status)
    }
}

struct PowerAssertionController {
    private(set) var assertionID: IOPMAssertionID?

    var hasAssertion: Bool { assertionID != nil }

    var isActive: Bool {
        guard let assertionID else { return false }
        return verifiedProperties(for: assertionID) != nil
    }

    mutating func start(timeoutSeconds: Int) -> Result<Void, PowerAssertionFailure> {
        guard assertionID == nil else {
            return isActive ? .success(()) : .failure(.verificationFailed)
        }

        let properties: [String: Any] = [
            kIOPMAssertionTypeKey as String: kIOPMAssertionTypePreventUserIdleSystemSleep,
            kIOPMAssertionLevelKey as String: kIOPMAssertionLevelOn,
            kIOPMAssertionNameKey as String: "Perky timed idle sleep prevention",
            kIOPMAssertionTimeoutKey as String: NSNumber(value: timeoutSeconds),
            kIOPMAssertionTimeoutActionKey as String: kIOPMAssertionTimeoutActionRelease
        ]

        var createdID: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithProperties(properties as CFDictionary, &createdID)
        guard status == kIOReturnSuccess else {
            return .failure(.createFailed(status))
        }

        guard verifiedProperties(for: createdID) != nil else {
            let releaseStatus = IOPMAssertionRelease(createdID)
            if releaseStatus != kIOReturnSuccess, copyProperties(for: createdID) != nil {
                assertionID = createdID
                return .failure(.releaseFailed(releaseStatus))
            }
            return .failure(.verificationFailed)
        }

        assertionID = createdID
        return .success(())
    }

    mutating func resume(timeoutSeconds: Int) -> Result<Void, PowerAssertionFailure> {
        guard let assertionID else { return start(timeoutSeconds: timeoutSeconds) }
        if isActive { return updateTimeout(seconds: timeoutSeconds) }

        guard let timeout = Self.number(Int32(timeoutSeconds)) else {
            return .failure(.verificationFailed)
        }
        let timeoutStatus = IOPMAssertionSetProperty(assertionID, kIOPMAssertionTimeoutKey as CFString, timeout)
        guard timeoutStatus == kIOReturnSuccess else {
            return .failure(.timeoutUpdateFailed(timeoutStatus))
        }

        guard let level = Self.number(Int32(kIOPMAssertionLevelOn)) else {
            return .failure(.verificationFailed)
        }
        let levelStatus = IOPMAssertionSetProperty(assertionID, kIOPMAssertionLevelKey as CFString, level)
        guard levelStatus == kIOReturnSuccess else {
            return .failure(.verificationFailed)
        }
        guard verifiedProperties(for: assertionID) != nil else {
            return .failure(.verificationFailed)
        }
        return .success(())
    }

    mutating func updateTimeout(seconds: Int) -> Result<Void, PowerAssertionFailure> {
        guard let assertionID else { return .failure(.verificationFailed) }
        var value = Int32(seconds)
        guard let timeout = CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &value) else {
            return .failure(.verificationFailed)
        }

        let status = IOPMAssertionSetProperty(assertionID, kIOPMAssertionTimeoutKey as CFString, timeout)
        guard status == kIOReturnSuccess else {
            return .failure(.timeoutUpdateFailed(status))
        }
        guard verifiedProperties(for: assertionID) != nil else {
            return .failure(.verificationFailed)
        }
        return .success(())
    }

    mutating func stop() -> Result<Void, PowerAssertionFailure> {
        guard let assertionID else { return .success(()) }
        let status = IOPMAssertionRelease(assertionID)
        if status == kIOReturnSuccess || copyProperties(for: assertionID) == nil {
            self.assertionID = nil
            return .success(())
        }
        return .failure(.releaseFailed(status))
    }

    private func verifiedProperties(for assertionID: IOPMAssertionID) -> NSDictionary? {
        guard let properties = copyProperties(for: assertionID) else {
            return nil
        }
        let type = properties[kIOPMAssertionTypeKey as String] as? String
        let level = properties[kIOPMAssertionLevelKey as String] as? NSNumber
        guard
            type == (kIOPMAssertionTypePreventUserIdleSystemSleep as String),
            level?.intValue == Int(kIOPMAssertionLevelOn)
        else {
            return nil
        }
        return properties
    }

    private func copyProperties(for assertionID: IOPMAssertionID) -> NSDictionary? {
        guard let unmanagedProperties = IOPMAssertionCopyProperties(assertionID) else {
            return nil
        }
        return unmanagedProperties.takeRetainedValue() as NSDictionary
    }

    private static func number(_ value: Int32) -> CFNumber? {
        var number = value
        return CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &number)
    }
}
