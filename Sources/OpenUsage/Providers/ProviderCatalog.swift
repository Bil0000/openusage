import Foundation

/// The installed provider set and its canonical order. Both the menu-bar app and one-shot CLI build
/// their runtimes here so credentials, refresh behavior, pricing, and normalization can never drift.
@MainActor
enum ProviderCatalog {
    static func make(
        defaults: UserDefaults = .standard,
        claudeCards: [ClaudeAccountCard] = [],
        codexCards: [CodexAccountCard] = [],
        claudeIdentityKeys: [String: String] = [:],
        hubCards: [UsageHubAccountCard] = [],
        onHubAccountsListed: @escaping @MainActor (String, [UsageHubAccount]) -> Void = { _, _ in }
    ) -> [ProviderRuntime] {
        // Default provider order (see AGENTS.md "## Providers"): the three established providers first,
        // then every other provider alphabetically by display name. Hub-held accounts follow their
        // family's local cards.
        func hubProviders(family: String) -> [ProviderRuntime] {
            hubCards.filter { $0.source.account.family == family }.map { card in
                UsageHubProvider(
                    cardID: card.id, source: card.source, displayName: card.source.displayName,
                    onAccountsListed: { onHubAccountsListed(card.source.hub.id, $0) }
                )
            }
        }
        var providers: [ProviderRuntime]
        if claudeCards.isEmpty {
            providers = [ClaudeProvider()]
        } else {
            providers = claudeCards.map { card in
                let identity = claudeIdentityKeys[card.id] ?? card.identityKey
                let user = identity.split(separator: "|").first.map(String.init)
                let scanner = ClaudeLogUsageScanner(
                    accountUUID: user, organizationUUID: card.organizationID,
                    allowsUnattributedSessions: card.allowsUnattributedPiUsage,
                    additionalConfigDirectories: card.additionalLogDirectories
                )
                return ClaudeProvider(
                    provider: ClaudeProvider.makeProvider(
                        id: card.id,
                        displayName: claudeCards.count == 1 ? "Claude" : card.displayName
                    ),
                    authStore: ClaudeAuthStore(
                        desktopOrganization: card.organizationID,
                        expectedIdentityKey: identity,
                        desktopOnly: card.usesDesktopCredentials,
                        swapAccount: card.swapAccount,
                        preferOrganizationScopedDesktop: claudeCards.count > 1
                            && card.organizationID != nil && !card.usesDesktopCredentials
                    ),
                    logUsageScanner: scanner,
                    allowsUnattributedPiUsage: card.allowsUnattributedPiUsage
                )
            }
        }
        providers += hubProviders(family: "claude")
        if codexCards.isEmpty {
            providers.append(CodexProvider())
        } else {
            providers += codexCards.map { card in
                CodexProvider(
                    provider: CodexProvider.makeProvider(id: card.id, displayName: card.displayName),
                    authStore: CodexAuthStore(expectedIdentity: card.identity, additionalAuthHomes: card.authHomes),
                    logUsageScanner: CodexLogUsageScanner(
                        allowsUnattributedHistory: card.allowsUnattributedHistory,
                        additionalHomes: card.logHomes
                    ),
                    allowsUnattributedHistory: card.allowsUnattributedHistory
                )
            }
        }
        providers += hubProviders(family: "codex")
        providers += [
            CursorProvider(),
            AntigravityProvider(),
            CopilotProvider(defaults: defaults),
            DevinProvider(),
            GrokProvider(),
            OllamaProvider(),
            OpenCodeProvider(),
            OpenRouterProvider(),
            ZAIProvider()
        ]
        return providers
    }
}
