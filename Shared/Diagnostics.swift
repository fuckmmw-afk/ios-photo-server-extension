import Foundation

enum Diagnostics {
    private static let maximumMessageLength = 400

    /// Sends an operational error to the configured PhotoServer on a best-effort
    /// basis. The payload deliberately excludes the source photograph, prompt,
    /// API key, request body, and response body.
    static func report(configuration: ServerConfiguration, operation: String, error: Error) {
        let event = Event(
            id: UUID().uuidString,
            occurredAt: ISO8601DateFormatter().string(from: Date()),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown",
            operation: operation,
            message: sanitized(error.localizedDescription),
            httpStatus: httpStatus(from: error)
        )

        Task.detached(priority: .utility) {
            guard let body = try? JSONEncoder().encode(event) else { return }
            var request = URLRequest(url: configuration.baseURL.appendingPathComponent("photoserver/v1/diagnostics"))
            request.httpMethod = "POST"
            request.timeoutInterval = 5
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(configuration.apiKey, forHTTPHeaderField: "X-PhotoServer-Key")
            request.httpBody = body
            let sessionConfiguration = URLSessionConfiguration.ephemeral
            sessionConfiguration.timeoutIntervalForRequest = 5
            sessionConfiguration.timeoutIntervalForResource = 5
            sessionConfiguration.urlCache = nil
            _ = try? await URLSession(configuration: sessionConfiguration).data(for: request)
        }
    }

    private static func sanitized(_ message: String) -> String {
        let singleLine = message.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        return String(singleLine.prefix(maximumMessageLength))
    }

    private static func httpStatus(from error: Error) -> Int? {
        let text = error.localizedDescription
        guard text.hasPrefix("HTTP ") else { return nil }
        let digits = text.dropFirst(5).prefix { $0.isNumber }
        return Int(digits)
    }

    private struct Event: Encodable {
        let id: String
        let occurredAt: String
        let appVersion: String
        let build: String
        let bundleIdentifier: String
        let operation: String
        let message: String
        let httpStatus: Int?
    }
}
