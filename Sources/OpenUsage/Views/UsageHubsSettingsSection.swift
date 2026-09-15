import SwiftUI

/// Settings ▸ Usage Hubs: the CLIProxyAPI hubs whose pooled Claude and Codex accounts show as cards.
/// One row per connected hub with a Remove button (behind a confirmation, since it deletes the saved
/// management key), and an Add Hub button that opens an inline editor — hub URL, management key, and
/// an optional label — in the same recessed block the API Key editor uses. Connecting lists the hub's
/// accounts right away so a bad URL or key fails here, not on a card after relaunch.
struct UsageHubsSettingsSection: View {
    let hubs: UsageHubStore
    @AppStorage(DensitySetting.key) private var density = DensitySetting.regular

    @State private var isAdding = false
    @State private var url = ""
    @State private var managementKey = ""
    @State private var label = ""
    @State private var isConnecting = false
    @State private var actionError: String?
    @State private var pendingRemoval: UsageHubConfig?
    /// Connected or removed this session: cards follow on the next launch, and the row says so.
    @State private var needsRelaunch = false

    var body: some View {
        VStack(alignment: .leading, spacing: density.headerToCardSpacing) {
            Text("Usage Hubs")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            VStack(spacing: 0) {
                Text("Shows the limits of every Claude and Codex account a CLIProxyAPI hub pools, as cards next to your own logins. The management key stays on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, density.controlRowPadding)
                    .padding(.bottom, hubs.hubs.isEmpty ? density.controlRowPadding : 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(hubs.hubs, id: \.id) { hub in
                    hubRow(hub)
                }
                if needsRelaunch {
                    inlineNotice("Restart OpenUsage to update the hub cards on the dashboard.")
                }
                if let actionError, !isAdding {
                    inlineNotice(actionError)
                }
                Divider()
                if isAdding {
                    editorBlock
                } else {
                    Button {
                        resetEditor()
                        isAdding = true
                    } label: {
                        Text("Add Hub…").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .padding(.horizontal, 12)
                    .padding(.vertical, density.controlRowPadding)
                }
            }
            .cardSurface()
            .clipShape(Theme.cardShape)
        }
        .alert("Remove \(pendingRemoval?.displayLabel ?? "Hub")?", isPresented: Binding(
            get: { pendingRemoval != nil },
            set: { if !$0 { pendingRemoval = nil } }
        )) {
            Button("Remove", role: .destructive) {
                if let hub = pendingRemoval { remove(hub) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The hub's management key is deleted from this Mac and its account cards go away on the next launch. The hub itself is untouched.")
        }
    }

    private func hubRow(_ hub: UsageHubConfig) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(hub.displayLabel)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(hubSubtitle(hub))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button("Remove") { pendingRemoval = hub }
                .buttonStyle(.borderless)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, density.controlRowPadding)
    }

    private func inlineNotice(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Theme.notice)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hubSubtitle(_ hub: UsageHubConfig) -> String {
        let count = hub.accounts.count
        return "\(count) \(count == 1 ? "account" : "accounts") · \(hub.url)"
    }

    private var editorBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Hub URL", text: $url, prompt: Text("http://127.0.0.1:8317"))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            SecureField("Management Key", text: $managementKey, prompt: Text("Management Key"))
                .textFieldStyle(.roundedBorder)
            TextField("Label", text: $label, prompt: Text("Label (Optional)"))
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                Button("Connect") { connect() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!canConnect || isConnecting)
                Button("Cancel") { isAdding = false }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(isConnecting)
                if isConnecting {
                    MotionAwareProgressView(controlSize: .small)
                        .accessibilityLabel("Connecting to the hub")
                }
            }
            if let actionError {
                Text(actionError)
                    .font(.caption)
                    .foregroundStyle(Theme.notice)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Rectangle().fill(.fill.quinary))
    }

    private var canConnect: Bool {
        !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !managementKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func resetEditor() {
        url = ""
        managementKey = ""
        label = ""
        actionError = nil
    }

    /// Lists the hub's accounts before saving, so the row only ever appears for a hub that answered.
    private func connect() {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let hub = UsageHubConfig(
            id: UsageHubConfig.makeID(url: trimmedURL),
            label: label.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            url: trimmedURL,
            managementKey: managementKey.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        isConnecting = true
        actionError = nil
        Task {
            defer { isConnecting = false }
            do {
                var connected = hub
                connected.accounts = try await UsageHubClient(hub: hub).listAccounts()
                try hubs.add(connected)
                isAdding = false
                needsRelaunch = true
                AppLog.info(.config, "usage hub \(hub.id) connected with \(connected.accounts.count) accounts")
            } catch {
                actionError = error.localizedDescription
                AppLog.error(.config, "usage hub connect failed for \(hub.id): \(error.localizedDescription)")
            }
        }
    }

    private func remove(_ hub: UsageHubConfig) {
        do {
            try hubs.remove(id: hub.id)
            needsRelaunch = true
        } catch {
            actionError = error.localizedDescription
            AppLog.error(.config, "usage hub remove failed for \(hub.id): \(error.localizedDescription)")
        }
    }
}
