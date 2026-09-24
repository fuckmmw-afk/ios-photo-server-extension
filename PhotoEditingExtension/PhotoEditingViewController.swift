import UIKit
import Photos
import PhotosUI

final class PhotoEditingViewController: UIViewController, PHContentEditingController {
    private var input: PHContentEditingInput?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var result: URL?
    private var processedModel = ""
    private var directory: URL?
    private var pending = false
    private var resolutionConsent = ResolutionConsent()
    private let preview = UIImageView()
    private let status = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let retry = UIButton(type: .system)
    private let applyAnyway = UIButton(type: .system)
    private let keepOriginal = UIButton(type: .system)

    override func loadView() {
        // Photos may ask the principal class for its view before viewDidLoad.  A
        // programmatic root avoids a zero-sized/black extension host while the
        // PHContentEditingInput is still being delivered.
        let root = UIView(frame: .zero)
        root.backgroundColor = .systemBackground
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        preview.contentMode = .scaleAspectFit
        preview.accessibilityLabel = "Processed photograph"
        preview.backgroundColor = .secondarySystemFill
        status.numberOfLines = 0
        status.accessibilityIdentifier = "PhotoServerStatus"
        status.textAlignment = .center
        status.font = .preferredFont(forTextStyle: .body)
        status.textColor = .label
        status.text = "Starting PhotoServer…"
        retry.setTitle("Retry", for: .normal)
        retry.addTarget(self, action: #selector(retryProcessing), for: .touchUpInside)
        retry.isHidden = true
        applyAnyway.setTitle("Apply anyway", for: .normal)
        applyAnyway.accessibilityIdentifier = "PhotoServerApplyAnyway"
        applyAnyway.addTarget(self, action: #selector(applySmallerResult), for: .touchUpInside)
        applyAnyway.isHidden = true
        keepOriginal.setTitle("Keep original", for: .normal)
        keepOriginal.accessibilityIdentifier = "PhotoServerKeepOriginal"
        keepOriginal.addTarget(self, action: #selector(keepSourceImage), for: .touchUpInside)
        keepOriginal.isHidden = true
        spinner.hidesWhenStopped = true
        spinner.startAnimating()
        let stack = UIStackView(arrangedSubviews: [preview, spinner, status, applyAnyway, keepOriginal, retry])
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            preview.heightAnchor.constraint(greaterThanOrEqualToConstant: 160)
        ])
        preview.setContentHuggingPriority(.defaultLow, for: .vertical)
        status.setContentCompressionResistancePriority(.required, for: .vertical)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if input == nil {
            setStatus("Waiting for the photograph from Photos…")
        }
    }

    func canHandle(_ adjustmentData: PHAdjustmentData) -> Bool { false }

    func startContentEditing(with contentEditingInput: PHContentEditingInput, placeholderImage: UIImage) {
        loadViewIfNeeded()
        task?.cancel()
        input = contentEditingInput
        DispatchQueue.main.async { [weak self] in
            self?.preview.image = placeholderImage
        }
        beginProcessing()
    }
    @objc private func retryProcessing() { guard !pending else { return }; beginProcessing() }

    @objc private func applySmallerResult() {
        guard resolutionConsent.needsChoice else { return }
        resolutionConsent.choose(.applyAnyway)
        applyAnyway.isHidden = true
        keepOriginal.isHidden = true
        setStatus("Ready. Tap Done to apply the smaller result.")
    }

    @objc private func keepSourceImage() {
        guard resolutionConsent.needsChoice else { return }
        resolutionConsent.choose(.keepOriginal)
        result = nil
        applyAnyway.isHidden = true
        keepOriginal.isHidden = true
        cleanup()
        setStatus("Original kept. Tap Done to finish.")
    }

    private func beginProcessing() {
        task?.cancel()
        cleanup()
        removeOrphanedWorkDirectories()
        task = nil
        let attempt = UUID()
        generation = attempt
        result = nil
        resolutionConsent = ResolutionConsent()
        pending = true
        setProcessingUI()
        guard let input, input.mediaType == .image, !input.mediaSubtypes.contains(.photoLive), let source = input.fullSizeImageURL else {
            fail("Only full-size still photographs are supported. Download the photo from iCloud in Photos and try again.")
            return
        }
        let configuration: ServerConfiguration
        do {
            configuration = try Settings.savedConfiguration()
        } catch {
            fail(error.localizedDescription)
            return
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoServer-\(attempt.uuidString)", isDirectory: true)
        let prepared = work.appendingPathComponent("rendered.jpg")
        directory = work
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
                let client = GeminiClient(configuration: configuration)
                let models = try await client.availableModels()
                let model = models.contains(Settings.model) ? Settings.model : (Settings.preferredModel(from: models) ?? "")
                guard !model.isEmpty else { throw PhotoError.message("The server did not publish any usable Gemini models.") }
                try Settings.saveModel(model)
                processedModel = model
                let orientation = input.fullSizeImageOrientation
                let preparation = Task.detached(priority: .userInitiated) { try GeminiClient.makeRequestFile(image: source, orientation: orientation, model: model, directory: work) }
                let request = try await withTaskCancellationHandler(operation: { try await preparation.value }, onCancel: { preparation.cancel() })
                try Task.checkCancellation()
                setStatus("Uploading and processing…")
                let file = try await client.process(requestFile: request, directory: work)
                try Task.checkCancellation()
                guard generation == attempt else { return }
                setStatus("Preparing result…")
                try await Task.detached { try ImageFiles.prepareJPEG(from: file, to: prepared) }.value
                try Task.checkCancellation()
                let image = try await Task.detached { try ImageFiles.preview(prepared) }.value
                try Task.checkCancellation()
                let originalDimensions = try ImageFiles.orientedPixelDimensions(source, orientation: orientation)
                let outputDimensions = try ImageFiles.pixelDimensions(prepared)
                let needsChoice = outputDimensions.isSmallerThan(originalDimensions)
                guard generation == attempt else { return }
                result = prepared
                if needsChoice { resolutionConsent.presentWarning() }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == attempt else { return }
                    self.preview.image = image
                    self.pending = false
                    self.spinner.stopAnimating()
                    if needsChoice {
                        self.status.text = "The result is smaller in at least one dimension.\nGenerated: \(Self.dimensionLabel(outputDimensions))\nOriginal: \(Self.dimensionLabel(originalDimensions))\nChoose Apply anyway or Keep original."
                        self.applyAnyway.isHidden = false
                        self.keepOriginal.isHidden = false
                    } else {
                        self.status.text = "Ready. Tap Done to apply."
                    }
                }
                try? FileManager.default.removeItem(at: request)
                try? FileManager.default.removeItem(at: file)
            } catch {
                if generation == attempt && !Task.isCancelled {
                    Diagnostics.report(configuration: configuration, operation: "photo_edit", error: error)
                    fail(error.localizedDescription)
                }
            }
            if result != prepared {
                try? FileManager.default.removeItem(at: work)
            }
        }
    }

    private func fail(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pending = false
            self.spinner.stopAnimating()
            self.status.text = message
            self.retry.isHidden = false
        }
    }

    private func setStatus(_ value: String) {
        DispatchQueue.main.async { [weak self] in self?.status.text = value }
    }

    private func setProcessingUI() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.retry.isHidden = true
            self.applyAnyway.isHidden = true
            self.keepOriginal.isHidden = true
            self.spinner.startAnimating()
            self.status.text = "Preparing photograph…"
        }
    }
    func finishContentEditing(completionHandler: @escaping (PHContentEditingOutput?) -> Void) {
        let attempt = generation
        Task {
            await task?.value
            guard resolutionConsent.mayApply else {
                result = nil
                cleanup()
                completionHandler(nil)
                return
            }
            guard generation == attempt, let input, let result else { completionHandler(nil); return }
            do {
                let output = PHContentEditingOutput(contentEditingInput: input)
                let destination = output.renderedContentURL
                try await Task.detached { try FileManager.default.copyItem(at: result, to: destination) }.value
                ImageFiles.logDimensions("Photos renderedContentURL", at: destination)
                guard generation == attempt else { completionHandler(nil); return }
                let metadata = try JSONSerialization.data(withJSONObject: ["version": 1, "model": processedModel, "operation": "gemini-web"])
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

    private static func dimensionLabel(_ dimensions: ImageFiles.PixelDimensions) -> String {
        String(format: "%lld × %lld (%.2f MP)", dimensions.width, dimensions.height, dimensions.megapixels)
    }

    private func removeOrphanedWorkDirectories() {
        let temporary = FileManager.default.temporaryDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix("PhotoServer-") {
            try? FileManager.default.removeItem(at: entry)
        }
    }
}
