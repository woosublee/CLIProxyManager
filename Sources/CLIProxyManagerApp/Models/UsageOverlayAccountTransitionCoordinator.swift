struct UsageOverlayAccountTransitionCoordinator {
    enum Action: Equatable {
        case none
        case applyImmediately(UsageOverlayAccountPresentation)
        case beginConceal(generation: Int)
        case beginReveal(generation: Int)
        case retargetHidden(
            generation: Int,
            presentation: UsageOverlayAccountPresentation
        )
    }

    private(set) var generation = 0
    private(set) var phase: UsageOverlayAccountTransitionPhase = .visible
    private(set) var desiredPresentation: UsageOverlayAccountPresentation

    init(initialPresentation: UsageOverlayAccountPresentation) {
        desiredPresentation = initialPresentation
    }

    mutating func receive(
        _ presentation: UsageOverlayAccountPresentation,
        presentedProviderIDs: [ProviderRowState.ID],
        allowsAnimation: Bool
    ) -> Action {
        guard presentation != desiredPresentation else { return .none }
        desiredPresentation = presentation

        guard allowsAnimation else {
            generation += 1
            phase = .visible
            return .applyImmediately(presentation)
        }

        let keepsPresentedIdentity = presentation.orderedProviderIDs == presentedProviderIDs
        switch phase {
        case .visible:
            guard !keepsPresentedIdentity else {
                return .applyImmediately(presentation)
            }
            generation += 1
            phase = .concealing
            return .beginConceal(generation: generation)

        case .concealing:
            generation += 1
            if keepsPresentedIdentity {
                phase = .revealing
                return .beginReveal(generation: generation)
            }
            phase = .concealing
            return .beginConceal(generation: generation)

        case .swapping, .resizing:
            generation += 1
            phase = .swapping
            return .retargetHidden(
                generation: generation,
                presentation: presentation
            )

        case .revealing:
            guard !keepsPresentedIdentity else {
                return .applyImmediately(presentation)
            }
            generation += 1
            phase = .concealing
            return .beginConceal(generation: generation)
        }
    }

    mutating func completeConceal(
        generation expectedGeneration: Int
    ) -> UsageOverlayAccountPresentation? {
        guard generation == expectedGeneration, phase == .concealing else { return nil }
        phase = .swapping
        return desiredPresentation
    }

    mutating func beginResize(generation expectedGeneration: Int) -> Bool {
        guard generation == expectedGeneration, phase == .swapping else { return false }
        phase = .resizing
        return true
    }

    mutating func retargetResize() -> Int? {
        guard phase == .resizing else { return nil }
        generation += 1
        return generation
    }

    mutating func completeResize(generation expectedGeneration: Int) -> Bool {
        guard generation == expectedGeneration, phase == .resizing else { return false }
        phase = .revealing
        return true
    }

    mutating func completeReveal(generation expectedGeneration: Int) -> Bool {
        guard generation == expectedGeneration, phase == .revealing else { return false }
        phase = .visible
        return true
    }

    mutating func prepareHiddenSettlement() -> (
        generation: Int,
        presentation: UsageOverlayAccountPresentation
    ) {
        generation += 1
        phase = .swapping
        return (generation, desiredPresentation)
    }

    mutating func absorbLatestPresentation() -> UsageOverlayAccountPresentation {
        generation += 1
        phase = .visible
        return desiredPresentation
    }
}

enum UsageOverlayAccountTransitionPhase: Equatable {
    case visible
    case concealing
    case swapping
    case resizing
    case revealing
}
