import Foundation

/// One hub-held Claude or Codex account, refreshed through its CLIProxyAPI hub. The card reuses the
/// family's usage client and mapper through `UsageHubClient.Tunnel`, so the meters read exactly like a
/// local login's; only the trend and spend rows are absent (the session logs stay on the hub).
///
/// Each refresh relists the hub's accounts first: that is how an account added to the hub later reaches
/// the store (and a card on the next launch), and how a credential the hub removed or disabled fails
/// loudly instead of fetching with a dead index.
@MainActor
final class UsageHubProvider: ProviderRuntime {
    let provider: Provider
    let source: UsageHubAccountSource
    let client: UsageHubClient
    /// Every provider request for this card travels through the hub with the account's own token.
    let tunnel: UsageHubClient.Tunnel
    private let onAccountsListed: @MainActor ([UsageHubAccount]) -> Void

    /// The plan Anthropic's profile reports for a Claude account, kept once it resolves so the hub is
    /// not a second poll of the profile endpoint (the restraint `ClaudeProvider` applies per token).
    private var claudePlan: String?
    /// Credential id → identity, seeded from the hub's saved listing and grown by each relisting, so a
    /// Claude account added to the hub later has its profile read once per card, not once per refresh.
    private var knownIdentities: [String: String]

    init(
        cardID: String,
        source: UsageHubAccountSource,
        displayName: String,
        http: any HTTPClient = URLSessionHTTPClient(),
        onAccountsListed: @escaping @MainActor ([UsageHubAccount]) -> Void = { _ in }
    ) {
        self.provider = source.account.family == "codex"
            ? CodexProvider.makeProvider(id: cardID, displayName: displayName)
            : ClaudeProvider.makeProvider(id: cardID, displayName: displayName)
        self.source = source
        let client = UsageHubClient(hub: source.hub, http: http)
        self.client = client
        self.tunnel = client.tunnel(authIndex: source.account.authIndex)
        self.onAccountsListed = onAccountsListed
        self.knownIdentities = Dictionary(
            source.hub.accounts.map { ($0.id, $0.identityKey) }, uniquingKeysWith: { first, _ in first }
        )
    }

    var account: UsageHubAccount { source.account }

    var widgetDescriptors: [WidgetDescriptor] {
        account.family == "codex"
            ? CodexProvider.limitDescriptors(provider: provider)
            : ClaudeProvider.limitDescriptors(provider: provider)
    }

    /// The card exists only because the hub's management key is saved on this Mac — that is its
    /// credential, and probing it never touches the network.
    func hasLocalCredentials() async -> Bool {
        true
    }

    func refresh() async -> ProviderSnapshot {
        do {
            let accounts = try await client.listAccounts(known: knownIdentities)
            for listed in accounts { knownIdentities[listed.id] = listed.identityKey }
            onAccountsListed(accounts)
            guard accounts.contains(where: { $0.id == account.id }) else {
                throw UsageHubError.accountUnavailable
            }
            let (plan, lines) = if account.family == "codex" { try await refreshCodex() } else { try await refreshClaude() }
            return ProviderSnapshot.make(provider: provider, plan: plan, lines: lines, refreshedAt: Date())
        } catch {
            return ProviderSnapshot.error(provider: provider, error: error)
        }
    }

    /// The resets popover's claim service for a Codex hub account: the same claim flow as a local
    /// login, tunneled through the hub. `nil` for Claude accounts.
    ///
    /// A hub stops routing to an account it saw rate-limited until its own cooldown expires, and a
    /// reset redeemed through `api-call` does not tell it otherwise — so after a claim the cooldown is
    /// cleared (`reset-quota`), best-effort: the credit is spent and the meters refresh either way.
    func makeCodexResetClaimService(refreshAfterClaim: @escaping () async -> Void) -> CodexResetClaimService? {
        guard account.family == "codex" else { return nil }
        let candidates: [CodexResetClaimService.Credentials] = [(UsageHubClient.tokenPlaceholder, account.codexAccountID)]
        let hubClient = client
        let authIndex = account.authIndex
        return CodexResetClaimService(
            usageClient: CodexUsageClient(http: tunnel),
            credentialCandidates: { candidates },
            refreshAfterClaim: {
                do {
                    _ = try await hubClient.management(
                        "reset-quota", body: try JSONEncoder().encode(["auth_index": authIndex])
                    )
                } catch {
                    AppLog.warn(LogTag.plugin("usagehub"), "hub cooldown could not be cleared after the reset claim; routing resumes when it expires: \(error.localizedDescription)")
                }
                await refreshAfterClaim()
            }
        )
    }

    private func refreshCodex() async throws -> (plan: String?, lines: [MetricLine]) {
        let codexUsageClient = CodexUsageClient(http: tunnel)
        let response = try await codexUsageClient.fetchUsage(
            accessToken: UsageHubClient.tokenPlaceholder, accountID: account.codexAccountID
        )
        guard !ProviderAuthRetry.isAuthFailure(response) else { throw UsageHubError.accountAuthExpired }
        // Supplementary, like `CodexProvider`: a failed credit fetch falls back to the usage body's count.
        let resetCredits = try? await codexUsageClient.fetchResetCredits(
            accessToken: UsageHubClient.tokenPlaceholder, accountID: account.codexAccountID
        )
        let mapped = try CodexUsageMapper.mapUsageResponse(response, resetCredits: resetCredits)
        var lines = mapped.lines
        MetricLine.appendNoDataIfNeeded(&lines)
        return (mapped.plan, lines)
    }

    private func refreshClaude() async throws -> (plan: String?, lines: [MetricLine]) {
        let claudeUsageClient = ClaudeUsageClient(httpClient: tunnel)
        let config = ClaudeAuthStore.productionOAuthConfig
        let response = try await claudeUsageClient.fetchUsage(accessToken: UsageHubClient.tokenPlaceholder, config: config)
        guard !ProviderAuthRetry.isAuthFailure(response) else { throw UsageHubError.accountAuthExpired }
        // The hub's listing carries no plan; the stored-login fields the mapper formats are empty here.
        var mapped = try ClaudeUsageMapper.mapUsageResponse(response, credentials: ClaudeOAuth())
        if claudePlan == nil {
            do {
                let profile = try ClaudeUsageClient.decodeProfile(
                    try await claudeUsageClient.fetchProfile(accessToken: UsageHubClient.tokenPlaceholder, config: config)
                )
                claudePlan = ClaudeUsageMapper.formatLivePlan(profile: profile, credentials: ClaudeOAuth())
            } catch {
                AppLog.warn(LogTag.plugin("usagehub"), "live plan lookup failed; retrying next refresh: \(error.localizedDescription)")
            }
        }
        mapped.plan = claudePlan
        MetricLine.appendNoDataIfNeeded(&mapped.lines)
        return (mapped.plan, mapped.lines)
    }
}
