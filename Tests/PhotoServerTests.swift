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
    func testInputBytesAreNotReencoded() throws {
        let data = png(), url = directory.appendingPathComponent("source.png")
        try data.write(to: url)
        let body = try GeminiClient.makeRequestFile(image: url, orientation: 6, directory: directory)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: body)) as? [String: Any])
        let encoded = try XCTUnwrap(object["image"] as? String)
        XCTAssertEqual(Data(base64Encoded: String(encoded.split(separator: ",", maxSplits: 1)[1])), data)
        XCTAssertEqual(object["model"] as? String, "gemini-3.6-flash")
        XCTAssertEqual(object["input_orientation"] as? Int, 6)
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
    func testExifRotationIsBakedIntoPhotosOutput() throws {
        let input = directory.appendingPathComponent("rotated.jpg")
        let writer = try XCTUnwrap(CGImageDestinationCreateWithURL(input as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        let image = try XCTUnwrap(UIImage(data: png())?.cgImage)
        CGImageDestinationAddImage(writer, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(writer))
        let output = directory.appendingPathComponent("upright.jpg")
        try ImageFiles.prepareJPEG(from: input, to: output)
        let source = try ImageFiles.source(output)
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual((props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1, 1)
        XCTAssertEqual((props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, image.height)
        XCTAssertEqual((props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, image.width)
    }
    func testConnectionUsingURLProtocol() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        StubProtocol.reply = (200, Data("{\"data\":[{\"id\":\"gemini-3.6-flash\"}]}".utf8))
        let client = GeminiClient(configuration: try Settings.configuration(address: "https://unit.test", apiKey: "unit-key-with-sufficient-entropy"), session: URLSession(configuration: config))
        let status = try await client.checkConnection()
        XCTAssertTrue(status.contains("Connected"))
        XCTAssertEqual(StubProtocol.lastRequest?.value(forHTTPHeaderField: "X-PhotoServer-Key"), "unit-key-with-sufficient-entropy")
        StubProtocol.reply = (429, Data("{\"error\":{\"message\":\"Quota exhausted\"}}".utf8))
        do { _ = try await client.checkConnection(); XCTFail("Should fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("429")) }
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
