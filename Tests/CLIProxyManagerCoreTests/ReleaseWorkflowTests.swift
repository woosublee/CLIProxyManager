import XCTest

final class ReleaseWorkflowTests: XCTestCase {
    func testReleaseWorkflowBuildsAndUploadsNotarizedDMG() throws {
        let workflow = try String(contentsOf: repositoryRoot().appendingPathComponent(".github/workflows/release.yml"), encoding: .utf8)
        let makefile = try String(contentsOf: repositoryRoot().appendingPathComponent("Makefile"), encoding: .utf8)
        let releaseLocal = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/release-local.sh"), encoding: .utf8)

        XCTAssertTrue(
            makefile.contains("DEVELOPER_ID_IDENTITY := Developer ID Application: Woosub Lee (2L6ZW98RCP)"),
            "Development and local release builds should default to the Developer ID signing identity."
        )
        XCTAssertFalse(
            makefile.contains("cliproxymanager\n"),
            "The retired self-signed cliproxymanager identity must not be a signing default."
        )
        XCTAssertTrue(
            makefile.contains("RELEASE_CODESIGN_IDENTITY ?= $(CODESIGN_IDENTITY)"),
            "Release signing should follow the effective signing identity so CI overrides are honored."
        )
        XCTAssertTrue(
            makefile.contains("CODESIGN_IDENTITY ?= $(DEVELOPER_ID_IDENTITY)"),
            "Generic signing should inherit the local default identity."
        )
        XCTAssertFalse(makefile.contains("VERSION ?="))
        XCTAssertFalse(makefile.contains("BUILD_NUMBER ?="))
        XCTAssertTrue(makefile.contains("RELEASE_RESOLVER := scripts/resolve-release-version.sh"))
        XCTAssertTrue(makefile.contains("release-metadata-check:"))
        XCTAssertTrue(makefile.contains("scripts/sync-release-version.sh --check"))
        XCTAssertTrue(makefile.contains("print-app-version:"))
        XCTAssertTrue(makefile.contains("$(RELEASE_RESOLVE) version"))
        XCTAssertTrue(makefile.contains("$(RELEASE_RESOLVE) build"))
        XCTAssertTrue(makefile.contains("$(RELEASE_RESOLVE) tag"))
        XCTAssertTrue(makefile.contains("CLIProxyManagerReleaseChannel"))
        XCTAssertTrue(makefile.contains("scripts/verify-dmg.sh \"$(DMG_PATH)\""))
        XCTAssertTrue(makefile.contains("sign-dmg:"))
        XCTAssertTrue(makefile.contains("codesign --force --timestamp --sign \"$(RELEASE_CODESIGN_IDENTITY)\" \"$(DMG_PATH)\""))
        XCTAssertTrue(makefile.contains("CODESIGN_FLAGS = --force --options runtime $(CODESIGN_TIMESTAMP)"))
        XCTAssertTrue(
            makefile.contains("$(MAKE) sign CODESIGN_IDENTITY=\"$(RELEASE_CODESIGN_IDENTITY)\" CODESIGN_TIMESTAMP=--timestamp"),
            "Release signing must request a secure timestamp, which notarization requires."
        )
        XCTAssertTrue(makefile.contains("notarize-app:"))
        XCTAssertTrue(makefile.contains("notarize-dmg:"))
        XCTAssertTrue(makefile.contains("xcrun stapler staple \"$(APP_BUNDLE)\""))
        XCTAssertTrue(makefile.contains("xcrun stapler staple \"$(DMG_PATH)\""))
        XCTAssertTrue(makefile.contains("xcrun stapler validate \"$$MOUNT_DIR/$(APP_NAME).app\""))
        XCTAssertTrue(
            makefile.contains("scripts/sign-bundled-cliproxyapi.sh --identity \"$(CODESIGN_IDENTITY)\""),
            "Notarization requires the bundled CLIProxyAPI binary to be Developer ID signed."
        )
        assert("scripts/sign-bundled-cliproxyapi.sh", appearsBefore: "--entitlements \"$(ENTITLEMENTS)\" \"$$STAGED_APP\"", in: makefile)
        assert("dmg: release-sign\n\t$(MAKE) notarize-app", appearsBefore: "hdiutil create", in: makefile)
        XCTAssertTrue(makefile.contains("verify-app-structure: bundle"))
        XCTAssertTrue(makefile.contains("CLIPROXYAPI_RESOLVER := scripts/resolve-bundled-cliproxyapi.sh"))
        XCTAssertTrue(makefile.contains("resolve-bundled-proxy:"))
        XCTAssertTrue(makefile.contains("prune-bundled-proxy-cache:"))
        XCTAssertTrue(makefile.contains("--prune-cache"))
        XCTAssertTrue(makefile.contains("bundle: swift-build $(INFO_PLIST) $(ENTITLEMENTS) $(ICON_FILE)"))
        XCTAssertFalse(makefile.contains("bundle: swift-build resolve-bundled-proxy"), "The bundle recipe resolves and materializes the proxy in one verification pass.")
        XCTAssertTrue(
            makefile.contains("scripts/verify-app-structure.sh --app \"$(APP_BUNDLE)\" --version \"$(VERSION)\" --build \"$(BUILD_NUMBER)\" --channel \"$(RELEASE_CHANNEL)\""),
            "The Makefile should validate canonical app structure before signing."
        )
        XCTAssertTrue(
            makefile.contains("scripts/verify-app-structure.sh --app \"$$MOUNT_DIR/$(APP_NAME).app\" --version \"$(VERSION)\" --build \"$(BUILD_NUMBER)\" --channel \"$(RELEASE_CHANNEL)\""),
            "DMG verification should validate the mounted app's pinned proxy artifact before publication."
        )
        XCTAssertTrue(makefile.contains("install_name_tool -add_rpath \"@executable_path/../Frameworks\""))
        XCTAssertTrue(
            makefile.contains("Sparkle.framework/Versions/Current/XPCServices"),
            "Sparkle XPC services should be signed through the canonical Versions/Current path."
        )
        XCTAssertTrue(
            makefile.contains("Sparkle.framework/Versions/Current/Updater.app"),
            "Sparkle Updater.app should be signed through the canonical Versions/Current path."
        )
        XCTAssertTrue(
            makefile.contains("Sparkle.framework/Versions/Current/Autoupdate"),
            "Sparkle Autoupdate should be signed through the canonical Versions/Current path."
        )
        XCTAssertTrue(
            makefile.contains("-exec codesign $(CODESIGN_FLAGS) --preserve-metadata=entitlements --sign \"$(CODESIGN_IDENTITY)\" {} \\;"),
            "Sparkle XPC services should be signed with hardened runtime and find -exec instead of find|xargs."
        )
        XCTAssertTrue(
            makefile.contains("codesign $(CODESIGN_FLAGS) --sign \"$(CODESIGN_IDENTITY)\" \"$$STAGED_APP/Contents/Helpers/cliproxy-manager\""),
            "The bundled helper should be signed with hardened runtime for release consistency."
        )
        XCTAssertFalse(
            makefile.contains("xargs -0"),
            "Sparkle codesigning must not pipe find output through xargs."
        )

        XCTAssertTrue(
            releaseLocal.contains("make resolve-bundled-proxy"),
            "Local fallback releases should use the canonical Makefile resolver entrypoint."
        )
        XCTAssertFalse(releaseLocal.contains("resolve-bundled-cliproxyapi.sh"))
        XCTAssertTrue(
            releaseLocal.contains("security find-identity -v -p codesigning | grep -F '\"Developer ID Application: Woosub Lee (2L6ZW98RCP)\"'"),
            "Local fallback releases should verify the required signing identity before building."
        )
        XCTAssertTrue(
            releaseLocal.contains("make NOTARY_PROFILE=\"$NOTARY_PROFILE\" verify-dmg"),
            "Local fallback releases should let Makefile resolve canonical release metadata and signing defaults."
        )
        XCTAssertTrue(releaseLocal.contains("xcrun notarytool history --keychain-profile \"$NOTARY_PROFILE\""))
        assert("make sign-dmg", appearsBefore: "make NOTARY_PROFILE=\"$NOTARY_PROFILE\" notarize-dmg", in: releaseLocal)
        assert("notarize-dmg", appearsBefore: "generate-sparkle-appcast.sh", in: releaseLocal)
        XCTAssertFalse(
            releaseLocal.contains("make CODESIGN_IDENTITY=- VERSION=\"$VERSION\" BUILD_NUMBER=\"$BUILD_NUMBER\" verify-dmg"),
            "The local fallback release path must not force ad-hoc signing."
        )
        XCTAssertTrue(
            releaseLocal.contains("Artifacts passed canonical identity, monotonicity, and parity verification before publication."),
            "Local release notes should record the canonical verification gates."
        )
        XCTAssertTrue(
            releaseLocal.contains("ALLOW_LOCAL_RELEASE_CLOBBER"),
            "Local fallback releases should require an explicit opt-in before clobbering release assets."
        )
        XCTAssertTrue(
            releaseLocal.contains("gh release upload \"$CANONICAL_TAG\" \"$RELEASE_DMG_PATH\" \"$RELEASE_APPCAST_PATH\" \"$PROVENANCE_PATH\"\n"),
            "Local fallback releases should upload canonical artifacts and provenance without --clobber by default."
        )
        XCTAssertTrue(
            releaseLocal.contains("gh release upload \"$CANONICAL_TAG\" \"$RELEASE_DMG_PATH\" \"$RELEASE_APPCAST_PATH\" \"$PROVENANCE_PATH\" --clobber"),
            "Local fallback releases may still clobber canonical artifacts when explicitly requested."
        )
        XCTAssertFalse(
            releaseLocal.contains("Ad-hoc signed, non-notarized DMG with Sparkle appcast."),
            "Local release notes should no longer describe releases as ad-hoc signed."
        )

        XCTAssertTrue(workflow.contains("name: Notarized Release"))
        XCTAssertTrue(workflow.contains("workflow_dispatch:"))
        XCTAssertFalse(
            workflow.contains("push:"),
            "Release workflow should be manually dispatched, not a tag-push release path."
        )
        XCTAssertFalse(
            workflow.contains("tags:"),
            "Release workflow should not include automatic tag push triggers."
        )
        XCTAssertTrue(workflow.contains("contents: write"))
        XCTAssertTrue(workflow.contains("concurrency:"))
        XCTAssertTrue(workflow.contains("group: cliproxymanager-official-release"))
        XCTAssertTrue(workflow.contains("cancel-in-progress: false"))
        XCTAssertTrue(workflow.contains("fetch-depth: 1"))
        XCTAssertFalse(workflow.contains("fetch-depth: 0"), "Release checks remote tags explicitly and should not fetch historical binary blobs.")
        XCTAssertTrue(workflow.contains("INPUT_TAG: ${{ inputs.tag }}"))
        XCTAssertTrue(workflow.contains("ACTUAL_TAG='invalid'"))
        XCTAssertTrue(workflow.contains("[[ \"$INPUT_TAG\" =~ ^v(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$ ]]"))
        XCTAssertTrue(workflow.contains("actual $ACTUAL_TAG"))
        XCTAssertTrue(makefile.contains("swift-build: release-metadata-check"))
        XCTAssertTrue(makefile.contains("BUNDLE_ID is fixed to com.woosublee.CLIProxyManager"))
        XCTAssertFalse(workflow.contains("actual $INPUT_TAG"))
        XCTAssertTrue(workflow.contains("scripts/resolve-release-version.sh validate"))
        XCTAssertTrue(workflow.contains("scripts/resolve-release-version.sh shell"))
        XCTAssertTrue(workflow.contains("scripts/sync-release-version.sh --check"))
        XCTAssertTrue(workflow.contains("scripts/check-release-monotonic.sh"))
        XCTAssertTrue(workflow.contains("scripts/verify-release-artifacts.sh"))
        XCTAssertTrue(workflow.contains("provenance_path=build/release-provenance.json"))
        XCTAssertTrue(workflow.contains("git ls-remote --exit-code --tags origin \"refs/tags/$RELEASE_TAG\""))
        XCTAssertEqual(
            workflow.components(separatedBy: "scripts/check-release-monotonic.sh").count - 1,
            2
        )
        XCTAssertEqual(
            workflow.components(separatedBy: "if [ \"$status\" -ne 2 ]; then").count - 1,
            2,
            "Only exit status 2 should represent a missing remote tag."
        )
        XCTAssertEqual(
            workflow.components(separatedBy: "exit \"$status\"").count - 1,
            2,
            "Every other remote lookup error should be propagated."
        )
        XCTAssertFalse(workflow.contains("APP_VERSION=\"$(make -s print-app-version)\""))
        XCTAssertFalse(workflow.contains("BUILD_NUMBER=\"$(make -s print-build-number)\""))
        XCTAssertFalse(workflow.contains("VERSION=\"${{ steps.version.outputs.version }}\""))
        XCTAssertFalse(workflow.contains("BUILD_NUMBER=\"${{ steps.version.outputs.build_number }}\""))
        XCTAssertFalse(workflow.contains("RELEASE_TAG: ${{ steps.version.outputs.tag }}"))
        XCTAssertFalse(workflow.contains("DMG_PATH: ${{ steps.version.outputs.dmg_path }}"))
        XCTAssertFalse(
            workflow.contains("ref: ${{ steps.release-tag.outputs.release_tag }}"),
            "The CI release should build the current workflow commit, not checkout a pre-existing tag."
        )

        XCTAssertTrue(
            workflow.contains("bash scripts/run-script-tests.sh"),
            "The release workflow must run every Git-tracked script regression test through the deterministic runner."
        )
        XCTAssertFalse(workflow.contains("bash Tests/ScriptTests/release-version-tests.sh"))
        XCTAssertFalse(workflow.contains("bash Tests/ScriptTests/release-local-tests.sh"))
        XCTAssertFalse(workflow.contains("bash Tests/ScriptTests/generate-sparkle-appcast-tests.sh"))
        XCTAssertTrue(workflow.contains("swift test"))
        XCTAssertTrue(workflow.contains("uses: actions/cache@v4"))
        XCTAssertTrue(workflow.contains("path: .build/cliproxyapi"))
        XCTAssertTrue(workflow.contains("hashFiles('Sources/CLIProxyManagerApp/Resources/cliproxyapi/cliproxyapi.manifest.json')"))
        XCTAssertTrue(workflow.contains("- name: Resolve pinned CLIProxyAPI artifact"))
        XCTAssertTrue(workflow.contains("run: make resolve-bundled-proxy"))
        XCTAssertTrue(workflow.contains("CLIPROXYAPI_OFFLINE=1 make CODESIGN_IDENTITY=\"$CODESIGN_IDENTITY\" NOTARY_PROFILE=notarytool-profile NOTARY_KEYCHAIN=\"$KEYCHAIN_PATH\" verify-dmg"))
        assert("- name: Resolve pinned CLIProxyAPI artifact", appearsBefore: "- name: Import Developer ID certificate", in: workflow)
        XCTAssertFalse(workflow.contains("CLIPROXYMANAGER_CERTIFICATE"), "The retired self-signed certificate secrets must not be used.")
        XCTAssertTrue(workflow.contains("DEVELOPER_ID_CERTIFICATE_BASE64"))
        XCTAssertTrue(workflow.contains("DEVELOPER_ID_CERTIFICATE_PASSWORD"))
        XCTAssertTrue(workflow.contains("ASC_KEY_ID: ${{ secrets.ASC_KEY_ID }}"))
        XCTAssertTrue(workflow.contains("ASC_ISSUER_ID: ${{ secrets.ASC_ISSUER_ID }}"))
        XCTAssertTrue(workflow.contains("ASC_KEY_P8_BASE64: ${{ secrets.ASC_KEY_P8_BASE64 }}"))
        XCTAssertTrue(workflow.contains("xcrun notarytool store-credentials \"notarytool-profile\""))
        XCTAssertTrue(workflow.contains("import_intermediate DeveloperIDG2CA f16cd3c54c7f83cea4bf1a3e6a0819c8aaa8e4a1528fd144715f350643d2df3a"))
        XCTAssertTrue(workflow.contains("SPARKLE_PRIVATE_KEY: ${{ secrets.SPARKLE_PRIVATE_KEY }}"))
        XCTAssertTrue(workflow.contains("security create-keychain"))
        XCTAssertTrue(workflow.contains("security import \"$CERTIFICATE_PATH\""))
        XCTAssertTrue(workflow.contains("security set-key-partition-list -S apple-tool:,apple:,codesign:"))
        XCTAssertTrue(workflow.contains("security list-keychains -d user -s \"$KEYCHAIN_PATH\""))
        XCTAssertTrue(workflow.contains("security default-keychain -s \"$KEYCHAIN_PATH\""))
        XCTAssertTrue(workflow.contains("awk '/\"Developer ID Application: / { print $2; exit }'"))
        XCTAssertFalse(workflow.contains("CODESIGN_IDENTITY=cliproxymanager"))
        XCTAssertFalse(
            workflow.contains("CODESIGN_IDENTITY=-"),
            "The official CI release should import the Developer ID certificate instead of using ad-hoc signing."
        )
        XCTAssertTrue(workflow.contains("make CODESIGN_IDENTITY=\"$CODESIGN_IDENTITY\" sign-dmg"))
        XCTAssertTrue(workflow.contains("make NOTARY_PROFILE=notarytool-profile NOTARY_KEYCHAIN=\"$KEYCHAIN_PATH\" notarize-dmg"))
        XCTAssertTrue(workflow.contains("REPOSITORY: ${{ github.repository }}"))
        XCTAssertTrue(workflow.contains("scripts/generate-sparkle-appcast.sh"))
        XCTAssertTrue(workflow.contains("git tag \"${{ steps.version.outputs.tag }}\" \"$GITHUB_SHA\""))
        XCTAssertTrue(workflow.contains("git push origin \"refs/tags/${{ steps.version.outputs.tag }}\""))
        XCTAssertTrue(workflow.contains("softprops/action-gh-release@a06a81a03ee405af7f2048a818ed3f03bbf83c7b"))
        XCTAssertTrue(workflow.contains("make_latest: true"))
        XCTAssertTrue(workflow.contains("${{ steps.version.outputs.dmg_path }}"))
        XCTAssertTrue(workflow.contains("${{ steps.version.outputs.appcast_path }}"))
        XCTAssertTrue(workflow.contains("${{ steps.version.outputs.provenance_path }}"))
        XCTAssertTrue(workflow.contains("Developer ID signed and notarized DMG with Sparkle appcast."))
        XCTAssertFalse(workflow.contains("Self-signed, non-notarized DMG"))
        XCTAssertTrue(workflow.contains("Cleanup signing artifacts"))
        XCTAssertTrue(workflow.contains("security delete-keychain \"$KPATH\""))
        XCTAssertTrue(workflow.contains("rm -f \"$RUNNER_TEMP/developer_id.p12\" \"$RUNNER_TEMP/notary_api_key.p8\""))

        assert("- name: Store notarization credentials", appearsBefore: "- name: Build, sign, notarize, and verify DMG", in: workflow)
        assert("- name: Sign DMG", appearsBefore: "- name: Notarize DMG", in: workflow)
        assert("- name: Notarize DMG", appearsBefore: "- name: Generate Sparkle appcast", in: workflow)
        assert("- name: Verify release artifacts", appearsBefore: "- name: Recheck published build", in: workflow)
        assert("- name: Recheck published build", appearsBefore: "- name: Create tag", in: workflow)
        assert("- name: Create tag", appearsBefore: "- name: Create Release", in: workflow)

        XCTAssertTrue(makefile.contains("CPM_EXECUTABLE = $(SWIFT_BUILD_DIR)/cpm"))
        XCTAssertTrue(makefile.contains("BUNDLED_CPM := $(HELPERS_DIR)/cpm"))
        XCTAssertTrue(makefile.contains("Contents/Helpers/cpm"))
        XCTAssertTrue(makefile.contains("Contents/Helpers/cliproxy-manager"))
        XCTAssertTrue(makefile.contains("/usr/local/bin/cpm"))
        XCTAssertTrue(makefile.contains("/usr/local/bin/cliproxy-manager"))
    }

    func testVerifyDMGScriptReturnsFailureStatusAfterRetries() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("VerifyDMGTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fakeBin = sandbox.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: sandbox) }
        let fakeHdiutil = fakeBin.appendingPathComponent("hdiutil")
        try "#!/usr/bin/env bash\nexit 42\n".write(to: fakeHdiutil, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeHdiutil.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["bash", repositoryRoot().appendingPathComponent("scripts/verify-dmg.sh").path, "fake.dmg"]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = fakeBin.path + ":" + (environment["PATH"] ?? "")
        process.environment = environment
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 42)
    }

    private func assert(_ firstNeedle: String, appearsBefore secondNeedle: String, in haystack: String) {
        guard let firstRange = haystack.range(of: firstNeedle) else {
            XCTFail("Missing expected string: \(firstNeedle)")
            return
        }
        guard let secondRange = haystack.range(of: secondNeedle) else {
            XCTFail("Missing expected string: \(secondNeedle)")
            return
        }
        XCTAssertLessThan(firstRange.lowerBound, secondRange.lowerBound)
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
