import XCTest
@testable import OpenUsage

/// CLIProxyAPI usage hubs: the account listing, the `api-call` tunnel the family clients ride through,
/// hub-only cards that never claim a local login's card, and the saved hub config.
@MainActor
final class UsageHubTests: XCTestCase {
    private nonisolated static let hub = UsageHubConfig(id: "cliproxy-hub.test", url: "http://hub.test:8317", managementKey: "management-secret")
    private nonisolated static let codexA = UsageHubAccount(
        id: "first.json", authIndex: "a", family: "codex", email: "first@example.com",
        identityKey: "account-a|first@example.com"
    )
    private nonisolated static let claudeB = UsageHubAccount(
        id: "claude.json", authIndex: "b", family: "claude", email: "claude@example.com",
        identityKey: "user-b|org-b"
    )
    /// The hub as a launch sees it: both accounts already listed, so Claude's identity is known.
    private nonisolated static var connectedHub: UsageHubConfig {
        var hub = Self.hub
        hub.accounts = [codexA, claudeB]
        return hub
    }

    private nonisolated static let listing = Data("""
    {"files": [
      {"id": "first.json", "auth_index": "a", "provider": "codex", "email": "First@Example.com",
       "id_token": {"chatgpt_account_id": "Account-A", "plan_type": "pro"}},
      {"id": "claude.json", "auth_index": "b", "provider": "claude", "email": "claude@example.com"},
      {"id": "off.json", "auth_index": "c", "provider": "codex", "disabled": true,
       "id_token": {"chatgpt_account_id": "account-c"}},
      {"id": "gemini.json", "auth_index": "d", "provider": "gemini"},
      {"id": "nameless.json", "auth_index": "e", "provider": "codex", "email": "x@example.com"}
    ]}
    """.utf8)

