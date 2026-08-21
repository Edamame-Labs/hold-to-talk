import Testing
@testable import HoldToTalk

@Suite("S1-mini Model Tests")
struct S1MiniModelTests {
    // MARK: - Metadata

    @Test("Model info constants are populated")
    func modelInfoConstants() {
        #expect(!S1MiniModelInfo.id.isEmpty)
        #expect(!S1MiniModelInfo.displayName.isEmpty)
        #expect(!S1MiniModelInfo.sizeLabel.isEmpty)
        #expect(S1MiniModelInfo.englishOnly == true)
        #expect(S1MiniModelInfo.expectedSHA256.count == 64)
        #expect(S1MiniModelInfo.expectedByteCount > 0)
    }

    @Test("Download URL is pinned to a Hugging Face revision")
    func downloadURLIsPinned() {
        let url = S1MiniModelInfo.downloadURL
        #expect(url.scheme == "https")
        #expect(url.host()?.contains("huggingface.co") == true)
        // A branch name here would let the file change out from under the checksum.
        #expect(url.absoluteString.contains(S1MiniModelInfo.revision))
        #expect(!url.absoluteString.contains("/resolve/main/"))
        #expect(url.lastPathComponent == S1MiniModelInfo.fileName)
    }

    @Test("Provenance URLs are valid")
    func provenanceURLs() {
        #expect(S1MiniModelInfo.modelCardURL.absoluteString.contains("huggingface.co"))
        #expect(S1MiniModelInfo.ggufURL.absoluteString.contains("huggingface.co"))
        #expect(S1MiniModelInfo.llamaCppURL.absoluteString.contains("github.com"))
    }

    // MARK: - Prompt Format
    //
    // The system prompt, control line and empty think block are the input
    // format the model was trained on. Drift here silently degrades output
    // rather than failing loudly, so pin the exact shape.

    @Test("System prompt matches the trained wording exactly")
    func systemPromptIsExact() {
        #expect(S1MiniPrompt.systemPrompt == "You are a text normalizer for speech-to-text transcripts. The input begins with a control line specifying the styling, structure, and context settings; clean the transcript to match those settings and output only the cleaned text.")
    }

    @Test("Control line uses the trained axis vocabulary")
    func controlLineFormat() {
        let line = S1MiniPrompt.controlLine(styling: .semiFormal, structure: .prose)
        #expect(line == "[Styling: semi-formal] [Structure: prose] [Context: general]")
    }

    @Test("Control values match the trained sets")
    func controlValuesAreTrainedValues() {
        #expect(Set(CleanupStyling.allCases.map(\.rawValue)) == ["casual", "semi-casual", "semi-formal", "formal"])
        #expect(Set(CleanupStructure.allCases.map(\.rawValue)) == ["prose", "lists"])
        #expect(S1MiniPrompt.context == "general")
    }

    @Test("Prompt is the exact ChatML shape with an empty think block")
    func promptShape() {
        let prompt = S1MiniPrompt.build(
            transcript: "so um send the report by uh friday",
            styling: .semiFormal,
            structure: .prose
        )

        let expected = """
            <|im_start|>system
            You are a text normalizer for speech-to-text transcripts. The input begins with a control line specifying the styling, structure, and context settings; clean the transcript to match those settings and output only the cleaned text.<|im_end|>
            <|im_start|>user
            [Styling: semi-formal] [Structure: prose] [Context: general]
            so um send the report by uh friday<|im_end|>
            <|im_start|>assistant
            <think>

            </think>


            """

        #expect(prompt == expected)
    }

    @Test("Assistant prefix disables thinking")
    func assistantPrefixDisablesThinking() {
        let prompt = S1MiniPrompt.build(transcript: "hello", styling: .casual, structure: .prose)
        // Leaving this out yields an empty response from the model.
        #expect(prompt.hasSuffix("<|im_start|>assistant\n<think>\n\n</think>\n\n"))
    }

    @Test("Styling choice reaches the control line")
    func stylingReachesPrompt() {
        for styling in CleanupStyling.allCases {
            let prompt = S1MiniPrompt.build(transcript: "hi", styling: styling, structure: .lists)
            #expect(prompt.contains("[Styling: \(styling.rawValue)] [Structure: lists] [Context: general]"))
        }
    }

    // MARK: - Chunking

    @Test("Short transcripts stay in one chunk")
    func shortTranscriptSingleChunk() {
        let chunks = S1MiniPrompt.chunks(for: "so um i need to send the report by friday")
        #expect(chunks.count == 1)
        #expect(chunks[0] == "so um i need to send the report by friday")
    }

