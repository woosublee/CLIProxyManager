import XCTest
@testable import CLIProxyManagerApp

final class ModelSelectionOptionsTests: XCTestCase {
    func testPreservesCurrentModelWhenAvailableModelsAreEmpty() {
        XCTAssertEqual(ModelSelectionOptions.options(currentModel: "gpt-5.5", availableModels: []), ["gpt-5.5"])
    }

    func testKeepsAvailableModelOrderWhenCurrentModelExists() {
        XCTAssertEqual(
            ModelSelectionOptions.options(currentModel: "gpt-5.5", availableModels: ["gpt-5.5", "gpt-5.6"]),
            ["gpt-5.5", "gpt-5.6"]
        )
    }

    func testPreservesCurrentModelWhenItIsMissingFromServerModels() {
        XCTAssertEqual(
            ModelSelectionOptions.options(currentModel: "custom-model", availableModels: ["gpt-5.5"]),
            ["custom-model", "gpt-5.5"]
        )
    }

    func testDoesNotAddCurrentRoutedModelWhenItIsMissingFromServerModels() {
        XCTAssertEqual(
            ModelSelectionOptions.options(currentModel: "codex-work/gpt-5.5", availableModels: ["gpt-5.5"]),
            ["gpt-5.5"]
        )
    }

    func testUsesFirstAvailableModelWhenCurrentModelIsEmpty() {
        XCTAssertEqual(
            ModelSelectionOptions.selectedModel(currentModel: "", availableModels: ["gpt-5.5", "gpt-5.6"]),
            "gpt-5.5"
        )
    }
}
