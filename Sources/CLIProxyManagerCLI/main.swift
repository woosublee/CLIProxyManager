import CLIProxyManagerCore
import Foundation

do {
    try CLIProxyManagerCommand().run(arguments: Array(CommandLine.arguments.dropFirst()))
} catch let error as CLIProxyManagerCommandError {
    fputs("\(error.description)\n", stderr)
    exit(EXIT_FAILURE)
} catch let error as SecretStoreError {
    fputs("\(error.description)\n", stderr)
    exit(EXIT_FAILURE)
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(EXIT_FAILURE)
}
