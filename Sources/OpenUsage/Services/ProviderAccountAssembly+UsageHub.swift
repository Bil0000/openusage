import Foundation

struct UsageHubAccountCard: Equatable, Sendable {
    let id: String
    let source: UsageHubAccountSource
}

extension ProviderAccountAssembly {
    /// Turns the accounts each connected hub last listed into cards, after the local pass: an account
    /// this Mac is signed in to keeps its local card (the hub adds nothing a local login lacks), so a
    /// hub card only ever appears for an account with no local login. Card ids mint like any later
    /// account (`family@<hash8>`) and persist in the registry, so they survive relaunches and hub edits.
    static func attachHubAccounts(
        to assembly: ProviderAccountAssembly,
        hubs: [UsageHubConfig],
        accountsStore: ProviderAccountsStore
    ) -> ProviderAccountAssembly {
        var observations: [ProviderAccountsStore.Observation] = []
        var sources: [String: UsageHubAccountSource] = [:]
        for hub in hubs {
            for account in hub.accounts {
                let local = assembly.identityKeysByCard.first { cardID, identityKey in
                    ProviderAccountID.family(of: cardID) == account.family
                        && sameAccount(identityKey, account.identityKey)
                }
                if let local {
                    AppLog.info(.config, "accounts: hub \(hub.id) \(account.family) account is signed in locally (\(local.key)); using the local login")
                    continue
                }
                let key = "\(account.family)|\(account.identityKey)"
                // The same account on two hubs reads through the first hub listed.
                guard sources[key] == nil else { continue }
                sources[key] = UsageHubAccountSource(hub: hub, account: account)
                observations.append(ProviderAccountsStore.Observation(
                    family: account.family, identityKey: account.identityKey, label: account.email,
                    sources: [ProviderAccountSource(kind: .usageHub, anchor: hub.id, holdsDefaultSource: false)]
                ))
            }
        }
        guard !observations.isEmpty else { return assembly }
        AppLog.info(.config, "accounts: \(observations.count) hub-only accounts across \(hubs.count) hubs")

        var result = assembly
        let records = accountsStore.reconcile(with: observations)
        for observation in observations {
            guard let record = records.first(where: {
                $0.family == observation.family && $0.identityKey == observation.identityKey && !$0.removedTombstone
            }), let source = sources["\(observation.family)|\(observation.identityKey)"] else { continue }
            result.hubCards.append(UsageHubAccountCard(id: record.id, source: source))
            result.identityKeysByCard[record.id] = observation.identityKey
        }
        return result
    }

    /// A local identity can be partial (a default Codex login names only its workspace, a Claude login
    /// only its account), in which case it names the hub's account when it is that key's first component.
    private static func sameAccount(_ local: String, _ hub: String) -> Bool {
        local == hub || (!local.contains("|") && hub.hasPrefix(local + "|"))
    }
}
