import SwiftUI

@main
struct PhotoServerApp: App {
    var body: some Scene { WindowGroup { ConnectionView() } }
}

struct ConnectionView: View {
    static let loginInstructions = "Откроется одноразовая ссылка в окне Chrome на сервере. В открывшемся окне войдите в Google, затем закройте окно Chrome. Мы проверим вход автоматически."

    @Environment(\.openURL) private var openURL
    @State private var address = Settings.address
    @State private var apiKey = Settings.apiKey
    @State private var message = ""
    @State private var checking = false
    @State private var authState = "verifying"
    @State private var authMessage = ""
    @State private var startingLogin = false
    @State private var authPolling: Task<Void, Never>?
    var body: some View {
        NavigationStack {
            // Do not use Form here. On the iOS 27 beta a Form can be backed by a
            // UICollectionView list layout, which has caused scene-snapshot
            // watchdog terminations while this app is backgrounded by Photos.
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    section("From Apple Photos") {
                        Text("Open a photo → Edit → ⋯ → PhotoServer. Processing begins automatically. Review the result and tap Done, then finish editing in Photos.")
                        Text("The original stays available through Revert to Original. Photos are sent to the server you configure below.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    section("Server connection") {
                        TextField("https://photo.example.com", text: $address)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                            .textFieldStyle(.roundedBorder)
                        SecureField("PhotoServer API key", text: $apiKey)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.asciiCapable)
                            .textFieldStyle(.roundedBorder)
                        Button("Save and check connection") {
                            checking = true
                            Task {
                                defer { checking = false }
                                var configuration: ServerConfiguration?
                                do {
                                    configuration = try Settings.configuration(address: address, apiKey: apiKey)
                                    guard let configuration else { return }
                                    guard Settings.appGroupAvailable else {
                                        message = "This install cannot save credentials for the Photos extension. Re-sign both targets with an App Group profile."
                                        return
                                    }
                                    try Settings.save(configuration)
                                    let connected = try await GeminiClient(configuration: configuration).checkConnection()
                                    message = connected
                                    await refreshAuthStatus()
                                } catch {
                                    if let configuration {
                                        Diagnostics.report(configuration: configuration, operation: "connection_check", error: error)
                                        await refreshAuthStatus()
                                    }
                                    message = error.localizedDescription
                                }
                            }
                        }.disabled(checking)
                        if checking { ProgressView() }
                        if !message.isEmpty { Text(message).font(.footnote) }
                        Text("Use HTTPS for a remote server. HTTP is allowed only for localhost or an SSH tunnel. The API key is shared only by this app and its Photos extension through the App Group.")
                            .font(.footnote).foregroundStyle(.secondary)
                        if !Settings.appGroupAvailable {
                            Text("You can test the connection, but this build has no usable App Group. Re-sign both the app and extension with a profile that authorizes \(Settings.groupID) before Photos can receive its server credentials.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    section("Gemini") {
                        Text(authLabel).font(.subheadline)
                        Text(Self.loginInstructions).font(.footnote).foregroundStyle(.secondary)
                        if !authMessage.isEmpty { Text(authMessage).font(.footnote).foregroundStyle(.secondary) }
                        Button("Открыть ссылку для входа") { startLogin() }
                            .disabled(startingLogin)
                        Button("Проверить снова") { Task { await refreshAuthStatus(check: true) } }
                            .disabled(startingLogin)
                        if startingLogin { ProgressView() }
                    }
                }.padding(20)
            }.navigationTitle("PhotoServer")
        }.onAppear { Task { await refreshAuthStatus() } }
    }

    private var authLabel: String {
        switch authState {
        case "authenticated": return "Подключено"
        case "login_required": return "Требуется вход"
        case "login_in_progress": return "Ожидание входа"
        case "verifying": return "Проверка"
        case "network_error": return "Ошибка сети"
        default: return "Проверка"
        }
    }

    @MainActor
    private func refreshAuthStatus(check: Bool = false) async {
        do {
            let configuration = try Settings.configuration(address: address, apiKey: apiKey)
            let status = try await GeminiClient(configuration: configuration).authStatus(check: check)
            authState = status.status
            // The backend message is informational input from a remote server.
            // Keep the login UI copy local and never render server-provided markup.
            authMessage = ""
        } catch {
            authState = "network_error"
            authMessage = "Не удалось получить статус Gemini. Проверьте соединение и попробуйте снова."
        }
    }

    private func startLogin() {
        startingLogin = true
        Task { @MainActor in
            defer { startingLogin = false }
            do {
                let configuration = try Settings.configuration(address: address, apiKey: apiKey)
                let url = try await GeminiClient(configuration: configuration).createLoginSession()
                authState = "login_in_progress"
                authMessage = "Ожидаем завершения входа. После закрытия окна Chrome мы проверим его автоматически."
                if let url { openURL(url) }
                authPolling?.cancel()
                authPolling = Task { @MainActor in
                    for _ in 0..<200 {
                        try? await Task.sleep(for: .seconds(3))
                        if Task.isCancelled { return }
                        await refreshAuthStatus()
                        if authState == "authenticated" || authState == "login_required" { return }
                    }
                }
            } catch {
                authMessage = "Не удалось открыть ссылку. Проверьте соединение и попробуйте снова."
            }
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
