import ServiceManagement

protocol LoginItemControlling: Sendable {
    func setStartAtLoginEnabled(_ isEnabled: Bool) throws
}

struct LoginItemService: LoginItemControlling {
    func setStartAtLoginEnabled(_ isEnabled: Bool) throws {
        if isEnabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
