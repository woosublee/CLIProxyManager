import XCTest
@testable import CLIProxyManagerApp

final class UsageOverlayAccountTransitionCoordinatorTests: XCTestCase {
    func testIdentityChangeBeginsConcealWithoutReplacingDesiredUntilCallback() {
        let oneAccount = presentation([.claude])
        let twoAccounts = presentation([.claude, .codex])
        var coordinator = UsageOverlayAccountTransitionCoordinator(
            initialPresentation: oneAccount
        )

        let action = coordinator.receive(
            twoAccounts,
            presentedProviderIDs: oneAccount.orderedProviderIDs,
            allowsAnimation: true
        )

        XCTAssertEqual(action, .beginConceal(generation: 1))
        XCTAssertEqual(coordinator.phase, .concealing)
        XCTAssertEqual(coordinator.desiredPresentation, twoAccounts)
    }

    func testSameIdentityAppliesLatestValuesImmediately() {
        let original = presentation([.claude], displayNameSuffix: "Original")
        let renamed = presentation([.claude], displayNameSuffix: "Renamed")
        var coordinator = UsageOverlayAccountTransitionCoordinator(
            initialPresentation: original
        )

        XCTAssertEqual(
            coordinator.receive(
                renamed,
                presentedProviderIDs: original.orderedProviderIDs,
                allowsAnimation: true
            ),
            .applyImmediately(renamed)
        )
        XCTAssertEqual(coordinator.phase, .visible)
    }

    func testIdenticalPresentationDoesNothing() {
        let original = presentation([.claude])
        var coordinator = UsageOverlayAccountTransitionCoordinator(
            initialPresentation: original
        )

        XCTAssertEqual(
            coordinator.receive(
                original,
                presentedProviderIDs: original.orderedProviderIDs,
                allowsAnimation: true
            ),
            .none
        )
        XCTAssertEqual(coordinator.generation, 0)
    }

    func testProviderReorderingBeginsConceal() {
        let original = presentation([.claude, .codex])
        let reordered = presentation([.codex, .claude])
        var coordinator = UsageOverlayAccountTransitionCoordinator(
            initialPresentation: original
        )

        XCTAssertEqual(
            coordinator.receive(
                reordered,
                presentedProviderIDs: original.orderedProviderIDs,
                allowsAnimation: true
            ),
            .beginConceal(generation: 1)
        )
    }

    func testConcealingChangesCoalesceToLatestGeneration() {
        let oneAccount = presentation([.claude])
        let twoAccounts = presentation([.claude, .codex])
        let threeAccounts = presentation([.claude, .codex, .claudeAPI])
        var coordinator = UsageOverlayAccountTransitionCoordinator(
            initialPresentation: oneAccount
        )

        XCTAssertEqual(
            coordinator.receive(
                twoAccounts,
                presentedProviderIDs: oneAccount.orderedProviderIDs,
                allowsAnimation: true
            ),
            .beginConceal(generation: 1)
        )
        XCTAssertEqual(
            coordinator.receive(
                threeAccounts,
                presentedProviderIDs: oneAccount.orderedProviderIDs,
                allowsAnimation: true
            ),
            .beginConceal(generation: 2)
        )

        XCTAssertNil(coordinator.completeConceal(generation: 1))
        XCTAssertEqual(coordinator.completeConceal(generation: 2), threeAccounts)
        XCTAssertEqual(coordinator.phase, .swapping)
    }

    func testRollbackToPresentedIdentityCancelsPendingSwapAndReveals() {
        let oneAccount = presentation([.claude])
        let twoAccounts = presentation([.claude, .codex])
        var coordinator = UsageOverlayAccountTransitionCoordinator(
            initialPresentation: oneAccount
        )
        _ = coordinator.receive(
            twoAccounts,
            presentedProviderIDs: oneAccount.orderedProviderIDs,
            allowsAnimation: true
        )

        XCTAssertEqual(
            coordinator.receive(
                oneAccount,
                presentedProviderIDs: oneAccount.orderedProviderIDs,
                allowsAnimation: true
            ),
            .beginReveal(generation: 2)
        )
        XCTAssertEqual(coordinator.phase, .revealing)
        XCTAssertNil(coordinator.completeConceal(generation: 1))
        XCTAssertTrue(coordinator.completeReveal(generation: 2))
        XCTAssertEqual(coordinator.phase, .visible)
    }

    func testResizeCompletionRequiresLatestGeneration() {
        let oneAccount = presentation([.claude])
        let twoAccounts = presentation([.claude, .codex])
        var coordinator = UsageOverlayAccountTransitionCoordinator(
            initialPresentation: oneAccount
        )
        _ = coordinator.receive(
            twoAccounts,
            presentedProviderIDs: oneAccount.orderedProviderIDs,
            allowsAnimation: true
        )
        XCTAssertEqual(coordinator.completeConceal(generation: 1), twoAccounts)
        XCTAssertTrue(coordinator.beginResize(generation: 1))

        let retargetGeneration = coordinator.retargetResize()

        XCTAssertEqual(retargetGeneration, 2)
        XCTAssertFalse(coordinator.completeResize(generation: 1))
        XCTAssertTrue(coordinator.completeResize(generation: 2))
        XCTAssertEqual(coordinator.phase, .revealing)
    }

