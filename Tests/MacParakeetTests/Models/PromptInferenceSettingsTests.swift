import XCTest
@testable import MacParakeetCore

final class PromptInferenceSettingsTests: XCTestCase {
    func testDefaultNormalizesToNil() throws {
        let settings = PromptInferenceSettings()
        XCTAssertTrue(settings.isDefault)
        XCTAssertNil(try settings.validated())
    }

    func testValidationAcceptsBoundaryValues() throws {
        XCTAssertNotNil(
            try PromptInferenceSettings(
                temperature: 0,
                topP: 1,
                topK: 0,
                maxTokens: 131_072,
                seed: Int.min,
                thinkingMode: .disabled
            ).validated())
    }

    func testValidationRejectsInvalidAndNonFiniteValues() {
        XCTAssertThrowsError(try PromptInferenceSettings(temperature: .nan).validated())
        XCTAssertThrowsError(try PromptInferenceSettings(temperature: .infinity).validated())
        XCTAssertThrowsError(try PromptInferenceSettings(topP: -.infinity).validated())
        XCTAssertThrowsError(try PromptInferenceSettings(temperature: 2.000_001).validated())
        XCTAssertThrowsError(try PromptInferenceSettings(topP: -0.000_001).validated())
        XCTAssertThrowsError(try PromptInferenceSettings(topK: 1001).validated())
        XCTAssertThrowsError(try PromptInferenceSettings(maxTokens: 0).validated())
    }

    func testCodableRoundTrip() throws {
        let settings = PromptInferenceSettings(
            temperature: 0.2,
            topP: 0.9,
            topK: 20,
            maxTokens: 4096,
            seed: 42,
            thinkingMode: .enabled,
            reasoningEffort: .xhigh
        )
        let decoded = try JSONDecoder().decode(
            PromptInferenceSettings.self,
            from: JSONEncoder().encode(settings)
        )
        XCTAssertEqual(decoded, settings)
    }

    func testEveryReasoningEffortValueRoundTrips() throws {
        for effort in PromptInferenceSettings.ReasoningEffort.allCases {
            let settings = PromptInferenceSettings(
                thinkingMode: .enabled,
                reasoningEffort: effort
            )
            let decoded = try JSONDecoder().decode(
                PromptInferenceSettings.self,
                from: JSONEncoder().encode(settings)
            )
            XCTAssertEqual(decoded.reasoningEffort, effort)
        }
    }

