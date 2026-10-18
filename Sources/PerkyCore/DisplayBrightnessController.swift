import CoreGraphics
import Darwin
import Foundation

/// DisplayServices is a private SPI. We load it dynamically and only expose the
/// feature on the macOS major version that has been checked in this project.
public final class DisplayBrightnessController {
    public static let shared = DisplayBrightnessController()

    private typealias CanChangeBrightness = @convention(c) (UInt32) -> Bool
    private typealias GetBrightness = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (UInt32, Float) -> Int32

    private struct Functions {
        let canChange: CanChangeBrightness
        let get: GetBrightness
        let set: SetBrightness
    }

    private var frameworkHandle: UnsafeMutableRawPointer?
    private var functions: Functions?

    private init() {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26 else { return }
        frameworkHandle = dlopen(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            RTLD_NOW | RTLD_LOCAL
        )
        guard let frameworkHandle,
              let canChangeSymbol = dlsym(frameworkHandle, "DisplayServicesCanChangeBrightness"),
              let getSymbol = dlsym(frameworkHandle, "DisplayServicesGetBrightness"),
              let setSymbol = dlsym(frameworkHandle, "DisplayServicesSetBrightness") else {
            return
        }
        functions = Functions(
            canChange: unsafeBitCast(canChangeSymbol, to: CanChangeBrightness.self),
            get: unsafeBitCast(getSymbol, to: GetBrightness.self),
            set: unsafeBitCast(setSymbol, to: SetBrightness.self)
        )
    }

    public var availabilityMessage: String {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26 else {
            return "亮度接口目前只在 macOS 26.x 完成运行时验证。"
        }
        guard let displayID = builtInDisplayID(), currentBrightness(displayID: displayID) != nil else {
            return "当前内建屏幕没有可用的亮度控制接口。"
        }
        return "内建屏幕亮度接口可用；外接显示器不受控制。"
    }

    public var isAvailable: Bool {
        guard let displayID = builtInDisplayID(),
              let functions,
              functions.canChange(displayID) else {
            return false
        }
        return currentBrightness(displayID: displayID) != nil
    }

    public func captureCurrentBrightness() -> BrightnessRestoreRecord? {
        guard let displayID = builtInDisplayID(),
              let value = currentBrightness(displayID: displayID) else {
            return nil
        }
        return BrightnessRestoreRecord(
            displayID: displayID,
            originalValue: value,
            targetValue: 0.1,
            lastAppliedValue: nil
        )
    }

    public func currentBrightness(displayID: UInt32) -> Float? {
        guard let functions, functions.canChange(displayID) else { return nil }
        var value: Float = 0
        guard functions.get(displayID, &value) == 0, value.isFinite, (0...1).contains(value) else {
            return nil
        }
        return value
    }

    public func setBrightness(_ value: Float, displayID: UInt32) -> Bool {
        guard value.isFinite, (0...1).contains(value),
              let functions, functions.canChange(displayID),
              functions.set(displayID, value) == 0 else {
            return false
        }
        guard let actual = currentBrightness(displayID: displayID) else { return false }
        return abs(actual - value) <= 0.025
    }

    private func builtInDisplayID() -> UInt32? {
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 16)
        var displayCount: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &displayIDs, &displayCount) == .success else {
            return nil
        }
        return displayIDs.prefix(Int(displayCount)).first(where: { CGDisplayIsBuiltin($0) != 0 })
    }
}

public struct BrightnessRestoreRecord: Codable {
    public let displayID: UInt32
    public let originalValue: Float
    public var targetValue: Float
    public var lastAppliedValue: Float?

    public init(displayID: UInt32, originalValue: Float, targetValue: Float, lastAppliedValue: Float?) {
        self.displayID = displayID
        self.originalValue = originalValue
        self.targetValue = targetValue
        self.lastAppliedValue = lastAppliedValue
    }
}
