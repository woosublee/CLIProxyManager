import XCTest

final class ReleaseWorkflowTests: XCTestCase {
    func testReleaseWorkflowBuildsAndUploadsSelfSignedDMG() throws {
        let workflow = try String(contentsOf: repositoryRoot().appendingPathComponent(".github/workflows/release.yml"), encoding: .utf8)
        let makefile = try String(contentsOf: repositoryRoot().appendingPathComponent("Makefile"), encoding: .utf8)
        let releaseLocal = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/release-local.sh"), encoding: .utf8)

        XCTAssertTrue(
            makefile.contains("LOCAL_CODESIGN_IDENTITY ?= cliproxymanager"),
            "Development and local release builds should default to the shared cliproxymanager signing identity."
        )
        XCTAssertTrue(
            makefile.contains("RELEASE_CODESIGN_IDENTITY ?= $(CODESIGN_IDENTITY)"),
            "Release signing should follow the effective signing identity so CI overrides are honored."
        )
        XCTAssertTrue(
            makefile.contains("CODESIGN_IDENTITY ?= $(LOCAL_CODESIGN_IDENTITY)"),
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
        XCTAssertTrue(makefile.contains("codesign --force --sign \"$(CODESIGN_IDENTITY)\" \"$(DMG_PATH)\""))
        XCTAssertTrue(makefile.contains("test -d \"$$VERIFY_APP/Contents/Frameworks/Sparkle.framework\""))
        XCTAssertTrue(makefile.contains("test -x \"$$VERIFY_APP/Contents/Frameworks/Sparkle.framework/Autoupdate\""))
        XCTAssertTrue(makefile.contains("test -d \"$$VERIFY_APP/Contents/Frameworks/Sparkle.framework/Updater.app\""))
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
            makefile.contains("-exec codesign --force --options runtime --sign \"$(CODESIGN_IDENTITY)\" {} \\;"),
            "Sparkle XPC services should be signed with hardened runtime and find -exec instead of find|xargs."
        )
        XCTAssertTrue(
            makefile.contains("codesign --force --options runtime --sign \"$(CODESIGN_IDENTITY)\" \"$$STAGED_APP/Contents/Helpers/cliproxy-manager\""),
            "The bundled helper should be signed with hardened runtime for release consistency."
        )
        XCTAssertFalse(
            makefile.contains("xargs -0"),
            "Sparkle codesigning must not pipe find output through xargs."
        )

        XCTAssertTrue(
            releaseLocal.contains("CODESIGN_IDENTITY=\"cliproxymanager\""),
            "Local fallback releases should name the required signing identity explicitly."
        )
        XCTAssertTrue(
            releaseLocal.contains("security find-identity -v -p codesigning"),
            "Local fallback releases should fail before building if the cliproxymanager identity is missing."
        )
        XCTAssertTrue(
            releaseLocal.contains("make VERSION=\"$VERSION\" BUILD_NUMBER=\"$BUILD_NUMBER\" verify-dmg"),
            "Local fallback releases should use Makefile signing defaults instead of forcing ad-hoc signing."
        )
        XCTAssertFalse(
            releaseLocal.contains("make CODESIGN_IDENTITY=- VERSION=\"$VERSION\" BUILD_NUMBER=\"$BUILD_NUMBER\" verify-dmg"),
            "The local fallback release path must not force ad-hoc signing."
        )
        XCTAssertTrue(
            releaseLocal.contains("Manual fallback release: self-signed, non-notarized DMG signed with the local cliproxymanager code signing identity and Sparkle appcast."),
            "Local release notes should describe the fallback self-signed artifact."
        )
        XCTAssertTrue(
            releaseLocal.contains("ALLOW_LOCAL_RELEASE_CLOBBER"),
            "Local fallback releases should require an explicit opt-in before clobbering release assets."
        )
        XCTAssertTrue(
            releaseLocal.contains("gh release upload \"$RELEASE_TAG\" \"$DMG_PATH\" \"$APPCAST_PATH\"\n"),
            "Local fallback releases should upload without --clobber by default."
        )
        XCTAssertTrue(
            releaseLocal.contains("gh release upload \"$RELEASE_TAG\" \"$DMG_PATH\" \"$APPCAST_PATH\" --clobber"),
            "Local fallback releases may still clobber when explicitly requested."
        )
        XCTAssertFalse(
            releaseLocal.contains("Ad-hoc signed, non-notarized DMG with Sparkle appcast."),
            "Local release notes should no longer describe releases as ad-hoc signed."
        )

        XCTAssertTrue(workflow.contains("name: Self-signed Release"))
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
        XCTAssertTrue(workflow.contains("fetch-depth: 0"))
        XCTAssertTrue(workflow.contains("INPUT_TAG: ${{ inputs.tag }}"))
        XCTAssertTrue(workflow.contains("TAG=\"$INPUT_TAG\""))
        XCTAssertTrue(workflow.contains("APP_VERSION=\"$(make -s print-app-version)\""))
        XCTAssertTrue(workflow.contains("BUILD_NUMBER=\"$(make -s print-build-number)\""))
        XCTAssertTrue(workflow.contains("BUILD_TAG=\"$(make -s print-build-tag)\""))
        XCTAssertTrue(workflow.contains("if ! [[ \"$TAG\" =~ ^v[0-9]+\\.[0-9]+\\.[0-9]+$ ]]"))
        XCTAssertTrue(workflow.contains("[ \"$TAG\" != \"$BUILD_TAG\" ]"))
        XCTAssertTrue(workflow.contains("[ \"$VERSION\" != \"$APP_VERSION\" ]"))
        XCTAssertTrue(workflow.contains("[[ \"$BUILD_NUMBER\" =~ ^[1-9][0-9]*$ ]]"))
        XCTAssertTrue(workflow.contains("git ls-remote --exit-code --tags origin \"refs/tags/$TAG\""))
        XCTAssertFalse(
            workflow.contains("ref: ${{ steps.release-tag.outputs.release_tag }}"),
            "The self-signed CI release should build the current workflow commit, not checkout a pre-existing tag."
        )

        XCTAssertTrue(workflow.contains("swift test"))
        XCTAssertTrue(workflow.contains("CLIPROXYMANAGER_CERTIFICATE_BASE64"))
        XCTAssertTrue(workflow.contains("CLIPROXYMANAGER_CERTIFICATE_PASSWORD"))
        XCTAssertTrue(workflow.contains("SPARKLE_PRIVATE_KEY: ${{ secrets.SPARKLE_PRIVATE_KEY }}"))
        XCTAssertTrue(workflow.contains("security create-keychain"))
        XCTAssertTrue(workflow.contains("security import \"$CERTIFICATE_PATH\""))
        XCTAssertTrue(workflow.contains("security set-key-partition-list -S apple-tool:,apple:,codesign:"))
        XCTAssertTrue(workflow.contains("security list-keychains -d user -s \"$KEYCHAIN_PATH\""))
        XCTAssertTrue(workflow.contains("security default-keychain -s \"$KEYCHAIN_PATH\""))
        XCTAssertTrue(workflow.contains("security find-identity -p codesigning \"$KEYCHAIN_PATH\" || true"))
        XCTAssertTrue(workflow.contains("CODESIGN_IDENTITY=cliproxymanager"))
        XCTAssertFalse(
            workflow.contains("CODESIGN_IDENTITY=-"),
            "The official self-signed CI release should import the cliproxymanager certificate instead of using ad-hoc signing."
        )
        XCTAssertTrue(workflow.contains("make CODESIGN_IDENTITY=\"$CODESIGN_IDENTITY\" VERSION=\"${{ steps.version.outputs.version }}\" BUILD_NUMBER=\"${{ steps.version.outputs.build_number }}\" verify-dmg"))
        XCTAssertTrue(workflow.contains("make CODESIGN_IDENTITY=\"$CODESIGN_IDENTITY\" VERSION=\"${{ steps.version.outputs.version }}\" BUILD_NUMBER=\"${{ steps.version.outputs.build_number }}\" sign-dmg"))
        XCTAssertFalse(workflow.contains("notarytool"))
        XCTAssertFalse(workflow.contains("stapler"))
        XCTAssertTrue(workflow.contains("REPOSITORY: ${{ github.repository }}"))
        XCTAssertTrue(workflow.contains("scripts/generate-sparkle-appcast.sh"))
        XCTAssertTrue(workflow.contains("git tag \"${{ steps.version.outputs.tag }}\" \"$GITHUB_SHA\""))
        XCTAssertTrue(workflow.contains("git push origin \"refs/tags/${{ steps.version.outputs.tag }}\""))
        XCTAssertTrue(workflow.contains("softprops/action-gh-release@a06a81a03ee405af7f2048a818ed3f03bbf83c7b"))
        XCTAssertTrue(workflow.contains("make_latest: true"))
        XCTAssertTrue(workflow.contains("${{ steps.version.outputs.dmg_path }}"))
        XCTAssertTrue(workflow.contains("${{ steps.version.outputs.appcast_path }}"))
        XCTAssertTrue(workflow.contains("Self-signed, non-notarized DMG with Sparkle appcast."))
        XCTAssertTrue(workflow.contains("Cleanup signing artifacts"))
        XCTAssertTrue(workflow.contains("security delete-keychain \"$KPATH\""))

        assert("- name: Sign DMG", appearsBefore: "- name: Generate Sparkle appcast", in: workflow)
        assert("- name: Generate Sparkle appcast", appearsBefore: "- name: Create tag", in: workflow)
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
