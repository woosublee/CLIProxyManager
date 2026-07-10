import CryptoKit
import Foundation
import XCTest
@testable import CLIProxyManagerCore

final class SparkleSignatureVerifierTests: XCTestCase {
    func testAcceptsMatchingSignatureAndLength() throws {
        let artifact = Data("dmg bytes".utf8)
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
        let signature = try key.signature(for: artifact)

        XCTAssertNoThrow(try SparkleSignatureVerifier().verify(
            artifact: artifact,
            expectedLength: artifact.count,
            base64Signature: signature.base64EncodedString(),
            base64PublicKey: key.publicKey.rawRepresentation.base64EncodedString()
        ))
    }

    func testRejectsOneByteTamperedArtifact() throws {
        let artifact = Data("dmg bytes".utf8)
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
        let signature = try key.signature(for: artifact)

        XCTAssertThrowsError(try SparkleSignatureVerifier().verify(
            artifact: Data("dmg byteX".utf8),
            expectedLength: artifact.count,
            base64Signature: signature.base64EncodedString(),
            base64PublicKey: key.publicKey.rawRepresentation.base64EncodedString()
        ))
    }

    func testRejectsWrongLength() throws {
        let artifact = Data("dmg bytes".utf8)
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
        let signature = try key.signature(for: artifact)

        XCTAssertThrowsError(try SparkleSignatureVerifier().verify(
            artifact: artifact,
            expectedLength: artifact.count + 1,
            base64Signature: signature.base64EncodedString(),
            base64PublicKey: key.publicKey.rawRepresentation.base64EncodedString()
        )) { error in
            XCTAssertEqual(error as? CLIProxyManagerCommandError, .operation("Downloaded app update length does not match appcast metadata."))
        }
    }

    func testRejectsInvalidBase64Signature() throws {
        let artifact = Data("dmg bytes".utf8)
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))

        XCTAssertThrowsError(try SparkleSignatureVerifier().verify(
            artifact: artifact,
            expectedLength: artifact.count,
            base64Signature: "not-valid-base64!!!",
            base64PublicKey: key.publicKey.rawRepresentation.base64EncodedString()
        ))
    }

    func testRejectsSignatureFromWrongKey() throws {
        let artifact = Data("dmg bytes".utf8)
        let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 7, count: 32))
        let wrongKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 8, count: 32))
        let signature = try signingKey.signature(for: artifact)

        XCTAssertThrowsError(try SparkleSignatureVerifier().verify(
            artifact: artifact,
            expectedLength: artifact.count,
            base64Signature: signature.base64EncodedString(),
            base64PublicKey: wrongKey.publicKey.rawRepresentation.base64EncodedString()
        )) { error in
            XCTAssertEqual(error as? CLIProxyManagerCommandError, .operation("Downloaded app update signature is invalid."))
        }
    }
}
