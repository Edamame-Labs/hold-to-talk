import CommonCrypto
import Foundation

struct SpeechModelInfo {
    static let id = "parakeet-tdt-0.6b-v2-int8"
    static let displayName = "Parakeet TDT 0.6B"
    static let sizeLabel = "~640 MB"
    static let englishOnly = true
    static let languageSummary = "English only"

    static let downloadURL = URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8.tar.bz2")!
    static let modelDirectoryName = "sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8"
    static let markerFile = "tokens.txt"
    /// SHA-256 hash of the model archive for integrity verification after download.
    static let expectedSHA256 = "157c157bc51155e03e37d2466522a3a737dd9c72bb25f36eb18912964161e1ad"

    static let parakeetURL = URL(string: "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2")!
    static let sherpaOnnxURL = URL(string: "https://github.com/k2-fsa/sherpa-onnx")!
    static let nvidiaURL = URL(string: "https://www.nvidia.com/en-us/ai-data-science/products/nemo/")!

    static let trustSummary = "Runs fully on your Mac after download. Hold to Talk downloads NVIDIA's Parakeet TDT 0.6B model (int8 quantized) from the sherpa-onnx GitHub releases. The model is open-source (Apache 2.0) and English-only."
}

@MainActor
final class ModelManager: ObservableObject {
    @Published var downloadProgress: Double = 0
    @Published var isDownloading: Bool = false
    @Published var isDownloaded: Bool = false
    @Published var downloadError: String?

    private var downloadTask: Task<Void, Never>?

    nonisolated static let modelBase: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("HoldToTalk/models")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    nonisolated static var isModelDownloaded: Bool {
        let marker = modelBase
            .appendingPathComponent(SpeechModelInfo.modelDirectoryName)
            .appendingPathComponent(SpeechModelInfo.markerFile)
        return FileManager.default.fileExists(atPath: marker.path)
    }

    var modelDirectory: URL {
        Self.modelBase.appendingPathComponent(SpeechModelInfo.modelDirectoryName)
    }

    init() {
        refreshDownloadStatus()
    }

    func refreshDownloadStatus() {
        let marker = modelDirectory.appendingPathComponent(SpeechModelInfo.markerFile)
        isDownloaded = FileManager.default.fileExists(atPath: marker.path)
    }

    func handleFreshOnboardingReset() {
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        downloadProgress = 0
        downloadError = nil
        refreshDownloadStatus()
    }

