import ServiceManagement

/// Launch-at-login via the system login items list. Needs the app to live in /Applications.
enum LoginItem {
    enum Status: Equatable {
        case enabled
        case requiresApproval
        case notRegistered
        case notFound
    }

    static var status: Status {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .notRegistered
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    static var isEnabled: Bool { status == .enabled }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func guidance(for error: Error?) -> String {
        switch status {
        case .requiresApproval:
            return "LabTunnel is registered, but macOS requires approval in System Settings -> General -> Login Items."
        case .notFound:
            return "Move LabTunnel.app to /Applications before enabling Launch at Login, then approve it in System Settings -> General -> Login Items if prompted."
        case .enabled, .notRegistered:
            if let error {
                return "Could not update Launch at Login (\(error.localizedDescription)). Make sure LabTunnel.app is in /Applications and allowed under System Settings -> General -> Login Items."
            }
            return "Make sure LabTunnel.app is in /Applications and allowed under System Settings -> General -> Login Items."
        }
    }
}
