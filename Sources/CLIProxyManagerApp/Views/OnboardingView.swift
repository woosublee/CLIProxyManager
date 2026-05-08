import SwiftUI

struct OnboardingView: View {
    @StateObject private var viewModel = OnboardingViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 10) {
                Text("CLIProxy Manager 설정")
                    .font(.largeTitle.bold())
                Text("앱이 Claude Code, Claude API, OpenAI/Codex 프로필을 사용할 준비를 확인합니다.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(viewModel.steps.enumerated()), id: \.element.id) { index, step in
                    HStack(spacing: 14) {
                        Text("\(index + 1)")
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(Color.accentColor))

                        Text(step.title)
                            .font(.headline)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

            Spacer(minLength: 0)
        }
        .padding(40)
        .frame(minWidth: 720, minHeight: 480)
    }
}
