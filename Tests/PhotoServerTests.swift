import XCTest
import UIKit
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoServer

final class StubProtocol: URLProtocol {
    static var reply: (Int, Data) = (200, Data())
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (code, data) = Self.reply
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class PhotoServerTests: XCTestCase {
    var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    func png() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 32, height: 24)).pngData { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        }
    }
    func testInputBytesAreNotReencoded() throws {
        let data = png(), url = directory.appendingPathComponent("source.png")
        try data.write(to: url)
        let body = try GeminiClient.makeRequestFile(image: url, directory: directory)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: body)) as? [String: Any])
        let encoded = try XCTUnwrap(object["image"] as? String)
        XCTAssertEqual(Data(base64Encoded: String(encoded.split(separator: ",", maxSplits: 1)[1])), data)
        XCTAssertEqual(object["model"] as? String, "gemini-3.6-flash")
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
        XCTAssertNoThrow(try Settings.save("http://127.0.0.1:4981"))
        XCTAssertEqual(Settings.address, "http://127.0.0.1:4981")
        UserDefaults.standard.removeObject(forKey: "serverAddress")
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
        let client = GeminiClient(baseURL: URL(string: "https://unit.test")!, session: URLSession(configuration: config))
        let status = try await client.checkConnection()
        XCTAssertTrue(status.contains("Connected"))
        StubProtocol.reply = (429, Data("{\"error\":{\"message\":\"Quota exhausted\"}}".utf8))
        do { _ = try await client.checkConnection(); XCTFail("Should fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("429")) }
    }
}
