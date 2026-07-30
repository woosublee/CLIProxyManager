import Foundation
import XCTest

final class CIWorkflowTests: XCTestCase {
    func testCIWorkflowDefinesOnlyTheRequiredIndependentChecks() throws {
        let workflow = try workflowContents()

        XCTAssertTrue(workflow.hasPrefix("name: CI\n"))
        XCTAssertTrue(
            workflow.contains(
                """
                on:
                  pull_request:
                  push:
                    branches:
                      - main
                """
            ),
            "CI should create all four checks for every pull request and only for pushes to main."
        )
        XCTAssertFalse(
            workflow.contains("  pull_request:\n    branches:"),
            "Pull request CI must not filter target branches."
        )
        XCTAssertFalse(
            workflow.contains("  pull_request:\n    branches-ignore:"),
            "Pull request CI must not filter target branches."
        )
        XCTAssertTrue(workflow.contains("permissions:\n  contents: read\n\nconcurrency:"))
        XCTAssertTrue(
            workflow.contains(
                """
                concurrency:
                  group: ${{ github.event_name == 'pull_request' && format('ci-pr-{0}', github.event.pull_request.number) || format('ci-push-{0}', github.run_id) }}
                  cancel-in-progress: ${{ github.event_name == 'pull_request' }}
                """
            ),
            "Only pull request runs should cancel an earlier run in the same PR."
        )

        let expectedJobs = [
            """
              build:
                name: Build
                runs-on: macos-14
                steps:
                  - uses: actions/checkout@v4
                    with:
                      persist-credentials: false
                  - run: make ci-build
            """,
            """
              test:
                name: Test
                runs-on: macos-14
                steps:
                  - uses: actions/checkout@v4
                    with:
                      persist-credentials: false
                  - run: swift test
            """,
            """
              script-tests:
                name: Script tests
                runs-on: macos-14
                steps:
                  - uses: actions/checkout@v4
                    with:
                      persist-credentials: false
                  - run: bash scripts/run-script-tests.sh
            """,
            """
              package-structure:
                name: Package structure
                runs-on: macos-14
                steps:
                  - uses: actions/checkout@v4
                    with:
                      persist-credentials: false
                  - run: make verify-bundle-structure
            """
        ]

        for expectedJob in expectedJobs {
            XCTAssertTrue(workflow.contains(expectedJob))
        }

        XCTAssertEqual(occurrences(of: "runs-on: macos-14", in: workflow), 4)
        XCTAssertEqual(occurrences(of: "uses: actions/checkout@v4", in: workflow), 4)
        XCTAssertEqual(occurrences(of: "persist-credentials: false", in: workflow), 4)
        XCTAssertEqual(occurrences(of: "run: swift test", in: workflow), 1)
        XCTAssertEqual(occurrences(of: "swift test", in: workflow), 1)
        XCTAssertFalse(workflow.contains("needs:"), "CI jobs must run independently.")
        XCTAssertFalse(workflow.contains("\n    if:"), "CI jobs must not be conditionally skipped.")
        XCTAssertFalse(workflow.contains("\n  if:"), "CI jobs must not be conditionally skipped.")
    }

    func testCIWorkflowRejectsForbiddenTriggersAndCapabilities() throws {
        let workflow = try workflowContents().lowercased()
        let forbiddenTokens = [
            "pull_request_target",
            "workflow_dispatch:",
            "workflow_call:",
            "schedule:",
            "merge_group:",
            "paths:",
            "paths-ignore:",
            "draft",
            "secrets",
            "github_token",
            ": write",
            "pull-requests: write",
            "actions/upload-artifact",
            "actions/download-artifact",
            "artifact",
            "gh",
            "git push",
            "release",
            "publish",
            "codesign",
            "security ",
            "notary",
            "stapler",
            "sign",
            "continue-on-error",
            "retry"
        ]

        for forbiddenToken in forbiddenTokens {
            XCTAssertFalse(
                workflow.contains(forbiddenToken),
                "CI must not contain forbidden token: \(forbiddenToken)"
            )
        }

        XCTAssertEqual(occurrences(of: "uses:", in: workflow), 4)
    }

