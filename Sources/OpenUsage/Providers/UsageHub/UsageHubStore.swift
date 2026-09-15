import Foundation
import Observation

/// One CLIProxyAPI hub the user connected: where it is and the management key that unlocks its
/// account list. Mirrors T3 Code's usage-limit source config. The key lives with the other
/// user-supplied secrets in `~/.config/openusage/` (owner-only file), never in UserDefaults.
struct UsageHubConfig: Codable, Equatable, Sendable {
    var id: String
    var label: String?
    var url: String
    var managementKey: String
    /// The Claude and Codex accounts the hub listed the last time it was reached (on connect and on
    /// every card refresh). Read at launch so the cards exist without a network call.
    var accounts: [UsageHubAccount] = []

    /// The label, else the hub's host — what the Settings row and the account cards show.
    var displayLabel: String {
        label?.nilIfEmpty ?? URL(string: url)?.host ?? url
    }

    /// `cliproxy-<host>` like T3 Code: dots and dashes in the host survive so `foo-bar.com` and
    /// `foo.bar.com` do not collide; the port's colon and anything else fold to a dash. An unparseable
    /// URL keeps its raw text; connecting rejects it before the id is ever saved.
    static func makeID(url: String) -> String {
        var host = url
        if let parsed = URL(string: url), let name = parsed.host {
            host = parsed.port.map { "\(name):\($0)" } ?? name
        }
        let slug = host.lowercased()
            .replacingOccurrences(of: "[^a-z0-9.-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "cliproxy-\(slug)"
    }
}

/// One account a hub pools, as the hub's `auth-files` listing names it. `identityKey` follows the
/// family's local convention (`<workspace>|<email>` for Codex, `<account>|<organization>` for Claude)
/// so a hub account that is also signed in on this Mac reconciles to the same card.
struct UsageHubAccount: Codable, Equatable, Sendable {
    /// The hub's credential id (its auth file name), stable across listings.
    var id: String
    /// The hub's credential index, which `api-call` uses to pick the token.
    var authIndex: String
    var family: String
    var email: String?
    var identityKey: String

    /// The ChatGPT workspace for the `ChatGPT-Account-Id` header, from the Codex identity key.
    var codexAccountID: String? {
        guard family == "codex" else { return nil }
        return identityKey.split(separator: "|", omittingEmptySubsequences: false).first.map(String.init)?.nilIfEmpty
    }
}

/// A hub-held account with no local login this launch: its card fetches through the hub instead of
/// a local credential. Attached to the family's account card by `ProviderAccountAssembly`.
struct UsageHubAccountSource: Equatable, Sendable {
    let hub: UsageHubConfig
    let account: UsageHubAccount

    var displayName: String {
        let family = account.family == "codex" ? "Codex" : "Claude"
        return "\(family): \(account.email ?? String(account.identityKey.prefix(8))) (\(hub.displayLabel))"
    }
}

/// The connected hubs (`~/.config/openusage/usage-hubs.json`). Written by the Settings card when a hub
/// is added or removed and by a hub card's refresh when the hub's account list changed; read once at
/// launch by `ProviderAccountAssembly` to build the hub account cards.
@MainActor
@Observable
final class UsageHubStore {
    static let configPath = "~/.config/openusage/usage-hubs.json"

    private(set) var hubs: [UsageHubConfig]
    private let files: TextFileAccessing

    init(files: TextFileAccessing = LocalTextFileAccessor()) {
        self.files = files
        do {
            if let text = try files.readTextIfPresent(Self.configPath) {
                self.hubs = try JSONDecoder().decode(File.self, from: Data(text.utf8)).hubs
            } else {
                self.hubs = []
            }
        } catch {
            AppLog.error(.config, "usage hub config was unreadable; starting with no hubs: \(error.localizedDescription)")
            self.hubs = []
        }
    }

    /// Adds a hub, replacing an existing entry with the same id (re-adding a hub rotates its key).
    func add(_ hub: UsageHubConfig) throws {
        try persist(hubs.filter { $0.id != hub.id } + [hub])
    }

    func remove(id: String) throws {
        try persist(hubs.filter { $0.id != id })
    }

    /// Records a hub's latest account list so the next launch builds cards for accounts added to the
    /// hub since. A failed write is logged, not thrown — the refresh that listed the accounts still
    /// has its usage to show.
    func updateAccounts(hubID: String, _ accounts: [UsageHubAccount]) {
        guard let index = hubs.firstIndex(where: { $0.id == hubID }), hubs[index].accounts != accounts else { return }
        var updated = hubs
        updated[index].accounts = accounts
        do {
            try persist(updated)
        } catch {
            AppLog.error(.config, "usage hub account list could not be saved: \(error.localizedDescription)")
        }
    }

    private func persist(_ updated: [UsageHubConfig]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(File(hubs: updated))
        try files.writeText(Self.configPath, String(decoding: data, as: UTF8.self))
        hubs = updated
    }

    private struct File: Codable {
        var hubs: [UsageHubConfig]
    }
}
