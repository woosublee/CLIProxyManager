import CryptoKit
import Foundation

public struct SparkleSignatureVerifier: Sendable {
    public init() {}

    public func verify(
        artifact: Data,
        expectedLength: Int,
        base64Signature: String,
        base64PublicKey: String
    ) throws {
        guard artifact.count == expectedLength else {
            throw CLIProxyManagerCommandError.operation("Downloaded app update length does not match appcast metadata.")
        }
        guard let keyData = Data(base64Encoded: base64PublicKey),
              let sigData = Data(base64Encoded: base64Signature) else {
            throw CLIProxyManagerCommandError.operation("Downloaded app update signature is invalid.")
        }
        let publicKey: Curve25519.Signing.PublicKey
        do {
            publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
        } catch {
            throw CLIProxyManagerCommandError.operation("Downloaded app update signature is invalid.")
        }
        guard publicKey.isValidSignature(sigData, for: artifact) else {
            throw CLIProxyManagerCommandError.operation("Downloaded app update signature is invalid.")
        }
    }
}
