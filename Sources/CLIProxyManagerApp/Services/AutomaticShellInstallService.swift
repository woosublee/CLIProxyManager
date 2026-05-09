import CLIProxyManagerCore

struct AutomaticShellInstallService: Sendable {
    private let installer: any ShellFunctionInstalling
    private let helperCommand: String

    init(installer: any ShellFunctionInstalling, helperCommand: String = "/usr/local/bin/cliproxy-manager") {
        self.installer = installer
        self.helperCommand = helperCommand
    }

    func apply(config: AppConfig) throws {
        let script = try ShellFunctionRenderer(config: config, helperCommand: helperCommand).render()
        try installer.install(
            functionScript: script,
            functionNames: [config.commands.cc, config.commands.ccapi, config.commands.ccodex]
        )
    }
}
