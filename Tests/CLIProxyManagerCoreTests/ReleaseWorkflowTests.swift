import XCTest

final class ReleaseWorkflowTests: XCTestCase {
    func testReleaseWorkflowBuildsAndUploadsAdHocDMGForTags() throws {
        let workflow = try String(contentsOf: repositoryRoot().appendingPathComponent(".github/workflows/release.yml"), encoding: .utf8)
        let makefile = try String(contentsOf: repositoryRoot().appendingPathComponent("Makefile"), encoding: .utf8)

        XCTAssertTrue(makefile.contains("scripts/verify-dmg.sh \"$(DMG_PATH)\""))
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
            makefile.contains("-exec codesign --force --sign \"$(CODESIGN_IDENTITY)\" {} \\;"),
            "Sparkle XPC services should be signed with find -exec instead of find|xargs."
        )
        XCTAssertFalse(
            makefile.contains("xargs -0"),
            "Sparkle codesigning must not pipe find output through xargs."
        )

        XCTAssertTrue(workflow.contains("on:"))
        XCTAssertTrue(workflow.contains("workflow_dispatch:"))
        XCTAssertTrue(workflow.contains("tags:"))
        XCTAssertTrue(workflow.contains("'v*'"))
        XCTAssertTrue(workflow.contains("contents: write"))
        XCTAssertTrue(workflow.contains("DISPATCH_TAG: ${{ inputs.tag }}"))
        XCTAssertTrue(workflow.contains("RELEASE_TAG=\"$DISPATCH_TAG\""))
        XCTAssertTrue(workflow.contains("RELEASE_TAG=\"$GITHUB_REF_NAME\""))
        XCTAssertTrue(workflow.contains("[[ \"$RELEASE_TAG\" == v* ]]"))
        XCTAssertTrue(workflow.contains("id: release-tag"))
        XCTAssertTrue(workflow.contains("echo \"release_tag=$RELEASE_TAG\" >> \"$GITHUB_OUTPUT\""))
        XCTAssertTrue(workflow.contains("echo \"RELEASE_TAG=$RELEASE_TAG\" >> \"$GITHUB_ENV\""))
        XCTAssertTrue(workflow.contains("ref: ${{ steps.release-tag.outputs.release_tag }}"))
        XCTAssertTrue(workflow.contains("VERSION=${RELEASE_TAG#v}"))
        XCTAssertTrue(workflow.contains("BUILD_NUMBER=$(plutil -extract CFBundleVersion raw Info.plist)"))
        XCTAssertTrue(workflow.contains("APPCAST_PATH=\"build/appcast.xml\""))
        XCTAssertTrue(workflow.contains("echo \"APPCAST_PATH=$APPCAST_PATH\" >> \"$GITHUB_ENV\""))
        XCTAssertTrue(workflow.contains("make CODESIGN_IDENTITY=- VERSION=\"$VERSION\" BUILD_NUMBER=\"$BUILD_NUMBER\" verify-dmg"))
        XCTAssertTrue(workflow.contains("SPARKLE_PRIVATE_KEY: ${{ secrets.SPARKLE_PRIVATE_KEY }}"))
        XCTAssertTrue(workflow.contains("test -n \"$SPARKLE_PRIVATE_KEY\""))
        XCTAssertTrue(workflow.contains("scripts/generate-sparkle-appcast.sh"))
        XCTAssertTrue(workflow.contains("gh release view \"$RELEASE_TAG\""))
        XCTAssertTrue(workflow.contains("gh release create \"$RELEASE_TAG\" --verify-tag"))
        XCTAssertTrue(workflow.contains("gh release upload \"$RELEASE_TAG\" \"$DMG_PATH\" \"$APPCAST_PATH\" --clobber"))
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

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