    func testDecodingOlderPartialJSONUsesDefaultThinkingMode() throws {
        let empty = try JSONDecoder().decode(
            PromptInferenceSettings.self,
            from: Data("{}".utf8)
        )
        XCTAssertEqual(empty, PromptInferenceSettings())

        let partial = try JSONDecoder().decode(
            PromptInferenceSettings.self,
            from: Data(#"{"temperature":0.2}"#.utf8)
        )
        XCTAssertEqual(partial, PromptInferenceSettings(temperature: 0.2))
    }

    func testReasoningEffortIsEffectiveOnlyWhenThinkingIsEnabled() throws {
        XCTAssertEqual(
            try PromptInferenceSettings(
                thinkingMode: .enabled,
                reasoningEffort: .medium
            ).validated(),
            PromptInferenceSettings(thinkingMode: .enabled, reasoningEffort: .medium)
        )
        XCTAssertEqual(
            try PromptInferenceSettings(
                thinkingMode: .disabled,
                reasoningEffort: .xhigh
            ).validated(),
            PromptInferenceSettings(thinkingMode: .disabled)
        )
        XCTAssertNil(try PromptInferenceSettings(reasoningEffort: .low).validated())
    }

    func testOverlayPreservesHistoricalDefaultsWhenSettingsAreAbsent() {
        XCTAssertEqual(ChatCompletionOptions.default.applying(nil), .default)
        XCTAssertEqual(
            ChatCompletionOptions.default.applying(PromptInferenceSettings()),
            .default
        )
    }

    func testOverlayPreservesBaselineReasoningEffortWhenThinkingIsInherited() {
        let baseline = ChatCompletionOptions(
            temperature: 0.7,
            thinkingMode: .enabled,
            reasoningEffort: .high
        )

        let overlaid = baseline.applying(PromptInferenceSettings(maxTokens: 512))

        XCTAssertEqual(overlaid.thinkingMode, .enabled)
        XCTAssertEqual(overlaid.reasoningEffort, .high)
        XCTAssertEqual(overlaid.maxTokens, 512)
    }

    func testEffectiveReceiptIncludesInheritedValuesActuallySent() {
        let custom = PromptInferenceCapabilityResolver.resolve(
            config: .openaiCompatible(
                model: "generic-model",
                baseURL: URL(string: "http://localhost:8080/v1")!
            ),
            requested: nil
        )
        XCTAssertEqual(custom.effectiveSettings, PromptInferenceSettings(temperature: 0.7))

        let anthropic = PromptInferenceCapabilityResolver.resolve(
            config: .anthropic(apiKey: "key", model: "claude-sonnet-5"),
            requested: nil
        )
        XCTAssertEqual(anthropic.effectiveSettings, PromptInferenceSettings(maxTokens: 4096))

        let openAIReasoning = PromptInferenceCapabilityResolver.resolve(
            config: .openai(apiKey: "key", model: "gpt-5.5"),
            requested: nil
        )
        XCTAssertNil(openAIReasoning.effectiveSettings)
    }

    func testCustomOpenAICompatibleSupportsEverySetting() {
        let requested = PromptInferenceSettings(
            temperature: 0.2,
            topP: 0.9,
            topK: 20,
            maxTokens: 4096,
            seed: 42,
            thinkingMode: .enabled,
            reasoningEffort: .xhigh
        )
        let resolution = PromptInferenceCapabilityResolver.resolve(
            config: .openaiCompatible(
                model: "local-model",
                baseURL: URL(string: "http://localhost:8080/v1")!
            ),
            requested: requested
        )

        XCTAssertEqual(resolution.effectiveSettings, requested)
        XCTAssertTrue(resolution.unsupportedSettings.isEmpty)
        XCTAssertEqual(resolution.options.temperature, 0.2)
        XCTAssertEqual(resolution.options.thinkingMode, .enabled)
        XCTAssertEqual(resolution.options.reasoningEffort, .xhigh)
    }

    func testOpenAIReasoningModelReportsUnsupportedSampling() {
        let resolution = PromptInferenceCapabilityResolver.resolve(
            config: .openai(apiKey: "key", model: "gpt-5.5"),
            requested: PromptInferenceSettings(
                temperature: 0.2,
                topP: 0.9,
                topK: 20,
                maxTokens: 4096,
                seed: 42,
                thinkingMode: .enabled,
                reasoningEffort: .medium
            )
        )

        XCTAssertEqual(resolution.options.maxTokens, 4096)
        XCTAssertNil(resolution.options.temperature)
        XCTAssertEqual(
            resolution.unsupportedSettings,
            [.temperature, .topP, .topK, .seed, .thinkingMode, .reasoningEffort]
        )
        XCTAssertEqual(
            resolution.effectiveSettings,
            PromptInferenceSettings(maxTokens: 4096)
        )
    }

    func testLocalCLIReportsAllExplicitSettingsUnsupported() {
        let requested = PromptInferenceSettings(temperature: 0.2, thinkingMode: .disabled)
        let resolution = PromptInferenceCapabilityResolver.resolve(
            config: LLMProviderConfig(
                id: .localCLI,
                baseURL: URL(string: "http://localhost")!,
                apiKey: nil,
                modelName: "claude",
                isLocal: false
            ),
            requested: requested
        )

        XCTAssertNil(resolution.effectiveSettings)
        XCTAssertEqual(resolution.unsupportedSettings, [.temperature, .thinkingMode])
        XCTAssertNil(resolution.options.temperature)
    }

    func testOllamaDefaultPreservesLegacyRequestSemantics() {
        let resolution = PromptInferenceCapabilityResolver.resolve(
            config: .ollama(model: "qwen3.5:9b"),
            requested: nil
        )

        XCTAssertNil(resolution.options.temperature)
        XCTAssertEqual(resolution.options.thinkingMode, .disabled)
        XCTAssertEqual(
            resolution.effectiveSettings,
            PromptInferenceSettings(thinkingMode: .disabled)
        )
        XCTAssertTrue(resolution.unsupportedSettings.isEmpty)
    }

    func testOllamaReportsReasoningEffortUnsupported() {
        let resolution = PromptInferenceCapabilityResolver.resolve(
            config: .ollama(model: "local-model"),
            requested: PromptInferenceSettings(
                thinkingMode: .enabled,
                reasoningEffort: .medium
            )
        )

        XCTAssertEqual(resolution.options.thinkingMode, .enabled)
        XCTAssertNil(resolution.options.reasoningEffort)
        XCTAssertEqual(resolution.unsupportedSettings, [.reasoningEffort])
        XCTAssertEqual(
            resolution.effectiveSettings,
            PromptInferenceSettings(thinkingMode: .enabled)
        )
    }
}
