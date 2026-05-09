import XCTest
@testable import CLIProxyManagerApp

final class ModelSelectionOptionsTests: XCTestCase {
    func testUsesCurrentModelWhenAvailableModelsAreEmpty() {
        XCTAssertEqual(ModelSelectionOptions.options(currentModel: "gpt-5.5", availableModels: []), ["gpt-5.5"])
    }

    func testKeepsAvailableModelOrderWhenCurrentModelExists() {
        XCTAssertEqual(
            ModelSelectionOptions.options(currentModel: "gpt-5.5", availableModels: ["gpt-5.5", "gpt-5.6"]),
            ["gpt-5.5", "gpt-5.6"]
        )
    }

    func testPreservesCustomCurrentModelBeforeAvailableModels() {
        XCTAssertEqual(
            ModelSelectionOptions.options(currentModel: "custom-model", availableModels: ["gpt-5.5"]),
            ["custom-model", "gpt-5.5"]
        )
    }

    func testUsesFirstAvailableModelWhenCurrentModelIsEmpty() {
        XCTAssertEqual(
            ModelSelectionOptions.selectedModel(currentModel: "", availableModels: ["gpt-5.5", "gpt-5.6"]),
            "gpt-5.5"
        )
    }
}
