import CLIProxyManagerCore
import Foundation

let output = TerminalCommandOutput()
do {
    try await CLIProxyManagerCommand(output: output)
        .run(arguments: Array(CommandLine.arguments.dropFirst()))
} catch let error as CLIProxyManagerCommandError {
    output.writeStderr("\(error.description)\n")
    exit(error.exitCode.rawValue)
} catch {
    output.writeStderr("\(error.localizedDescription)\n")
    exit(CLICommandExitCode.failure.rawValue)
}
