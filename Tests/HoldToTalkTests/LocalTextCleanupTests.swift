import Testing
@testable import HoldToTalk

/// End-to-end tests against the real S1-mini weights.
///
/// The model is a 462 MB runtime download, not a build artifact, so these are
/// skipped wherever it is absent (CI, fresh checkouts). Download it from
/// Settings › Cleanup, or run the app once with the local cleanup provider
/// selected, to enable them.
@Suite("Local Text Cleanup (requires downloaded model)")
struct LocalTextCleanupTests {
    static var modelAvailable: Bool { CleanupModelManager.isModelDownloaded }

    private func clean(
        _ text: String,
        styling: CleanupStyling = .semiFormal,
        structure: CleanupStructure = .prose
    ) async throws -> String {
        try await LocalTextCleanup.shared.cleanup(text, styling: styling, structure: structure)
    }

    @Test("Model loads and unloads", .enabled(if: modelAvailable))
    func loadsAndUnloads() async throws {
        try await LocalTextCleanup.shared.warmUp()
        #expect(await LocalTextCleanup.shared.isLoaded)
        await LocalTextCleanup.shared.unload()
        #expect(await LocalTextCleanup.shared.isLoaded == false)
    }

    @Test("Removes fillers and resolves self-corrections", .enabled(if: modelAvailable))
    func resolvesSelfCorrection() async throws {
        let result = try await clean("so um i need to like send the the report by uh friday no wait make that thursday")

        #expect(result.localizedCaseInsensitiveContains("Thursday"))
        #expect(!result.localizedCaseInsensitiveContains("Friday"))
        #expect(!result.localizedCaseInsensitiveContains(" um "))
        #expect(!result.localizedCaseInsensitiveContains(" uh "))
    }

    @Test("Applies inverse text normalization", .enabled(if: modelAvailable))
    func inverseTextNormalization() async throws {
        let result = try await clean("i think the answer is forty two no sorry forty three")
        #expect(result.contains("43"))
    }

    @Test("Renders spoken email addresses", .enabled(if: modelAvailable))
    func spokenEmailAddress() async throws {
        let result = try await clean("send it to support at superwhisper dot com")
        #expect(result.localizedCaseInsensitiveContains("support@superwhisper.com"))
    }

    @Test("Styling controls capitalization", .enabled(if: modelAvailable))
    func stylingControlsRegister() async throws {
        let input = "hmm im gonna be late theres a cute dog outside"

        let casual = try await clean(input, styling: .casual)
        let formal = try await clean(input, styling: .formal)

        // casual keeps everything lowercase; formal expands contractions.
        #expect(casual == casual.lowercased())
        #expect(formal.localizedCaseInsensitiveContains("I am") || formal.localizedCaseInsensitiveContains("going to"))
    }

    @Test("Structure controls list formatting", .enabled(if: modelAvailable))
    func structureControlsLists() async throws {
        let input = "i need to buy milk eggs bread butter and some coffee from the store"

        let prose = try await clean(input, structure: .prose)
        let lists = try await clean(input, structure: .lists)

        // The model is conservative about bulleting — it wants a clear
        // enumeration of at least three items, which this input is.
        #expect(!prose.contains("\n- "))
        #expect(!prose.contains("\n1. "))
        #expect(lists.contains("\n- ") || lists.contains("\n1. "))
    }

    @Test("Output never leaks control tokens", .enabled(if: modelAvailable))
    func noControlTokenLeakage() async throws {
        let result = try await clean("this is a test of the transcription cleanup pipeline")

        for token in ["<|im_start|>", "<|im_end|>", "<think>", "</think>", "[Styling:"] {
            #expect(!result.contains(token))
        }
    }

    @Test("Long transcripts are chunked and rejoined", .enabled(if: modelAvailable))
    func longTranscriptRoundTrip() async throws {
        // Longer than one chunk, so this exercises the chunk/rejoin path.
        let sentence = "and then we talked about the roadmap for the next quarter which was um pretty long. "
        let transcript = String(repeating: sentence, count: 40)

        let result = try await clean(transcript)

        #expect(!result.isEmpty)
        #expect(result.localizedCaseInsensitiveContains("roadmap"))
    }

    @Test("Empty input is returned unchanged", .enabled(if: modelAvailable))
    func emptyInput() async throws {
        #expect(try await clean("") == "")
    }
}
