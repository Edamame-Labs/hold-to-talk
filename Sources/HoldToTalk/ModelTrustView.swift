import SwiftUI

struct ModelTrustView: View {
    struct Reference: Identifiable {
        let id = UUID()
        let label: String
        let title: String
        let url: URL
    }

    var summary: String = SpeechModelInfo.trustSummary
    var badges: [String] = ["On-device", SpeechModelInfo.languageSummary, "Parakeet TDT"]
    var references: [Reference] = [
        Reference(label: "Model:", title: "nvidia/parakeet-tdt-0.6b-v2", url: SpeechModelInfo.parakeetURL),
        Reference(label: "Runtime:", title: "sherpa-onnx on GitHub", url: SpeechModelInfo.sherpaOnnxURL),
    ]
    var license: String = "Apache 2.0"

    /// Trust details for the on-device cleanup model.
    static var cleanupModel: ModelTrustView {
        ModelTrustView(
            summary: S1MiniModelInfo.trustSummary,
            badges: ["On-device", S1MiniModelInfo.languageSummary, "Qwen3 0.6B"],
            references: [
                Reference(label: "Model:", title: "superwhisper/s1-mini", url: S1MiniModelInfo.modelCardURL),
                Reference(label: "Weights:", title: "superwhisper/s1-mini-GGUF", url: S1MiniModelInfo.ggufURL),
                Reference(label: "Runtime:", title: "llama.cpp on GitHub", url: S1MiniModelInfo.llamaCppURL),
            ],
            license: "Apache 2.0 with a naming clause"
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("About this download")
                .font(.headline)

            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                ForEach(badges, id: \.self) { badge in
                    trustBadge(badge)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(references) { reference in
                    HStack(spacing: 6) {
                        Text(reference.label)
                            .foregroundStyle(.secondary)
                        Link(reference.title, destination: reference.url)
                    }
                }

                HStack(spacing: 6) {
                    Text("License:")
                        .foregroundStyle(.secondary)
                    Text(license)
                }
            }
            .font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.quaternary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.separator)
        )
    }

    private func trustBadge(_ label: String) -> some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary, in: Capsule())
    }
}
