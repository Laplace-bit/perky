import AppKit
import SwiftUI
import UserNotifications

@main
struct PerkyApp: App {
    @NSApplicationDelegateAdaptor(PerkyAppDelegate.self) private var appDelegate
    @StateObject private var model = PerkyModel.shared

    var body: some Scene {
        MenuBarExtra {
            PerkyPanelView(model: model)
                .frame(width: 328)
                .padding(16)
        } label: {
            Image(systemName: model.menuBarSymbol)
                .accessibilityLabel(model.menuBarAccessibilityLabel)
                .help(model.menuBarAccessibilityLabel)
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("退出 Perky") {
                    model.requestQuit()
                }
                .keyboardShortcut("q")
            }
        }
    }
}

@MainActor
final class PerkyAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().delegate = self
        PerkyModel.shared.startObservingSystemPowerEvents()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        PerkyModel.shared.prepareForTermination() ? .terminateNow : .terminateCancel
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
