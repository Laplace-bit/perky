import AppKit
import CoreFoundation
import IOKit
import IOKit.pwr_mgt

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