    func testHiddenPresentationChangeRetargetsLatestSnapshot() {
        let oneAccount = presentation([.claude])
        let twoAccounts = presentation([.claude, .codex])
        let threeAccounts = presentation([.claude, .codex, .claudeAPI])
        var coordinator = UsageOverlayAccountTransitionCoordinator(
            initialPresentation: oneAccount
        )
        _ = coordinator.receive(
            twoAccounts,
            presentedProviderIDs: oneAccount.orderedProviderIDs,
            allowsAnimation: true
        )
        _ = coordinator.completeConceal(generation: 1)
        XCTAssertTrue(coordinator.beginResize(generation: 1))

        XCTAssertEqual(
            coordinator.receive(
                threeAccounts,
                presentedProviderIDs: twoAccounts.orderedProviderIDs,
                allowsAnimation: true
            ),
            .retargetHidden(generation: 2, presentation: threeAccounts)
        )
        XCTAssertEqual(coordinator.phase, .swapping)
        XCTAssertFalse(coordinator.completeResize(generation: 1))
        XCTAssertTrue(coordinator.beginResize(generation: 2))
    }

    func testRevealCompletionRequiresLatestGeneration() {
        let oneAccount = presentation([.claude])
        let twoAccounts = presentation([.claude, .codex])
        var coordinator = UsageOverlayAccountTransitionCoordinator(
            initialPresentation: oneAccount
        )
        _ = coordinator.receive(
            twoAccounts,
            presentedProviderIDs: oneAccount.orderedProviderIDs,
            allowsAnimation: true
        )
        _ = coordinator.completeConceal(generation: 1)
        XCTAssertTrue(coordinator.beginResize(generation: 1))
        XCTAssertTrue(coordinator.completeResize(generation: 1))

        XCTAssertFalse(coordinator.completeReveal(generation: 0))
        XCTAssertTrue(coordinator.completeReveal(generation: 1))
        XCTAssertEqual(coordinator.phase, .visible)
    }

    func testAbsorbingLatestPresentationInvalidatesCallbacks() {
        let oneAccount = presentation([.claude])
        let twoAccounts = presentation([.claude, .codex])
        var coordinator = UsageOverlayAccountTransitionCoordinator(
            initialPresentation: oneAccount
        )
        _ = coordinator.receive(
            twoAccounts,
            presentedProviderIDs: oneAccount.orderedProviderIDs,
            allowsAnimation: true
        )

        XCTAssertEqual(coordinator.absorbLatestPresentation(), twoAccounts)
        XCTAssertEqual(coordinator.phase, .visible)
        XCTAssertEqual(coordinator.generation, 2)
        XCTAssertNil(coordinator.completeConceal(generation: 1))
    }

    func testPreparingHiddenSettlementInvalidatesResizeAndKeepsLatestPresentation() {
        let oneAccount = presentation([.claude])
        let twoAccounts = presentation([.claude, .codex])
        var coordinator = UsageOverlayAccountTransitionCoordinator(
            initialPresentation: oneAccount
        )
        _ = coordinator.receive(
            twoAccounts,
            presentedProviderIDs: oneAccount.orderedProviderIDs,
            allowsAnimation: true
        )
        _ = coordinator.completeConceal(generation: 1)
        XCTAssertTrue(coordinator.beginResize(generation: 1))

        let settlement = coordinator.prepareHiddenSettlement()

        XCTAssertEqual(settlement.generation, 2)
        XCTAssertEqual(settlement.presentation, twoAccounts)
        XCTAssertEqual(coordinator.phase, .swapping)
        XCTAssertFalse(coordinator.completeResize(generation: 1))
        XCTAssertTrue(coordinator.beginResize(generation: 2))
    }

    func testReduceMotionAppliesIdentityChangeImmediately() {
        let oneAccount = presentation([.claude])
        let twoAccounts = presentation([.claude, .codex])
        var coordinator = UsageOverlayAccountTransitionCoordinator(
            initialPresentation: oneAccount
        )

        XCTAssertEqual(
            coordinator.receive(
                twoAccounts,
                presentedProviderIDs: oneAccount.orderedProviderIDs,
                allowsAnimation: false
            ),
            .applyImmediately(twoAccounts)
        )
        XCTAssertEqual(coordinator.phase, .visible)
        XCTAssertEqual(coordinator.generation, 1)
    }

    private func presentation(
        _ ids: [ProviderRowState.ID],
        displayNameSuffix: String = "Account"
    ) -> UsageOverlayAccountPresentation {
        UsageOverlayAccountPresentation(
            providers: ids.enumerated().map { index, id in
                MenuBarConnectedProvider(
                    id: id,
                    name: "Provider \(index)",
                    displayName: "\(displayNameSuffix) \(index)",
                    functionName: "provider-\(index)",
                    connectionDetail: "account-\(index)@example.com",
                    accountDetailHidden: true,
                    subscriptionUsageState: .disabled,
                    showsSubscriptionUsage: true
                )
            },
            emptyMessage: ids.isEmpty ? "No connected accounts" : nil
        )
    }
}
