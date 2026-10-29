#if DEBUG
import APIClient
import Auth
import DesignSystem
import Domain
import Persistence
import SwiftUI

/// Developer settings (DESIGN.md v2 B5.11). Compiled only in Debug builds, so
/// it can't exist in Release. A system `Form` in its own `NavigationStack`,
/// sentence-case section headers, rows on the neutral `surface` step. Shows
/// whether a session token is stored, never its value.
struct DeveloperSettingsView: View {
    let services: AppServices

    @Environment(\.dismiss) private var dismiss
    @State private var urlText = ServerEnvironment.currentBaseURL().absoluteString
    @State private var validationError: String?
    @State private var connection: ConnectionResult?
    @State private var isTesting = false
    @State private var confirmsServerChange = false
    @State private var confirmsReset = false
    @State private var hasStoredToken = false
    @State private var toast: String?

    enum ConnectionResult: Equatable {
        case connected
        case failed(String)
    }

    private let presets: [(label: String, url: URL)] = [
        ("Simulator", ServerEnvironment.simulatorDefault),
        ("This Mac on the local network", ServerEnvironment.localNetworkDefault),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: Spacing.space2) {
                        Text("API base URL")
                            .textStyle(.subheadlineEmphasis)
                            .foregroundStyle(Palette.textPrimary)
                        TextField("http://localhost:8787/api", text: $urlText)
                            .textStyle(.body)
                            .foregroundStyle(Palette.textPrimary)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.URL)
                            .onChange(of: urlText) { _, _ in
                                validationError = nil
                                connection = nil
                            }
                        if let validationError {
                            Text(validationError)
                                .textStyle(.footnote)
                                .foregroundStyle(Palette.redText)
                        }
                    }
                    .listRowBackground(Palette.surface)
                    ForEach(presets, id: \.url) { preset in
                        Button {
                            urlText = preset.url.absoluteString
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(preset.label)
                                    .textStyle(.body)
                                    .foregroundStyle(Palette.textPrimary)
                                Text(preset.url.absoluteString)
                                    .textStyle(.subheadline)
                                    .foregroundStyle(Palette.textSecondary)
                            }
                        }
                        .listRowBackground(Palette.surface)
                    }
                    Button(isTesting ? "Testing\u{2026}" : "Test connection") {
                        Task { await testConnection() }
                    }
                    .disabled(isTesting)
                    .listRowBackground(Palette.surface)
                    if let connection {
                        Group {
                            switch connection {
                            case .connected:
                                Label("Connected", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(Palette.jadeText)
                            case .failed(let message):
                                Label(message, systemImage: "xmark.circle.fill")
                                    .foregroundStyle(Palette.redText)
                            }
                        }
                        .textStyle(.body)
                        .listRowBackground(Palette.surface)
                    }
                    Button("Save") { save() }
                        .listRowBackground(Palette.surface)
                        // Anchored to Save, so the iOS 26 popover points at it (A9.4).
                        .confirmationDialog("Change server? You'll be signed out.", isPresented: $confirmsServerChange, titleVisibility: .visible) {
                            Button("Change and sign out", role: .destructive) {
                                Task { await applyServerChange() }
                            }
                            Button("Cancel", role: .cancel) {}
                        }
                    Button("Reset to default") {
                        urlText = ServerEnvironment.defaultBaseURL.absoluteString
                        save(resettingToDefault: true)
                    }
                    .listRowBackground(Palette.surface)
                } header: {
                    Text("Server").textCase(nil)
                } footer: {
                    Text("Start the backend with scripts/dev-ios-backend.sh. On an iPhone, use this Mac's address on the same Wi-Fi.")
                }

                Section {
                    LabeledContent("Signed in", value: services.session.isSignedIn ? "Yes" : "No")
                        .listRowBackground(Palette.surface)
                    LabeledContent("Session token stored", value: hasStoredToken ? "Yes" : "No")
                        .listRowBackground(Palette.surface)
                    Button("Reset app data", role: .destructive) { confirmsReset = true }
                        .listRowBackground(Palette.surface)
                        // Anchored to the row, so the iOS 26 popover points at it (A9.4).
                        .confirmationDialog("Reset app data?", isPresented: $confirmsReset, titleVisibility: .visible) {
                            Button("Reset and sign out", role: .destructive) {
                                Task { await resetAppData() }
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("Signs out, deletes saved data on this device and resets app lock and Technical details.")
                        }
                } header: {
                    Text("Session").textCase(nil)
                }

                Section {
                    LabeledContent("Configuration", value: services.buildInfo.configuration)
                        .listRowBackground(Palette.surface)
                    LabeledContent("Bundle ID", value: services.buildInfo.bundleIdentifier)
                        .listRowBackground(Palette.surface)
                    LabeledContent("Version", value: services.buildInfo.displayVersion)
                        .listRowBackground(Palette.surface)
                } header: {
                    Text("Build").textCase(nil)
                }

                Section {
                    NavigationLink("Design specimen") {
                        DesignSpecimenView(services: services)
                    }
                    .accessibilityIdentifier("developer.designSpecimen")
                    .listRowBackground(Palette.surface)
                } header: {
                    Text("Design").textCase(nil)
                } footer: {
                    Text("Every DesignSystem component with specimen values, in this appearance.")
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Developer settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCloseButton { dismiss() }
                }
            }
            .toast($toast)
        }
        .sheetChrome([.large])
        .task { hasStoredToken = services.session.hasStoredToken() }
    }

    private func validatedURL() -> URL? {
        switch ServerEnvironment.validate(urlText) {
        case .success(let url):
            return url
        case .failure(let error):
            validationError = error.message
            return nil
        }
    }

    private func testConnection() async {
        guard let url = validatedURL() else { return }
        isTesting = true
        defer { isTesting = false }
        // A throwaway client for the typed URL: no token, nothing saved.
        let probe = APIClient(baseURL: url, clientInfo: .fromMainBundle())
        do throws(APIError) {
            let health = try await probe.send(API.Health.check())
            connection = health.status == "ok" ? .connected : .failed("The server answered but isn't healthy.")
        } catch {
            connection = .failed(error.message(for: .action))
        }
    }

    private func save(resettingToDefault: Bool = false) {
        guard let url = validatedURL() else { return }
        Task {
            let current = await services.api.currentBaseURL
            guard url != current else {
                if resettingToDefault { ServerEnvironment.clearOverride() }
                toast = "Saved."
                return
            }
            if services.session.isSignedIn {
                confirmsServerChange = true
            } else {
                await persist(url)
                toast = "Saved."
            }
        }
    }

    private func persist(_ url: URL) async {
        if url == ServerEnvironment.defaultBaseURL {
            ServerEnvironment.clearOverride()
        } else {
            ServerEnvironment.saveOverride(url)
        }
        await services.api.setBaseURL(url)
    }

    private func applyServerChange() async {
        guard let url = validatedURL() else { return }
        // Sign out against the old server first, then switch.
        await services.session.signOut(reason: .serverChanged)
        await persist(url)
        hasStoredToken = services.session.hasStoredToken()
        dismiss()
    }

    private func resetAppData() async {
        await services.session.signOut(reason: .userSignedOut)
        services.settings.reset()
        services.appLock.reset()
        PerUserKeys.removeAllStreakKeys(in: .standard)
        ServerEnvironment.clearOverride()
        await services.api.setBaseURL(ServerEnvironment.defaultBaseURL)
        urlText = ServerEnvironment.defaultBaseURL.absoluteString
        hasStoredToken = services.session.hasStoredToken()
        dismiss()
    }
}
#endif