    func testMainCIRulesetDefinesThePostRolloutBranchProtectionPolicy() throws {
        let workflow = try workflowContents()
        let rulesetURL = repositoryRoot().appendingPathComponent(".github/rulesets/main-ci.json")
        let rulesetData = try Data(contentsOf: rulesetURL)
        let ruleset = try XCTUnwrap(
            JSONSerialization.jsonObject(with: rulesetData) as? [String: Any],
            "Ruleset payload must be a JSON object."
        )

        XCTAssertFalse(workflow.contains("main-ci.json"))
        XCTAssertFalse(workflow.contains(".github/rulesets"))
        XCTAssertEqual(
            Set(ruleset.keys),
            Set(["name", "target", "enforcement", "conditions", "bypass_actors", "rules"]),
            "The ruleset should remain a declarative API payload."
        )
        XCTAssertEqual(ruleset["name"] as? String, "main-ci")
        XCTAssertEqual(ruleset["target"] as? String, "branch")
        XCTAssertEqual(ruleset["enforcement"] as? String, "active")
        XCTAssertEqual((ruleset["bypass_actors"] as? [Any])?.count, 0)

        let conditions = try XCTUnwrap(ruleset["conditions"] as? [String: Any])
        XCTAssertEqual(Set(conditions.keys), Set(["ref_name"]))
        let refName = try XCTUnwrap(conditions["ref_name"] as? [String: Any])
        XCTAssertEqual(refName["include"] as? [String], ["refs/heads/main"])
        XCTAssertEqual((refName["exclude"] as? [Any])?.count, 0)

        let rules = try XCTUnwrap(ruleset["rules"] as? [[String: Any]])
        XCTAssertEqual(rules.count, 4)
        XCTAssertEqual(
            Set(rules.compactMap { $0["type"] as? String }),
            Set(["deletion", "non_fast_forward", "pull_request", "required_status_checks"])
        )

        let pullRequestRule = try XCTUnwrap(rules.first { $0["type"] as? String == "pull_request" })
        let pullRequestParameters = try XCTUnwrap(pullRequestRule["parameters"] as? [String: Any])
        XCTAssertEqual(
            Set(pullRequestParameters.keys),
            Set([
                "allowed_merge_methods",
                "dismiss_stale_reviews_on_push",
                "require_code_owner_review",
                "require_last_push_approval",
                "required_approving_review_count",
                "required_review_thread_resolution"
            ])
        )
        XCTAssertEqual(
            pullRequestParameters["allowed_merge_methods"] as? [String],
            ["merge", "squash", "rebase"]
        )
        XCTAssertEqual(pullRequestParameters["require_code_owner_review"] as? Bool, false)
        XCTAssertEqual(pullRequestParameters["require_last_push_approval"] as? Bool, false)
        XCTAssertEqual(pullRequestParameters["required_approving_review_count"] as? Int, 0)
        XCTAssertEqual(pullRequestParameters["required_review_thread_resolution"] as? Bool, false)

        let statusChecksRule = try XCTUnwrap(rules.first { $0["type"] as? String == "required_status_checks" })
        let statusChecksParameters = try XCTUnwrap(statusChecksRule["parameters"] as? [String: Any])
        XCTAssertEqual(
            Set(statusChecksParameters.keys),
            Set([
                "do_not_enforce_on_create",
                "required_status_checks",
                "strict_required_status_checks_policy"
            ])
        )
        XCTAssertEqual(statusChecksParameters["do_not_enforce_on_create"] as? Bool, false)
        XCTAssertEqual(statusChecksParameters["strict_required_status_checks_policy"] as? Bool, true)

        let requiredChecks = try XCTUnwrap(statusChecksParameters["required_status_checks"] as? [[String: Any]])
        let expectedContexts = ["Build", "Test", "Script tests", "Package structure"]
        XCTAssertEqual(requiredChecks.count, expectedContexts.count)
        for (check, context) in zip(requiredChecks, expectedContexts) {
            XCTAssertEqual(check["context"] as? String, context)
            XCTAssertEqual(check["integration_id"] as? Int, 15368)
        }
    }

    private func workflowContents() throws -> String {
        try String(
            contentsOf: repositoryRoot().appendingPathComponent(".github/workflows/ci.yml"),
            encoding: .utf8
        )
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
