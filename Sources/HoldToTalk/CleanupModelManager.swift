import Foundation

/// Downloads and manages the on-device cleanup model (S1-mini GGUF).
///
/// Unlike the speech model this is a single file, so there is no archive to
/// list or extract — the download is verified by SHA-256 and moved into place.
@MainActor
final class CleanupModelManager: ObservableObject {
    @Published var downloadProgress: Double = 0
    @Published var isDownloading: Bool = false
    @Published var isDownloaded: Bool = false
    @Published var downloadError: String?

    private var downloadTask: Task<Void, Never>?
    private var downloadGeneration = 0

    nonisolated static var modelFileURL: URL {
        ModelManager.modelBase.appendingPathComponent(S1MiniModelInfo.fileName)
    }

    nonisolated static var isModelDownloaded: Bool {
        FileManager.default.fileExists(atPath: modelFileURL.path)
    }

    init() {
        refreshDownloadStatus()
    }

    func refreshDownloadStatus() {
        isDownloaded = Self.isModelDownloaded
    }

    func handleFreshOnboardingReset() {
        downloadGeneration += 1
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        downloadProgress = 0
        downloadError = nil
        refreshDownloadStatus()
    }

    func download() {
        guard !isDownloading else { return }
        downloadGeneration += 1
        let generation = downloadGeneration
        isDownloading = true
        downloadProgress = 0
        downloadError = nil

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let tempFileURL = try await self.downloadModelFile(generation: generation)
                defer { try? FileManager.default.removeItem(at: tempFileURL) }
                if Task.isCancelled { return }

                try await Task.detached(priority: .utility) {
                    try ModelManager.verifyChecksum(
                        of: tempFileURL,
                        expected: S1MiniModelInfo.expectedSHA256
                    )
                }.value
                if Task.isCancelled { return }

                try Self.install(tempFileURL)
                await MainActor.run {
                    guard self.downloadGeneration == generation else { return }
                    self.isDownloaded = true
                }
            } catch {
                if !Task.isCancelled {
                    await MainActor.run {
                        guard self.downloadGeneration == generation else { return }
                        self.downloadError = Self.userFacingDownloadError(error)
                    }
                    debugLog("[holdtotalk] Cleanup model download failed: \(error)")
                }
            }
            await MainActor.run {
                guard self.downloadGeneration == generation else { return }
                self.isDownloading = false
                self.downloadProgress = 0
                self.downloadTask = nil
            }
        }
        downloadTask = task
    }

    func cancelDownload() {
        downloadGeneration += 1
        downloadTask?.cancel()
        downloadTask = nil
        isDownloading = false
        downloadProgress = 0
    }

    func deleteModel() async {
        // Release the file before removing it so llama.cpp isn't holding a
        // mapping of a deleted inode.
        await LocalTextCleanup.shared.unload()
        let url = Self.modelFileURL
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        isDownloaded = false
    }

    func diskSize() -> String? {
        let url = Self.modelFileURL
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    // MARK: - Private

    private func downloadModelFile(generation: Int) async throws -> URL {
        let (tempURL, response) = try await URLSession.shared.download(
            from: S1MiniModelInfo.downloadURL,
            delegate: DownloadProgressDelegate { [weak self] fraction in
                Task { @MainActor [weak self] in
                    guard let self, self.downloadGeneration == generation else { return }
                    self.downloadProgress = fraction
                }
            }
        )

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            try? FileManager.default.removeItem(at: tempURL)
            throw CleanupModelError.downloadFailed(statusCode: http.statusCode)
        }
        return tempURL
    }

    nonisolated static func install(_ tempFileURL: URL) throws {
        let fileManager = FileManager.default
        let destination = modelFileURL
        try fileManager.createDirectory(at: ModelManager.modelBase, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: tempFileURL, to: destination)
    }

    nonisolated static func userFacingDownloadError(_ error: Error) -> String {
        if let modelError = error as? ModelExtractionError {
            if case .checksumMismatch = modelError { return modelError.localizedDescription }
            return "The cleanup model download could not be verified. Try again."
        }
        if let cleanupError = error as? CleanupModelError {
            return cleanupError.localizedDescription
        }

        let lower = error.localizedDescription.lowercased()
        if lower.contains("timed out")
            || lower.contains("network connection was lost")
            || lower.contains("internet")
            || lower.contains("offline") {
            return "Download failed due to a network issue. Check your connection and try again."
        }
        if lower.contains("no space") {
            return "Not enough free disk space for the cleanup model (\(S1MiniModelInfo.sizeLabel))."
        }
        return error.localizedDescription
    }
}

enum CleanupModelError: LocalizedError {
    case downloadFailed(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let statusCode):
            return "Could not download the cleanup model (HTTP \(statusCode)). Try again later."
        }
    }
}
