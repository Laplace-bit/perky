import ServiceManagement

@MainActor
public enum LoginItemsSettingsOpener {
    public static func open() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
