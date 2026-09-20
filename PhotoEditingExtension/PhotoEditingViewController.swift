import UIKit
import Photos
import PhotosUI

@MainActor
final class PhotoEditingViewController: UIViewController, PHContentEditingController {
    private var input: PHContentEditingInput?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var result: URL?
    private var directory: URL?
    private var pending = false
    private let preview = UIImageView()
    private let status = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let retry = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        preview.contentMode = .scaleAspectFit
        preview.accessibilityLabel = "Processed photograph"
        status.numberOfLines = 0
        status.accessibilityIdentifier = "PhotoServerStatus"
        status.textAlignment = .center
        retry.setTitle("Retry", for: .normal)
        retry.addTarget(self, action: #selector(retryProcessing), for: .touchUpInside)
        retry.isHidden = true
        let stack = UIStackView(arrangedSubviews: [preview, spinner, status, retry])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16)
        ])
        preview.setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    func canHandle(_ adjustmentData: PHAdjustmentData) -> Bool { false }

    func startContentEditing(with contentEditingInput: PHContentEditingInput, placeholderImage: UIImage) {
        loadViewIfNeeded()
        task?.cancel()
        input = contentEditingInput
        preview.image = placeholderImage
        beginProcessing()
    }
    @objc private func retryProcessing() { guard !pending else { return }; beginProcessing() }

    private func beginProcessing() {
        task?.cancel()
        cleanup()
        let attempt = UUID()
        generation = attempt
        result = nil
        pending = true
        retry.isHidden = true
        spinner.startAnimating()
        status.text = "Preparing photograph…"
        guard let input, input.mediaType == .image, !input.mediaSubtypes.contains(.photoLive), let source = input.fullSizeImageURL else {
            fail("Only full-size still photographs are supported. Download the photo from iCloud in Photos and try again.")
            return
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoServer-\(attempt.uuidString)", isDirectory: true)
        directory = work
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                let preparation = Task.detached(priority: .userInitiated) { try GeminiClient.makeRequestFile(image: source, directory: work) }
                let request = try await withTaskCancellationHandler(operation: { try await preparation.value }, onCancel: { preparation.cancel() })
                try Task.checkCancellation()
                status.text = "Uploading and processing…"
                let client = GeminiClient(baseURL: try Settings.validatedURL(Settings.address))
                let file = try await client.process(requestFile: request, directory: work)
                try Task.checkCancellation()
                guard generation == attempt else { return }
                status.text = "Preparing result…"
                let image = try await Task.detached { try ImageFiles.preview(file) }.value
                try Task.checkCancellation()
                guard generation == attempt else { return }
                result = file
                preview.image = image
                pending = false
                spinner.stopAnimating()
                status.text = "Ready. Tap Done to apply."
                try? FileManager.default.removeItem(at: request)
            } catch {
                if generation == attempt && !Task.isCancelled { fail(error.localizedDescription) }
            }
            if result != work.appendingPathComponent("result.image") {
                try? FileManager.default.removeItem(at: work)
            }
        }
    }

    private func fail(_ message: String) {
        pending = false
        spinner.stopAnimating()
        status.text = message
        retry.isHidden = false
    }
    func finishContentEditing(completionHandler: @escaping (PHContentEditingOutput?) -> Void) {
        let attempt = generation
        Task {
            await task?.value
            guard generation == attempt, let input, let result else { completionHandler(nil); return }
            do {
                let output = PHContentEditingOutput(contentEditingInput: input)
                let destination = output.renderedContentURL
                try await Task.detached { try ImageFiles.prepareJPEG(from: result, to: destination) }.value
                guard generation == attempt else { completionHandler(nil); return }
                let metadata = try JSONSerialization.data(withJSONObject: ["version": 1, "model": Settings.model, "operation": "gemini-web"])
                output.adjustmentData = PHAdjustmentData(formatIdentifier: "com.example.PhotoServer.adjustment", formatVersion: "1.0", data: metadata)
                completionHandler(output)
                cleanup()
            } catch {
                fail(error.localizedDescription)
                completionHandler(nil)
            }
        }
    }
    func cancelContentEditing() {
        generation = UUID()
        task?.cancel()
        pending = false
        result = nil
        // The processing task removes its own files after cancellation has completed.
        cleanup()
    }
    var shouldShowCancelConfirmation: Bool { pending || result != nil }
    private func cleanup() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }
}