    @Test("Empty transcript produces no chunks")
    func emptyTranscript() {
        #expect(S1MiniPrompt.chunks(for: "").isEmpty)
        #expect(S1MiniPrompt.chunks(for: "   \n  ").isEmpty)
    }

    @Test("Long transcripts split at sentence boundaries")
    func longTranscriptSplitsAtSentences() {
        let sentence = "This is a sentence with exactly ten words in it. "
        let transcript = String(repeating: sentence, count: 60)  // 600 words

        let chunks = S1MiniPrompt.chunks(for: transcript, maxWords: 100)

        #expect(chunks.count > 1)
        for chunk in chunks {
            #expect(chunk.split(whereSeparator: \.isWhitespace).count <= 100)
            // Sentence-aligned chunks end on terminal punctuation.
            #expect(chunk.hasSuffix("."))
        }
    }

    @Test("Chunking preserves every word")
    func chunkingPreservesWords() {
        let transcript = String(repeating: "alpha beta gamma delta epsilon. ", count: 50)
        let original = transcript.split(whereSeparator: \.isWhitespace).map(String.init)

        let rejoined = S1MiniPrompt.chunks(for: transcript, maxWords: 40)
            .joined(separator: " ")
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)

        #expect(rejoined == original)
    }

    @Test("A single overlong sentence is split on word count")
    func overlongSentenceIsSplit() {
        let transcript = String(repeating: "word ", count: 250)  // no punctuation at all
        let chunks = S1MiniPrompt.chunks(for: transcript, maxWords: 100)

        #expect(chunks.count == 3)
        #expect(chunks[0].split(whereSeparator: \.isWhitespace).count == 100)
        #expect(chunks[2].split(whereSeparator: \.isWhitespace).count == 50)
    }

    // MARK: - Output Handling

    @Test("Sanitize strips control tokens")
    func sanitizeStripsControlTokens() {
        #expect(S1MiniPrompt.sanitize("Send the report.<|im_end|>") == "Send the report.")
        #expect(S1MiniPrompt.sanitize("  Send the report.\n\n") == "Send the report.")
    }

    @Test("Sanitize drops a leaked think block")
    func sanitizeDropsThinkBlock() {
        let leaked = "<think>\nThe user wants...\n</think>\n\nSend the report."
        #expect(S1MiniPrompt.sanitize(leaked) == "Send the report.")
    }

    @Test("Sanitize keeps list output intact")
    func sanitizeKeepsLists() {
        let listOutput = "We need:\n- Sunscreen\n- A first aid kit\n- Chargers"
        #expect(S1MiniPrompt.sanitize(listOutput) == listOutput)
    }

    @Test("Join drops chunks that normalize to nothing")
    func joinDropsEmptyChunks() {
        #expect(S1MiniPrompt.join(["First part.", "", "  ", "Second part."]) == "First part. Second part.")
        #expect(S1MiniPrompt.join(["", "  "]).isEmpty)
    }

    // MARK: - Provider Wiring

    @Test("S1-mini is a local provider that needs no API key")
    func providerIsLocal() {
        #expect(CleanupProvider.localS1Mini.isLocal)
        #expect(CleanupProvider.localS1Mini.cloudProvider == nil)
        #expect(CleanupProvider.localS1Mini.defaultModel.isEmpty)
    }

    // MARK: - Time Budget

    @Test("Budget scales with chunk count so long dictations are not dropped")
    func budgetScalesWithChunks() {
        // A flat per-call budget made every multi-chunk transcript time out and
        // come back uncleaned.
        #expect(LocalTextCleanup.budget(forChunks: 1) == LocalTextCleanup.chunkBudget)
        #expect(LocalTextCleanup.budget(forChunks: 3) == LocalTextCleanup.chunkBudget * 3)
        #expect(LocalTextCleanup.budget(forChunks: 3) > LocalTextCleanup.budget(forChunks: 1))
    }

    @Test("Budget is capped and never zero")
    func budgetIsBounded() {
        #expect(LocalTextCleanup.budget(forChunks: 1000) == LocalTextCleanup.maximumBudget)
        #expect(LocalTextCleanup.budget(forChunks: 0) == LocalTextCleanup.chunkBudget)
    }

    // MARK: - Language Gating

    @Test("S1-mini is the only provider gated to English")
    func onlyS1MiniIsEnglishGated() {
        #expect(!CleanupProvider.localS1Mini.supportsMultilingual)
        for provider in CleanupProvider.allCases where provider != .localS1Mini {
            #expect(provider.supportsMultilingual)
        }
    }

    @Test("English mode offers every provider")
    func englishModeOffersEverything() {
        #expect(CleanupProvider.available(for: .english) == CleanupProvider.allCases)
        for provider in CleanupProvider.allCases {
            #expect(provider.supports(.english))
        }
    }

    @Test("Multilingual mode hides only S1-mini")
    func multilingualHidesOnlyS1Mini() {
        let available = CleanupProvider.available(for: .multilingual)

        #expect(!available.contains(.localS1Mini))
        // Apple Intelligence is on-device and multilingual — dropping it would
        // push multilingual users to the cloud for no reason.
        #expect(available.contains(.appleIntelligence))
        #expect(available.contains(.openAI))
        #expect(available.contains(.anthropic))
        #expect(!CleanupProvider.localS1Mini.supports(.multilingual))
    }

    @Test("S1-mini is the default wherever the language allows")
    func s1MiniIsTheDefault() {
        #expect(CleanupProvider.defaultForThisMac(languageMode: .english) == .localS1Mini)
        // It cannot be the default for multilingual, so Apple Intelligence is.
        #expect(CleanupProvider.defaultForThisMac(languageMode: .multilingual) == .appleIntelligence)
    }

    @Test("Cloud providers always need setup")
    func cloudProvidersNeedSetup() {
        #expect(!CleanupProvider.openAI.isReadyWithoutSetup)
        #expect(!CleanupProvider.anthropic.isReadyWithoutSetup)
    }

    @Test("Language mode never defaults to a cloud provider")
    func defaultsStayLocalInEveryMode() {
        for mode in DictationLanguageMode.allCases {
            let fallback = CleanupProvider.defaultForThisMac(languageMode: mode)
            #expect(fallback.isLocal)
            #expect(fallback.supports(mode))
        }
    }

    @Test("Switching to multilingual clamps a stored S1-mini selection")
    func multilingualClampsStoredS1Mini() {
        // The user picked S1-mini in English mode, then switched to
        // multilingual. The stored value is now invalid and must not be used.
        let resolved = CleanupProvider.resolved(
            storedRawValue: CleanupProvider.localS1Mini.rawValue,
            languageMode: .multilingual
        )

        #expect(resolved != .localS1Mini)
        #expect(resolved.supports(.multilingual))
    }

    @Test("A valid stored selection survives resolution")
    func validStoredSelectionSurvives() {
        for mode in DictationLanguageMode.allCases {
            for provider in CleanupProvider.available(for: mode) {
                let resolved = CleanupProvider.resolved(
                    storedRawValue: provider.rawValue,
                    languageMode: mode
                )
                #expect(resolved == provider)
            }
        }
    }

    @Test("Unknown or missing stored values fall back safely")
    func unknownStoredValueFallsBack() {
        for mode in DictationLanguageMode.allCases {
            for stored in [nil, "", "some_removed_provider"] {
                let resolved = CleanupProvider.resolved(storedRawValue: stored, languageMode: mode)
                #expect(resolved.supports(mode))
                #expect(resolved.isLocal)
            }
        }
    }

    @Test("Resolution never yields a provider that cannot handle the language")
    func resolutionNeverViolatesLanguage() {
        for mode in DictationLanguageMode.allCases {
            for provider in CleanupProvider.allCases {
                let resolved = CleanupProvider.resolved(
                    storedRawValue: provider.rawValue,
                    languageMode: mode
                )
                #expect(resolved.supports(mode))
            }
        }
    }

    @Test("Language mode raw values are stable across releases")
    func languageModeRawValuesAreStable() {
        #expect(DictationLanguageMode.english.rawValue == "english")
        #expect(DictationLanguageMode.multilingual.rawValue == "multilingual")
    }

    // MARK: - Licence Attribution

    @Test("Attribution satisfies the licence naming clause")
    func attributionNamesModelAndAuthor() {
        // The licence's additional term requires this exact capitalization,
        // paired with Superwhisper, wherever the model is identified.
        #expect(S1MiniModelInfo.displayName == "S1-mini")
        #expect(S1MiniModelInfo.attributedName.contains("S1-mini"))
        #expect(S1MiniModelInfo.attributedName.contains("Superwhisper"))
        #expect(S1MiniModelInfo.trustSummary.contains("Superwhisper"))
    }

    @Test("Provider raw values are stable across releases")
    func providerRawValuesAreStable() {
        // These are persisted in UserDefaults; renaming one silently resets a
        // user's choice.
        #expect(CleanupProvider.localS1Mini.rawValue == "local_s1_mini")
        #expect(CleanupProvider.appleIntelligence.rawValue == "apple_intelligence")
        #expect(CleanupProvider.openAI.rawValue == "openai")
        #expect(CleanupProvider.anthropic.rawValue == "anthropic")
    }
}