    func download() {
        guard !isDownloading else { return }
        isDownloading = true
        downloadProgress = 0
        downloadError = nil

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let tempFileURL = try await self.downloadArchive()
                defer { try? FileManager.default.removeItem(at: tempFileURL) }
                if Task.isCancelled { return }
                try await Task.detached(priority: .utility) {
                    try Self.verifyChecksum(of: tempFileURL, expected: SpeechModelInfo.expectedSHA256)
                }.value
                try await self.extractArchive(tempFileURL)
                if !Task.isCancelled {
                    await MainActor.run { self.isDownloaded = true }
                }
            } catch {
                if !Task.isCancelled {
                    await MainActor.run {
                        self.downloadError = self.userFacingDownloadError(error)
                    }
                    print("[modelmanager] Download failed: \(error)")
                }
            }
            await MainActor.run {
                self.isDownloading = false
                self.downloadProgress = 0
                self.downloadTask = nil
            }
        }
        downloadTask = task
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        downloadProgress = 0
    }

    func deleteModel() {
        let dir = modelDirectory
        if FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.removeItem(at: dir)
        }
        isDownloaded = false
    }

    func diskSize() -> String? {
        let dir = modelDirectory
        guard FileManager.default.fileExists(atPath: dir.path) else { return nil }
        guard let total = directorySize(dir) else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
    }

    /// Deletes legacy WhisperKit model directories if they exist.
    func cleanupLegacyWhisperKitModels() {
        let legacyRepo = Self.modelBase.appendingPathComponent("models/argmaxinc/whisperkit-coreml")
        if FileManager.default.fileExists(atPath: legacyRepo.path) {
            try? FileManager.default.removeItem(at: legacyRepo)
            print("[modelmanager] Cleaned up legacy WhisperKit models directory.")
        }
        // Also clean the parent "models/argmaxinc" directory if empty
        let argmaxDir = Self.modelBase.appendingPathComponent("models/argmaxinc")
        if FileManager.default.fileExists(atPath: argmaxDir.path) {
            let contents = try? FileManager.default.contentsOfDirectory(atPath: argmaxDir.path)
            if contents?.isEmpty ?? true {
                try? FileManager.default.removeItem(at: argmaxDir)
            }
        }
        let modelsDir = Self.modelBase.appendingPathComponent("models")
        if FileManager.default.fileExists(atPath: modelsDir.path) {
            let contents = try? FileManager.default.contentsOfDirectory(atPath: modelsDir.path)
            if contents?.isEmpty ?? true {
                try? FileManager.default.removeItem(at: modelsDir)
            }
        }
    }

    // MARK: - Private

    /// Verify the SHA-256 checksum of a downloaded file.
    nonisolated static func verifyChecksum(of fileURL: URL, expected: String) throws {
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(buffer.count), &digest)
        }
        let actual = digest.map { String(format: "%02x", $0) }.joined()
        guard actual == expected else {
            throw ModelExtractionError.checksumMismatch(expected: expected, actual: actual)
        }
    }

    nonisolated static func validatedModelArchiveDestinations(
        for entries: [String],
        modelDirectory: URL,
        expectedRoot: String = SpeechModelInfo.modelDirectoryName
    ) throws -> [URL] {
        let destinationRoot = modelDirectory.standardizedFileURL.path
        let destinationPrefix = destinationRoot.hasSuffix("/") ? destinationRoot : destinationRoot + "/"
        var destinations: [URL] = []

        for entry in entries {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard !trimmed.hasPrefix("/") else {
                throw ModelExtractionError.unsafeArchivePath(trimmed)
            }

            let components = trimmed
                .split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)

            guard let root = components.first else { continue }
            guard root == expectedRoot else {
                throw ModelExtractionError.unexpectedArchiveRoot(root)
            }
            guard !components.contains("."), !components.contains("..") else {
                throw ModelExtractionError.unsafeArchivePath(trimmed)
            }

            let strippedComponents = components.dropFirst()
            guard !strippedComponents.isEmpty else { continue }

            let destination = strippedComponents.reduce(modelDirectory) { partial, component in
                partial.appendingPathComponent(component)
            }.standardizedFileURL
            let path = destination.path
            guard path == destinationRoot || path.hasPrefix(destinationPrefix) else {
                throw ModelExtractionError.unsafeArchivePath(trimmed)
            }
            destinations.append(destination)
        }

        guard !destinations.isEmpty else {
            throw ModelExtractionError.emptyArchive
        }
        return destinations
    }

    nonisolated static func validateModelArchiveEntryTypes(_ details: [String]) throws {
        for detail in details {
            guard let type = detail.first else { continue }
            guard type == "-" || type == "d" else {
                throw ModelExtractionError.unsafeArchivePath(detail)
            }
        }
    }

    private nonisolated static func listArchiveEntries(_ archiveURL: URL) throws -> [String] {
        let details = try runTar(arguments: ["-tvjf", archiveURL.path])
        try validateModelArchiveEntryTypes(details)
        return try runTar(arguments: ["-tjf", archiveURL.path])
    }

    private nonisolated static func runTar(arguments: [String]) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "Unknown archive listing error"
            throw ModelExtractionError.extractionFailed(message)
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private func downloadArchive() async throws -> URL {
        let (tempURL, _) = try await URLSession.shared.download(
            from: SpeechModelInfo.downloadURL,
            delegate: DownloadProgressDelegate { [weak self] fraction in
                Task { @MainActor [weak self] in
                    self?.downloadProgress = fraction
                }
            }
        )
        return tempURL
    }

    private func extractArchive(_ archiveURL: URL) async throws {
        try await Task.detached(priority: .utility) {
            let fm = FileManager.default
            let destParent = Self.modelBase
            let modelDirectory = destParent.appendingPathComponent(
                SpeechModelInfo.modelDirectoryName,
                isDirectory: true
            )

            // Ensure destination parent exists
            try fm.createDirectory(at: destParent, withIntermediateDirectories: true)
            let entries = try Self.listArchiveEntries(archiveURL)
            _ = try Self.validatedModelArchiveDestinations(
                for: entries,
                modelDirectory: modelDirectory
            )
            if fm.fileExists(atPath: modelDirectory.path) {
                try fm.removeItem(at: modelDirectory)
            }
            try fm.createDirectory(at: modelDirectory, withIntermediateDirectories: true)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = [
                "-xjf", archiveURL.path,
                "--strip-components", "1",
                "-C", modelDirectory.path,
            ]

            let pipe = Pipe()
            process.standardError = pipe

            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let errorData = pipe.fileHandleForReading.readDataToEndOfFile()
                let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown extraction error"
                throw ModelExtractionError.extractionFailed(errorMessage)
            }
        }.value
    }

    private func directorySize(_ url: URL) -> UInt64? {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += UInt64(size)
            }
        }
        return total
    }

    private func userFacingDownloadError(_ error: Error) -> String {
        let message = error.localizedDescription
        let lower = message.lowercased()

        if lower.contains("timed out")
            || lower.contains("network connection was lost")
            || lower.contains("internet")
            || lower.contains("offline") {
            return "Download failed due to a network issue. Check your connection and try again."
        }

        if case ModelExtractionError.checksumMismatch = error {
            return error.localizedDescription
        }

        if error is ModelExtractionError {
            return "Failed to extract the model archive. Try deleting and re-downloading."
        }

        return message
    }
}

enum ModelExtractionError: LocalizedError {
    case extractionFailed(String)
    case checksumMismatch(expected: String, actual: String)
    case emptyArchive
    case unexpectedArchiveRoot(String)
    case unsafeArchivePath(String)

    var errorDescription: String? {
        switch self {
        case .extractionFailed(let message):
            return "Model extraction failed: \(message)"
        case .checksumMismatch(let expected, let actual):
            return "Model integrity check failed. Expected SHA-256 \(expected.prefix(12))..., got \(actual.prefix(12)).... The download may be corrupted or tampered with. Please try again."
        case .emptyArchive:
            return "Model archive integrity check failed: archive did not contain model files."
        case .unexpectedArchiveRoot(let root):
            return "Model archive integrity check failed: unexpected top-level path \(root)."
        case .unsafeArchivePath(let path):
            return "Model archive integrity check failed: unsafe path \(path)."
        }
    }
}

// MARK: - Download Progress Delegate

final class DownloadProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let handler: @Sendable (Double) -> Void

    init(handler: @escaping @Sendable (Double) -> Void) {
        self.handler = handler
    }

    nonisolated func urlSession(
        _ session: URLSession,
        didCreateTask task: URLSessionTask
    ) {
        // Monitor download progress via observation
        let observation = task.progress.observe(\.fractionCompleted) { [handler] progress, _ in
            handler(progress.fractionCompleted)
        }
        objc_setAssociatedObject(task, "progressObservation", observation, .OBJC_ASSOCIATION_RETAIN)
    }
}
