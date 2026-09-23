import Foundation

enum Settings {
    static let modelKey = "geminiModel"
    static let serverAddressKey = "serverAddress"
    static let serverAPIKeyKey = "serverAPIKey"
    // Replace this instruction in a later iteration; no prompt editor in the extension.
    static let prompt = "Process the attached photograph while preserving its subjects, faces and composition. Return the resulting photograph as an image, not a text description."
    static var groupID: String { Bundle.main.object(forInfoDictionaryKey: "PhotoServerAppGroup") as? String ?? "group.64bb0d6b088653aa.3" }
    static var appGroupAvailable: Bool {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) != nil
    }
    static func sharedDefaults() throws -> UserDefaults {
        guard appGroupAvailable, let suite = UserDefaults(suiteName: groupID) else {
            throw PhotoError.message("App Group is unavailable. Install a build signed with the configured App Group before using the Photos extension.")
        }
        return suite
    }
    static var address: String { (try? sharedDefaults())?.string(forKey: serverAddressKey) ?? "" }
    static var apiKey: String { (try? sharedDefaults())?.string(forKey: serverAPIKeyKey) ?? "" }
    static var model: String { (try? sharedDefaults())?.string(forKey: modelKey) ?? "" }

    static func saveModel(_ model: String, in defaults: UserDefaults? = nil) throws {
        let storage: UserDefaults
        if let defaults { storage = defaults } else { storage = try sharedDefaults() }
        storage.set(model, forKey: modelKey)
        storage.synchronize()
    }

    static func preferredModel(from available: [String]) -> String? {
        let unique = Array(Set(available)).sorted()
        func version(_ id: String) -> [Int] {
            let suffix = id.split(separator: "-").dropFirst().first ?? ""
            return suffix.split(separator: ".").compactMap { Int($0) }
        }
        return unique.sorted { lhs, rhs in
            let lhsFlash = lhs.localizedCaseInsensitiveContains("flash")
            let rhsFlash = rhs.localizedCaseInsensitiveContains("flash")
            let lhsLite = lhs.localizedCaseInsensitiveContains("lite")
            let rhsLite = rhs.localizedCaseInsensitiveContains("lite")
            let lhsPreferred = lhsFlash && !lhsLite
            let rhsPreferred = rhsFlash && !rhsLite
            if lhsPreferred != rhsPreferred { return lhsPreferred }
            if lhsFlash != rhsFlash { return lhsFlash }
            let lv = version(lhs), rv = version(rhs)
            if lv != rv { return lv.lexicographicallyPrecedes(rv) == false }
            return lhs < rhs
        }.first
    }

    static func validatedURL(_ address: String) throws -> URL {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else {
            throw PhotoError.message("Use HTTPS or a local SSH tunnel: http://localhost:4981")
        }
        return url
    }
    static func validatedAPIKey(_ value: String) throws -> String {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.count >= 24, !key.contains(where: { $0.isNewline || $0.isWhitespace }) else {
            throw PhotoError.message("Enter the 24+ character API key configured on your PhotoServer.")
        }
        return key
    }
    static func configuration(address: String, apiKey: String) throws -> ServerConfiguration {
        let url = try validatedURL(address)
        return ServerConfiguration(baseURL: url, apiKey: try validatedAPIKey(apiKey))
    }
    static func savedConfiguration() throws -> ServerConfiguration {
        try configuration(address: address, apiKey: apiKey)
    }
    static func save(_ configuration: ServerConfiguration, in defaults: UserDefaults? = nil) throws {
        let storage: UserDefaults
        if let defaults {
            storage = defaults
        } else {
            storage = try sharedDefaults()
        }
        storage.set(configuration.baseURL.absoluteString, forKey: serverAddressKey)
        storage.set(configuration.apiKey, forKey: serverAPIKeyKey)
        storage.synchronize()
    }
}

struct ServerConfiguration: Equatable {
    let baseURL: URL
    let apiKey: String
}

enum PhotoError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(message) = self { return message }; return nil }
}
