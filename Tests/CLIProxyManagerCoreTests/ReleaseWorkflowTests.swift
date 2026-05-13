import XCTest

final class ReleaseWorkflowTests: XCTestCase {
    func testReleaseWorkflowBuildsAndUploadsAdHocDMGForTags() throws {
        let workflow = try String(contentsOf: repositoryRoot().appendingPathComponent(".github/workflows/release.yml"), encoding: .utf8)
        let makefile = try String(contentsOf: repositoryRoot().appendingPathComponent("Makefile"), encoding: .utf8)

        XCTAssertTrue(makefile.contains("scripts/verify-dmg.sh \"$(DMG_PATH)\""))

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
        XCTAssertTrue(workflow.contains("BUILD_NUMBER=${{ github.run_number }}"))
        XCTAssertTrue(workflow.contains("make CODESIGN_IDENTITY=- VERSION=\"$VERSION\" BUILD_NUMBER=\"$BUILD_NUMBER\" verify-dmg"))
        XCTAssertTrue(workflow.contains("gh release view \"$RELEASE_TAG\""))
        XCTAssertTrue(workflow.contains("gh release create \"$RELEASE_TAG\" --verify-tag"))
        XCTAssertTrue(workflow.contains("gh release upload \"$RELEASE_TAG\" \"$DMG_PATH\" --clobber"))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
