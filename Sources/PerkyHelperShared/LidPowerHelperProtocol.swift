import Foundation

@objc public protocol LidPowerHelperProtocol {
    func startSession(
        identifier: String,
        deadline: Date,
        batteryThresholdPercent: Int,
        reply: @escaping (Bool, String?) -> Void
    )
    func stopSession(identifier: String, reply: @escaping (Bool, String?) -> Void)
    func resolveConflict(identifier: String, restoreOriginal: Bool, reply: @escaping (Bool, String?) -> Void)
    func discardUnreadableRecoveryRecord(reply: @escaping (Bool, String?) -> Void)
    func getStatus(reply: @escaping (String?, Date?, Bool, String?) -> Void)
}
