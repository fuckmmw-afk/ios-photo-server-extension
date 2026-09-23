import SwiftUI

@main
struct PhotoServerApp: App {
    var body: some Scene { WindowGroup { ConnectionView() } }
}

struct ConnectionView: View {
    static let loginInstructions = "Откроется одноразовая ссылка в окне Chrome на сервере. Войдите в Google, затем нажмите в окне wrapper кнопку «Завершить вход и проверить». Сервер закроет Chrome и проверит вход."

    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var address = Settings.address
    @State private var apiKey = Settings.apiKey
    @State private var message = ""
    @State private var checking = false
    @State private var authState = "verifying"
    @State private var authMessage = ""
    @State private var startingLogin = false
    @State private var availableModels: [String] = []
    @State private var selectedModel = Settings.model
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
                            .disabled(checking)
                        SecureField("PhotoServer API key", text: $apiKey)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.asciiCapable)
                            .textFieldStyle(.roundedBorder)
                            .disabled(checking)
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
                                    let models = try await GeminiClient(configuration: configuration).availableModels()
                                    availableModels = models.sorted()
                                    if !models.contains(selectedModel) {
                                        selectedModel = Settings.preferredModel(from: models) ?? ""
                                    }
                                    guard !selectedModel.isEmpty else { throw PhotoError.message("The server did not publish any usable models.") }
                                    try Settings.saveModel(selectedModel)
                                    message = "Connected · \(selectedModel)"
                                    authState = "authenticated"
                                    authMessage = ""
                                } catch {
                                    if let configuration {
                                        Diagnostics.report(configuration: configuration, operation: "connection_check", error: error)
                                        if Self.isUnavailable(error) {
                                            authState = "server_unavailable"
                                            authMessage = "Сервер Gemini временно недоступен. Повторите проверку позже."
                                        } else {
                                            await refreshAuthStatus(check: true)
                                        }
                                    }
                                    message = error.localizedDescription
                                }
                            }
                        }.disabled(checking)
                        if checking { ProgressView() }
                        if !message.isEmpty { Text(message).font(.footnote) }
                        if !availableModels.isEmpty {
                            Picker("Gemini model", selection: $selectedModel) {
                                ForEach(availableModels, id: \.self) { Text($0).tag($0) }
                            }
                            .onChange(of: selectedModel) { _, value in
                                guard availableModels.contains(value) else { return }
                                try? Settings.saveModel(value)
                            }
                        }
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
        }
        .onAppear {
            Task {
                await refreshAuthStatus(check: true)
                if authState == "login_in_progress" || authState == "server_unavailable" { startAuthPolling() }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                authPolling?.cancel()
                authPolling = nil
            } else if phase == .active {
                Task {
                    await refreshAuthStatus(check: true)
                    if authState == "login_in_progress" || authState == "server_unavailable" { startAuthPolling() }
                }
            }
        }
        .onChange(of: address) { _, _ in invalidateServerState() }
        .onChange(of: apiKey) { _, _ in invalidateServerState() }
    }

    private var authLabel: String {
        switch authState {
        case "authenticated": return "Подключено"
        case "login_required": return "Требуется вход"
        case "login_in_progress": return "Ожидание входа"
        case "verifying": return "Проверка"
        case "network_error": return "Ошибка сети"
        case "server_unavailable": return "Сервер временно недоступен"
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
            if Self.isUnavailable(error) {
                authState = "server_unavailable"
                authMessage = "Сервер Gemini временно недоступен. Повторите проверку позже."
            } else {
                authState = "network_error"
                authMessage = "Не удалось получить статус Gemini. Проверьте соединение и попробуйте снова."
            }
        }
    }

    private static func isUnavailable(_ error: Error) -> Bool {
        error.localizedDescription.contains("HTTP 503")
    }

    private func invalidateServerState() {
        authPolling?.cancel()
        authPolling = nil
        availableModels = []
        selectedModel = ""
        authState = "verifying"
        authMessage = ""
        message = ""
    }

    private func startLogin() {
        startingLogin = true
        Task { @MainActor in
            defer { startingLogin = false }
            do {
                let configuration = try Settings.configuration(address: address, apiKey: apiKey)
                let url = try await GeminiClient(configuration: configuration).createLoginSession()
                authState = "login_in_progress"
                authMessage = "После входа в Google нажмите в окне wrapper кнопку «Завершить вход и проверить». Сервер закроет Chrome и проверит вход."
                if let url { openURL(url) }
                startAuthPolling()
            } catch {
                authMessage = "Не удалось открыть ссылку. Проверьте соединение и попробуйте снова."
            }
        }
    }

    private func startAuthPolling() {
        authPolling?.cancel()
        authPolling = Task { @MainActor in
            for _ in 0..<200 {
                if Task.isCancelled { return }
                try? await Task.sleep(for: .seconds(3))
                if Task.isCancelled { return }
                await refreshAuthStatus(check: true)
                if authState == "authenticated" || authState == "login_required" { return }
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