    /// A hub that answers the listing, and tunnels `api-call` to `upstream` keyed by credential + URL.
    private nonisolated static func makeHub(
        listing: Data = listing,
        upstream: @escaping @Sendable (_ authIndex: String, _ url: String, _ header: [String: String], _ data: String?) -> (Int, String)
    ) -> RoutingHTTPClient {
        RoutingHTTPClient { request in
            XCTAssertEqual(request.headers["Authorization"], "Bearer management-secret")
            switch request.url.path {
            case "/v0/management/auth-files":
                return HTTPResponse(statusCode: 200, headers: [:], body: listing)
            case "/v0/management/reset-quota":
                return HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))
            case "/v0/management/api-call":
                let call = try XCTUnwrap(ProviderParse.jsonObject(try XCTUnwrap(request.body)))
                let header = try XCTUnwrap(call["header"] as? [String: String])
                let (status, body) = upstream(
                    try XCTUnwrap(call["auth_index"] as? String), try XCTUnwrap(call["url"] as? String),
                    header, call["data"] as? String
                )
                let envelope = try JSONSerialization.data(withJSONObject: [
                    "status_code": status, "header": ["Content-Type": ["application/json"]], "body": body
                ])
                return HTTPResponse(statusCode: 200, headers: [:], body: envelope)
            default:
                XCTFail("unexpected request: \(request.url)")
                return HTTPResponse(statusCode: 500, headers: [:], body: Data())
            }
        }
    }

    private nonisolated static let claudeProfile = #"{"account":{"uuid":"User-B"},"organization":{"uuid":"Org-B","organization_type":"claude_max","rate_limit_tier":"default_claude_max_20x"}}"#

    // MARK: - Listing

    func testListingKeepsEnabledClaudeAndCodexAccountsWithIdentities() async throws {
        let http = Self.makeHub { _, url, _, _ in
            url.hasSuffix("/api/oauth/profile") ? (200, Self.claudeProfile) : (404, "{}")
        }
        let accounts = try await UsageHubClient(hub: Self.hub, http: http).listAccounts()

        XCTAssertEqual(accounts, [Self.codexA, Self.claudeB])
        // The Claude identity comes from the profile through the tunnel, with the hub's token placeholder.
        let profileCall = try XCTUnwrap(http.requests.last { $0.url.path == "/v0/management/api-call" })
        let call = try XCTUnwrap(ProviderParse.jsonObject(try XCTUnwrap(profileCall.body)))
        XCTAssertEqual(call["auth_index"] as? String, "b")
        XCTAssertEqual((call["header"] as? [String: String])?["Authorization"], "Bearer $TOKEN$")
    }

    func testListingReusesKnownClaudeIdentitiesWithoutProfileCalls() async throws {
        let http = Self.makeHub { _, _, _, _ in
            XCTFail("no tunnel call expected")
            return (500, "{}")
        }
        let accounts = try await UsageHubClient(hub: Self.hub, http: http)
            .listAccounts(known: ["claude.json": "user-b|org-b"])

        XCTAssertEqual(accounts.map(\.identityKey), ["account-a|first@example.com", "user-b|org-b"])
    }

    func testManagementFailuresMapToTypedErrors() async {
        let unauthorized = RoutingHTTPClient { _ in HTTPResponse(statusCode: 401, headers: [:], body: Data("{\"error\":\"nope\"}".utf8)) }
        do {
            _ = try await UsageHubClient(hub: Self.hub, http: unauthorized).listAccounts()
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? UsageHubError, .unauthorized)
        }

        let offline = RoutingHTTPClient { _ in throw URLError(.cannotConnectToHost) }
        do {
            _ = try await UsageHubClient(hub: Self.hub, http: offline).listAccounts()
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? UsageHubError, .connectionFailed)
        }

        var invalid = Self.hub
        invalid.url = "hub.test"
        do {
            _ = try await UsageHubClient(hub: invalid, http: unauthorized).listAccounts()
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? UsageHubError, .invalidURL)
        }
    }

    // MARK: - Cards

    func testCodexCardReadsUsageAndCreditsThroughTheHub() async throws {
        let http = Self.makeHub { authIndex, url, header, _ in
            XCTAssertEqual(authIndex, "a")
            XCTAssertEqual(header["Authorization"], "Bearer $TOKEN$")
            XCTAssertEqual(header["ChatGPT-Account-Id"], "account-a")
            if url == CodexUsageClient.resetCreditsURL.absoluteString {
                return (200, #"{"available_count": 2, "credits": [{"id": "c1", "status": "available", "expires_at": "2099-01-01T00:00:00Z"}]}"#)
            }
            XCTAssertEqual(url, CodexUsageClient.usageURL.absoluteString)
            return (200, #"{"plan_type": "pro", "rate_limit": {"primary_window": {"used_percent": 12, "limit_window_seconds": 18000}, "secondary_window": {"used_percent": 78, "limit_window_seconds": 604800}}}"#)
        }
        let listed = HubProbe()
        let provider = UsageHubProvider(
            cardID: "codex@ab12cd34",
            source: UsageHubAccountSource(hub: Self.connectedHub, account: Self.codexA),
            displayName: "Codex: first@example.com (hub.test)",
            http: http,
            onAccountsListed: { listed.listings.append($0) }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.providerID, "codex@ab12cd34")
        XCTAssertEqual(snapshot.plan, "Pro 20x")
        XCTAssertEqual(progress(snapshot.lines, "Session")?.used, 12)
        XCTAssertEqual(progress(snapshot.lines, "Weekly")?.used, 78)
        XCTAssertEqual(snapshot.line(label: "Rate Limit Resets").map { values($0) }?.first?.number, 2)
        XCTAssertEqual(listed.listings.count, 1)
        XCTAssertEqual(listed.listings.first?.map(\.id), ["first.json", "claude.json"])
        XCTAssertEqual(provider.widgetDescriptors.map(\.id), CodexProvider.limitDescriptors(provider: provider.provider).map(\.id))
        XCTAssertFalse(provider.widgetDescriptors.contains { $0.isSpendTile || $0.id.hasSuffix(".trend") })
    }

    func testClaudeCardReadsUsageAndLivePlanOnce() async throws {
        let http = Self.makeHub { authIndex, url, _, _ in
            XCTAssertEqual(authIndex, "b")
            if url.hasSuffix("/api/oauth/profile") { return (200, Self.claudeProfile) }
            XCTAssertEqual(url, "https://api.anthropic.com/api/oauth/usage")
            return (200, #"{"five_hour": {"utilization": 10, "resets_at": null}, "seven_day": {"utilization": 50, "resets_at": "2099-01-01T00:00:00Z"}}"#)
        }
        let provider = UsageHubProvider(
            cardID: "claude@ab12cd34",
            source: UsageHubAccountSource(hub: Self.connectedHub, account: Self.claudeB),
            displayName: "Claude: claude@example.com (hub.test)",
            http: http
        )

        let first = await provider.refresh()
        let second = await provider.refresh()

        XCTAssertEqual(first.plan, "Max 20x")
        XCTAssertEqual(second.plan, "Max 20x")
        XCTAssertEqual(progress(first.lines, "Session")?.used, 10)
        XCTAssertEqual(progress(second.lines, "Weekly")?.used, 50)
        let profileCalls = http.requests.filter { request in
            guard let body = request.body, let call = ProviderParse.jsonObject(body) else { return false }
            return (call["url"] as? String)?.hasSuffix("/api/oauth/profile") == true
        }
        XCTAssertEqual(profileCalls.count, 1)
    }

    func testCardFailsLoudlyWhenTheHubDropsTheAccountOrItsLoginExpired() async {
        let dropped = UsageHubProvider(
            cardID: "codex@1", source: UsageHubAccountSource(hub: Self.connectedHub, account: Self.codexA), displayName: "Codex",
            http: Self.makeHub(listing: Data(#"{"files": []}"#.utf8)) { _, _, _, _ in
                XCTFail("no usage fetch for a dropped account")
                return (500, "{}")
            }
        )
        let droppedSnapshot = await dropped.refresh()
        XCTAssertEqual(droppedSnapshot.errorCategory, .notAvailable)
        XCTAssertEqual(droppedSnapshot.lines.first?.badgeText, UsageHubError.accountUnavailable.localizedDescription)

        let expired = UsageHubProvider(
            cardID: "codex@1", source: UsageHubAccountSource(hub: Self.connectedHub, account: Self.codexA), displayName: "Codex",
            http: Self.makeHub { _, _, _, _ in (401, #"{"detail": "do-not-publish"}"#) }
        )
        let expiredSnapshot = await expired.refresh()
        XCTAssertEqual(expiredSnapshot.errorCategory, .authExpired)
        XCTAssertFalse(expiredSnapshot.lines.first?.badgeText?.contains("do-not-publish") ?? true)
    }

    func testResetClaimTravelsThroughTheHubTunnel() async throws {
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        let http = Self.makeHub { authIndex, url, header, data in
            XCTAssertEqual(authIndex, "a")
            if url == CodexUsageClient.resetCreditsURL.absoluteString {
                return (200, #"{"credits": [{"id": "credit-1", "status": "available", "expires_at": "\#(OpenUsageISO8601.string(from: expiry))"}]}"#)
            }
            XCTAssertEqual(url, CodexUsageClient.consumeResetCreditURL.absoluteString)
            XCTAssertEqual(header["Authorization"], "Bearer $TOKEN$")
            XCTAssertTrue(data?.contains(#""credit_id":"credit-1""#) == true)
            return (200, #"{"code": "reset"}"#)
        }
        let provider = UsageHubProvider(
            cardID: "codex@1", source: UsageHubAccountSource(hub: Self.hub, account: Self.codexA), displayName: "Codex", http: http
        )
        let refreshes = HubProbe()
        let service = try XCTUnwrap(provider.makeCodexResetClaimService(refreshAfterClaim: { refreshes.value += 1 }))

        let outcome = await service.claim(creditExpiringAt: expiry, redeemRequestID: UUID().uuidString)

        XCTAssertEqual(outcome, .success)
        XCTAssertEqual(refreshes.value, 1)
        // The hub's routing cooldown for this account is cleared once the credit is spent.
        let cooldown = try XCTUnwrap(http.requests.last { $0.url.path == "/v0/management/reset-quota" })
        XCTAssertEqual(ProviderParse.jsonObject(try XCTUnwrap(cooldown.body))?["auth_index"] as? String, "a")
    }

    // MARK: - Assembly

    func testHubOnlyAccountsMintCardsAndLocalLoginsWin() async throws {
        let defaults = try defaults()
        let store = ProviderAccountsStore(defaults: defaults)
        // The Mac is signed in to Codex account A (a default login names only its workspace).
        let files = FakeFiles([
            "/test/main/auth.json": CodexSwapAccountTests.credential(
                CodexAccountIdentity(accountID: "account-a", email: "first@example.com")!, token: "main-a"
            )
        ])
        let hub = Self.connectedHub
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment(["CODEX_HOME": "/test/main"]), files: files,
            keychain: FakeKeychain(), homeDirectory: { URL(fileURLWithPath: "/test") }
        )

        let assembly = await Self.assemble(observer: observer, store: store, hubs: [hub])

        // Codex A stays the local default card; only the Claude account becomes a hub card.
        XCTAssertEqual(assembly.identityKeysByCard["codex"], "account-a")
        XCTAssertEqual(assembly.hubCards.map(\.source.account.id), ["claude.json"])
        let claudeCard = try XCTUnwrap(assembly.hubCards.first)
        XCTAssertEqual(ProviderAccountID.family(of: claudeCard.id), "claude")
        XCTAssertNotEqual(claudeCard.id, "claude", "a hub-only account never takes the family's default card")
        XCTAssertEqual(assembly.identityKeysByCard[claudeCard.id], "user-b|org-b")
        XCTAssertEqual(claudeCard.source.displayName, "Claude: claude@example.com (hub.test)")

        // A hub account never counts as a second local login: the Mac's one Codex login keeps
        // owning its unattributed history (the multi-account exclusion is for local accounts).
        var withHubCodex = hub
        withHubCodex.accounts = [UsageHubAccount(
            id: "other.json", authIndex: "z", family: "codex", email: "other@example.com",
            identityKey: "account-z|other@example.com"
        )]
        let mixed = await Self.assemble(observer: observer, store: store, hubs: [withHubCodex])
        XCTAssertEqual(mixed.hubCards.map(\.source.account.id), ["other.json"])
        XCTAssertTrue(mixed.codexCards.isEmpty, "a hub account must not flip the local login into multi-account mode")
        let relaunched = await Self.assemble(observer: observer, store: store, hubs: [withHubCodex])
        XCTAssertTrue(relaunched.codexCards.isEmpty)
        XCTAssertEqual(relaunched.hubCards, mixed.hubCards)

        // The card id is stable across launches, and a later local Claude login still gets `claude`.
        let again = await Self.assemble(observer: observer, store: store, hubs: [hub])
        XCTAssertEqual(again.hubCards, assembly.hubCards)
        XCTAssertFalse(store.records.contains { $0.id == "claude" })
    }

    func testHubCardsFollowTheirFamilyAndInheritItsDefaults() throws {
        let claude = UsageHubAccountCard(id: "claude@11111111", source: UsageHubAccountSource(hub: Self.hub, account: Self.claudeB))
        let codex = UsageHubAccountCard(id: "codex@22222222", source: UsageHubAccountSource(hub: Self.hub, account: Self.codexA))

        let ids = ProviderCatalog.make(defaults: try defaults(), hubCards: [codex, claude]).map(\.provider.id)

        XCTAssertEqual(Array(ids.prefix(4)), ["claude", claude.id, "codex", codex.id])
        XCTAssertEqual(
            DefaultLayout.expandingAccounts(["claude.session", "codex.weekly"], providerIDs: ids),
            ["claude.session", "\(claude.id).session", "codex.weekly", "\(codex.id).weekly"]
        )
    }

    // MARK: - Store

    func testStorePersistsHubsAndAccountListings() throws {
        let files = FakeFiles()
        let store = UsageHubStore(files: files)
        XCTAssertTrue(store.hubs.isEmpty)

        try store.add(Self.hub)
        store.updateAccounts(hubID: Self.hub.id, [Self.codexA])
        XCTAssertEqual(UsageHubStore(files: files).hubs.first?.accounts, [Self.codexA])

        var rotated = Self.hub
        rotated.managementKey = "new-secret"
        try store.add(rotated)
        XCTAssertEqual(store.hubs.count, 1)
        XCTAssertEqual(store.hubs.first?.managementKey, "new-secret")

        try store.remove(id: Self.hub.id)
        XCTAssertTrue(UsageHubStore(files: files).hubs.isEmpty)
    }

    func testHubIDsAndLabelsFollowTheHost() {
        XCTAssertEqual(UsageHubConfig.makeID(url: "https://Hub.Example.ts.net:8318/"), "cliproxy-hub.example.ts.net-8318")
        XCTAssertEqual(UsageHubConfig.makeID(url: "not a url"), "cliproxy-not-a-url")
        XCTAssertEqual(
            UsageHubAccountSource(hub: Self.hub, account: UsageHubAccount(
                id: "x", authIndex: "x", family: "codex", email: nil, identityKey: "4ac8ad7b-636b|"
            )).displayName,
            "Codex: 4ac8ad7b (hub.test)"
        )
        XCTAssertEqual(Self.hub.displayLabel, "hub.test")
        var labeled = Self.hub
        labeled.label = "Office"
        XCTAssertEqual(labeled.displayLabel, "Office")
    }

    // MARK: - Helpers

    private static func assemble(
        observer: DefaultAccountObserver, store: ProviderAccountsStore, hubs: [UsageHubConfig]
    ) async -> ProviderAccountAssembly {
        let local = await ProviderAccountAssembly.make(observer: observer, accountsStore: store, families: ["codex"])
        return ProviderAccountAssembly.attachHubAccounts(to: local, hubs: hubs, accountsStore: store)
    }

    private func defaults() throws -> UserDefaults {
        let suite = "UsageHub.\(UUID().uuidString)"
        let value = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { value.removePersistentDomain(forName: suite) }
        return value
    }

    private func progress(_ lines: [MetricLine], _ label: String) -> (used: Double, limit: Double)? {
        for case .progress(let l, let used, let limit, _, _, _, _) in lines where l == label {
            return (used, limit)
        }
        return nil
    }

    private func values(_ line: MetricLine) -> [MetricValue] {
        if case .values(_, let values, _, _, _, _) = line { return values }
        return []
    }
}

private final class HubProbe: @unchecked Sendable {
    var value = 0
    var listings: [[UsageHubAccount]] = []
}

private extension MetricLine {
    var badgeText: String? {
        if case .badge(_, let text, _, _) = self { return text }
        return nil
    }
}
