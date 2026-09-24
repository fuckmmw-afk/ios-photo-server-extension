import XCTest
import UIKit
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoServer

final class StubProtocol: URLProtocol {
    static var reply: (Int, Data) = (200, Data())
    static var headers: [String: String]?
    static var lastRequest: URLRequest?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        let (code, data) = Self.reply
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: Self.headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class PhotoServerTests: XCTestCase {
    var directory: URL!
    var defaults: UserDefaults!
    var defaultsSuite: String!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaultsSuite = "PhotoServerTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
        StubProtocol.headers = nil
    }
    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: defaultsSuite)
        StubProtocol.headers = nil
        try FileManager.default.removeItem(at: directory)
    }
    func png() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 32, height: 24)).pngData { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        }
    }
    func fixturePNG(size: CGSize) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor.blue.setFill(); context.fill(CGRect(origin: .zero, size: size))
        }
    }
    func jpeg(width: Int, height: Int) throws -> Data {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(UIColor.systemTeal.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let output = NSMutableData()
        let writer = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(writer, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        return output as Data
    }
    func testGeminiLoginInstructionsTellUserToUseWrapperButton() {
        XCTAssertEqual(
            ConnectionView.loginInstructions,
            "Откроется одноразовая ссылка в окне Chrome на сервере. Войдите в Google, затем нажмите в окне wrapper кнопку «Завершить вход и проверить». Сервер закроет Chrome и проверит вход."
        )
    }
    func testInputIsNormalizedAndBundledPromptIsSent() throws {
        let data = fixturePNG(size: CGSize(width: 32, height: 24)), url = directory.appendingPathComponent("source.png")
        try data.write(to: url)
        let body = try GeminiClient.makeRequestFile(image: url, orientation: 6, model: "gemini-3.8-flash", directory: directory)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: body)) as? [String: Any])
        let encoded = try XCTUnwrap(object["image"] as? String)
        let normalizedData = try XCTUnwrap(Data(base64Encoded: String(encoded.split(separator: ",", maxSplits: 1)[1])))
        XCTAssertTrue(encoded.hasPrefix("data:image/jpeg;base64,"))
        XCTAssertEqual(object["model"] as? String, "gemini-3.8-flash")
        XCTAssertEqual(object["input_orientation"] as? Int, 1)
        XCTAssertEqual(object["prompt"] as? String, Settings.prompt)
        XCTAssertTrue((object["prompt"] as? String)?.contains("Analyze the uploaded image first before generating the result.") == true)
        let normalized = directory.appendingPathComponent("normalized.jpg")
        try normalizedData.write(to: normalized)
        let source = try ImageFiles.source(normalized)
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual((props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1, 1)
        XCTAssertEqual((props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 24)
        XCTAssertEqual((props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, 32)
    }
    func testPortraitAndLandscapeSourcesNormalizeForAllEXIFOrientations() throws {
        for orientation in 1...8 {
            let portrait = orientation.isMultiple(of: 2)
            let size = portrait ? CGSize(width: 24, height: 32) : CGSize(width: 32, height: 24)
            let data = fixturePNG(size: size)
            let url = directory.appendingPathComponent("source-\(orientation).png")
            try data.write(to: url)
            let body = try GeminiClient.makeRequestFile(image: url, orientation: Int32(orientation), model: "gemini-test", directory: directory)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: body)) as? [String: Any])
            let encoded = try XCTUnwrap(object["image"] as? String)
            XCTAssertEqual(object["input_orientation"] as? Int, 1)
            let normalized = directory.appendingPathComponent("normalized-\(orientation).jpg")
            try XCTUnwrap(Data(base64Encoded: String(encoded.split(separator: ",", maxSplits: 1)[1]))).write(to: normalized)
            let source = try ImageFiles.source(normalized)
            let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            XCTAssertEqual((props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1, 1)
            let swapsDimensions = (5...8).contains(orientation)
            let width = Int(size.width), height = Int(size.height)
            XCTAssertEqual((props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, swapsDimensions ? height : width)
            XCTAssertEqual((props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, swapsDimensions ? width : height)
        }
    }
    func testPNGResultBecomesValidFullSizeJPEG() throws {
        let body = try JSONSerialization.data(withJSONObject: ["data": [["b64_json": png().base64EncodedString()]]])
        let result = try GeminiClient.decodeResult(body, directory: directory)
        let output = directory.appendingPathComponent("output.jpg")
        try ImageFiles.prepareJPEG(from: result, to: output)
        XCTAssertEqual(try ImageFiles.mime(output), "image/jpeg")
        let image = try XCTUnwrap(UIImage(contentsOfFile: output.path))
        XCTAssertEqual(image.size.width, 32 * UIScreen.main.scale)
        XCTAssertEqual(image.size.height, 24 * UIScreen.main.scale)
    }
    func testTwelveMegapixelUprightJPEGIsCopiedWithoutResizing() throws {
        let source = directory.appendingPathComponent("gemini-12mp.jpg")
        let output = directory.appendingPathComponent("photos-12mp.jpg")
        let original = try jpeg(width: 3024, height: 4032)
        try original.write(to: source)

        XCTAssertEqual(try ImageFiles.pixelDimensions(source).width, 3024)
        XCTAssertEqual(try ImageFiles.pixelDimensions(source).height, 4032)
        try ImageFiles.prepareJPEG(from: source, to: output)

        XCTAssertEqual(try ImageFiles.pixelDimensions(output).width, 3024)
        XCTAssertEqual(try ImageFiles.pixelDimensions(output).height, 4032)
        XCTAssertEqual(try Data(contentsOf: output), original, "An upright JPEG should pass through byte-for-byte.")
    }
    func testResolutionWarningComparesOrientedDimensionsAndRequiresAChoice() {
        let source = ImageFiles.PixelDimensions(width: 3024, height: 4032)
        XCTAssertTrue(ImageFiles.PixelDimensions(width: 896, height: 1195).isSmallerThan(source))
        XCTAssertTrue(ImageFiles.PixelDimensions(width: 3000, height: 4100).isSmallerThan(source), "A loss in either oriented dimension needs a warning.")
        XCTAssertFalse(ImageFiles.PixelDimensions(width: 4032, height: 3024).isSmallerThan(
            ImageFiles.PixelDimensions(width: 4032, height: 3024)))

        var consent = ResolutionConsent()
        XCTAssertTrue(consent.mayApply, "Full-size results do not need a confirmation step.")
        consent.presentWarning()
        XCTAssertTrue(consent.needsChoice)
        XCTAssertFalse(consent.mayApply, "Photos Done must not apply a smaller result before a choice.")
        consent.choose(.applyAnyway)
        XCTAssertTrue(consent.mayApply)

        consent = ResolutionConsent()
        consent.presentWarning()
        consent.choose(.keepOriginal)
        XCTAssertFalse(consent.mayApply)
        XCTAssertTrue(consent.keepsOriginal)
    }
    func testInvalidResultsAndURLAreRejected() throws {
        XCTAssertThrowsError(try GeminiClient.decodeResult(Data("{\"data\":[]}".utf8), directory: directory))
        XCTAssertThrowsError(try GeminiClient.decodeResult(Data("{\"data\":[{\"b64_json\":\"bm90LWltYWdl\"}]}".utf8), directory: directory))
        XCTAssertThrowsError(try Settings.validatedURL("http://example.com"))
        XCTAssertThrowsError(try Settings.validatedURL("https://user:password@example.com"))
        XCTAssertNoThrow(try Settings.validatedURL("http://localhost:4981"))
        XCTAssertNoThrow(try Settings.validatedURL("https://example.test"))
        XCTAssertThrowsError(try Settings.configuration(address: "https://unit.test", apiKey: ""))
        let saved = try Settings.configuration(address: "http://127.0.0.1:4981", apiKey: "unit-key-with-sufficient-entropy")
        XCTAssertNoThrow(try Settings.save(saved, in: defaults))
        XCTAssertEqual(defaults.string(forKey: Settings.serverAddressKey), "http://127.0.0.1:4981")
        XCTAssertEqual(defaults.string(forKey: Settings.serverAPIKeyKey), "unit-key-with-sufficient-entropy")
    }
    func testAllEXIFOrientationsAreBakedIntoPhotosOutput() throws {
        let image = try XCTUnwrap(UIImage(data: png())?.cgImage)
        for orientation in 1...8 {
            let input = directory.appendingPathComponent("input-\(orientation).jpg")
            let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(input as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(writer, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(writer))
            let output = directory.appendingPathComponent("upright-\(orientation).jpg")
            try ImageFiles.prepareJPEG(from: input, to: output)
            let source = try ImageFiles.source(output)
            let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            XCTAssertEqual((props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1, 1)
            let swapsDimensions = (5...8).contains(orientation)
            XCTAssertEqual((props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, swapsDimensions ? image.height : image.width)
            XCTAssertEqual((props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, swapsDimensions ? image.width : image.height)
        }
    }
    func testConnectionUsingURLProtocol() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        StubProtocol.reply = (200, Data("{\"data\":[{\"id\":\"gemini-3.5-flash-lite\"},{\"id\":\"gemini-3.8-flash\"},{\"id\":\"gemini-3.1-pro\"}]}".utf8))
        let client = GeminiClient(configuration: try Settings.configuration(address: "https://unit.test", apiKey: "unit-key-with-sufficient-entropy"), session: URLSession(configuration: config))
        let status = try await client.checkConnection()
        XCTAssertTrue(status.contains("Connected"))
        XCTAssertTrue(status.contains("gemini-3.8-flash"))
        let changed = try await client.checkConnection(model: "gemini-3.6-flash")
        XCTAssertTrue(changed.contains("gemini-3.8-flash"))
        XCTAssertEqual(StubProtocol.lastRequest?.value(forHTTPHeaderField: "X-PhotoServer-Key"), "unit-key-with-sufficient-entropy")
        StubProtocol.reply = (429, Data("{\"error\":{\"message\":\"Quota exhausted\"}}".utf8))
        do { _ = try await client.checkConnection(); XCTFail("Should fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("429")) }
    }

    func testDynamicModelFallbackUsesNewestFullFlashAndRequestCanChangeModel() throws {
        let current = ["gemini-3.5-flash-lite", "gemini-3.8-flash", "gemini-3.1-pro"]
        XCTAssertEqual(Settings.preferredModel(from: current), "gemini-3.8-flash")
        XCTAssertEqual(Settings.preferredModel(from: ["gemini-3.5-flash-lite", "gemini-3.1-pro"]), "gemini-3.5-flash-lite")
        XCTAssertNil(Settings.preferredModel(from: []))
        try Settings.saveModel("gemini-3.8-flash", in: defaults)
        XCTAssertEqual(defaults.string(forKey: Settings.modelKey), "gemini-3.8-flash")
    }

    func testGeminiAuth503IsSurfacedAsUnavailable() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        StubProtocol.reply = (503, Data("{\"error\":{\"message\":\"session unavailable\"}}".utf8))
        let client = GeminiClient(configuration: try Settings.configuration(address: "https://unit.test", apiKey: "unit-key-with-sufficient-entropy"), session: URLSession(configuration: config))
        do { _ = try await client.authStatus(check: true); XCTFail("Expected an unavailable response") }
        catch { XCTAssertTrue(error.localizedDescription.contains("HTTP 503")) }
        do { _ = try await client.availableModels(); XCTFail("Unavailable models must not trigger a stale-model fallback") }
        catch { XCTAssertTrue(error.localizedDescription.contains("HTTP 503")) }
    }

    func testGeminiAuthStatusAndOneTimeBrowserLink() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let client = GeminiClient(configuration: try Settings.configuration(address: "https://unit.test", apiKey: "unit-key-with-sufficient-entropy"), session: URLSession(configuration: config))
        StubProtocol.reply = (200, Data("{\"status\":\"login_required\",\"message\":\"Sign in\"}".utf8))
        let status = try await client.authStatus(check: true)
        XCTAssertEqual(status.status, "login_required")
        XCTAssertEqual(StubProtocol.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(StubProtocol.lastRequest?.url?.path, "/api/gemini/auth/check")
        StubProtocol.reply = (200, Data("{\"status\":\"login_in_progress\",\"url\":\"https://unit.test/gemini-login/start/opaque\"}".utf8))
        let url = try await client.createLoginSession()
        XCTAssertEqual(url?.path, "/gemini-login/start/opaque")
        XCTAssertEqual(StubProtocol.lastRequest?.value(forHTTPHeaderField: "X-PhotoServer-Key"), "unit-key-with-sufficient-entropy")
        StubProtocol.reply = (200, Data("{\"status\":\"login_in_progress\",\"url\":\"https://evil.test/gemini-login/start/opaque\"}".utf8))
        do { _ = try await client.createLoginSession(); XCTFail("Expected an invalid-link error") }
        catch { XCTAssertTrue(error.localizedDescription.contains("invalid Gemini login link")) }
    }

    func testProcessUsesProtectedBoundedResponseFileAndAPIKey() async throws {
        let request = directory.appendingPathComponent("request.json")
        try Data("{}".utf8).write(to: request)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        StubProtocol.reply = (200, try JSONSerialization.data(withJSONObject: ["data": [["b64_json": png().base64EncodedString()]]]))
        let client = GeminiClient(configuration: try Settings.configuration(address: "https://unit.test", apiKey: "unit-key-with-sufficient-entropy"), session: URLSession(configuration: config))
        let result = try await client.process(requestFile: request, directory: directory)
        XCTAssertEqual(try ImageFiles.mime(result), "image/png")
        XCTAssertEqual(StubProtocol.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(StubProtocol.lastRequest?.value(forHTTPHeaderField: "X-PhotoServer-Key"), "unit-key-with-sufficient-entropy")

        StubProtocol.headers = ["Content-Length": String(GeminiClient.maximumResponseBytes + 1)]
        do { _ = try await client.process(requestFile: request, directory: directory); XCTFail("Expected an error") }
        catch { XCTAssertTrue(error.localizedDescription.contains("safety limit")) }
    }
}
