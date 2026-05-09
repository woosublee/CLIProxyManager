import Combine

@MainActor
final class OnboardingViewModel: ObservableObject {
    @Published private(set) var steps: [OnboardingStep]

    init() {
        steps = [
            OnboardingStep(title: "Claude Code 설치 확인"),
            OnboardingStep(title: "Claude 구독 연결"),
            OnboardingStep(title: "Claude API key 선택 입력"),
            OnboardingStep(title: "OpenAI/Codex 연결"),
            OnboardingStep(title: "shell functions 설치"),
            OnboardingStep(title: "프로필 테스트")
        ]
    }
}

struct OnboardingStep: Equatable, Identifiable {
    let id: String
    let title: String

    init(title: String) {
        self.id = title
        self.title = title
    }
}
