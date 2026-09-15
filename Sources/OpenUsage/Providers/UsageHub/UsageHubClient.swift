import Foundation

enum UsageHubError: Error, LocalizedError, Equatable {
    case invalidURL
    case connectionFailed
    /// The hub rejected the management key (401/403 from a management endpoint).
    case unauthorized
    case managementFailed(Int)
    case invalidResponse
    /// The account is no longer listed by the hub, or the hub disabled it.
    case accountUnavailable
    /// The provider rejected the hub's token for this account (401/403 through `api-call`).
    case accountAuthExpired

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The hub URL is not valid. Use http(s)://host[:port]."
        case .connectionFailed:
            return "Hub request failed. Check the hub URL and your connection."
        case .unauthorized:
            return "The hub rejected the management key."
        case .managementFailed(let statusCode):
            return "Hub request failed (HTTP \(statusCode)). Try again later."
        case .invalidResponse:
            return "Hub response invalid. Try again later."
        case .accountUnavailable:
            return "This account is no longer available on the hub."
        case .accountAuthExpired:
            return "The hub's login for this account expired. Sign in again on the hub."
        }
    }
}

/// CLIProxyAPI's management API for one hub: the account listing, and a tunnel that sends any provider
/// request through `api-call` with the account's own token substituted for `$TOKEN$`. The Codex and
/// Claude usage clients, mappers, and the reset-credit claim then work unchanged against a hub account.
struct UsageHubClient: Sendable {
    /// The bearer value `api-call` replaces with the selected credential's access token.
    static let tokenPlaceholder = "$TOKEN$"

    let hub: UsageHubConfig
    var http: any HTTPClient

    init(hub: UsageHubConfig, http: any HTTPClient = URLSessionHTTPClient()) {
        self.hub = hub
        self.http = http
    }

    /// The hub's enabled Claude and Codex accounts. Identity keys come from the id_token claims the
    /// listing already exposes (Codex) or the account's live profile (Claude); `known` maps credential
    /// ids to identities resolved earlier, so relisting on every refresh never re-reads a profile.
    func listAccounts(known: [String: String] = [:]) async throws -> [UsageHubAccount] {
        let response = try await management("auth-files")
        guard let body = ProviderParse.jsonObject(response.body),
              let files = body["files"] as? [[String: Any]]
        else {
            throw UsageHubError.invalidResponse
        }
        var accounts: [UsageHubAccount] = []
        for file in files {
            guard let id = (file["id"] as? String)?.nilIfEmpty,
                  let authIndex = (file["auth_index"] as? String)?.nilIfEmpty,
                  let family = file["provider"] as? String, family == "claude" || family == "codex",
                  file["disabled"] as? Bool != true
            else { continue }
            let email = (file["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty?.lowercased()
            let identityKey: String
            if family == "codex" {
                let claims = file["id_token"] as? [String: Any]
                guard let identity = CodexAccountIdentity(accountID: claims?["chatgpt_account_id"] as? String, email: email),
                      !identity.accountID.isEmpty
                else {
                    AppLog.warn(LogTag.plugin("usagehub"), "hub Codex credential \(authIndex) names no workspace; skipping it")
                    continue
                }
                identityKey = identity.key
            } else if let cached = known[id] {
                identityKey = cached
            } else {
                do {
                    identityKey = try await claudeIdentityKey(authIndex: authIndex)
                } catch {
                    AppLog.warn(LogTag.plugin("usagehub"), "hub Claude credential \(authIndex) has no readable profile; skipping it: \(error.localizedDescription)")
                    continue
                }
            }
            accounts.append(UsageHubAccount(id: id, authIndex: authIndex, family: family, email: email, identityKey: identityKey))
        }
        return accounts
    }

    /// Claude's identity is org-scoped (`<account>|<organization>`, see `DefaultAccountObserver`), and the
    /// listing carries only the email, so the account's own profile names it.
    private func claudeIdentityKey(authIndex: String) async throws -> String {
        let client = ClaudeUsageClient(httpClient: tunnel(authIndex: authIndex))
        let response = try await client.fetchProfile(
            accessToken: Self.tokenPlaceholder, config: ClaudeAuthStore.productionOAuthConfig
        )
        let profile = try ClaudeUsageClient.decodeProfile(response)
        guard let organization = profile.organization?.uuid.nilIfEmpty else { throw UsageHubError.invalidResponse }
        return "\(profile.account.uuid)|\(organization)".lowercased()
    }

    func tunnel(authIndex: String) -> Tunnel {
        Tunnel(client: self, authIndex: authIndex)
    }

    /// `GET`/`POST /v0/management/<path>` with the management key. A 401/403 is the key being rejected;
    /// any other non-2xx is a hub failure. Transport failures never carry the hub's error body.
    func management(_ path: String, body: Data? = nil) async throws -> HTTPResponse {
        guard let base = URL(string: hub.url), base.host != nil,
              ["http", "https"].contains(base.scheme?.lowercased()),
              let url = URL(string: "/v0/management/\(path)", relativeTo: base)?.absoluteURL
        else {
            throw UsageHubError.invalidURL
        }
        var request = HTTPRequest(
            method: body == nil ? "GET" : "POST",
            url: url,
            headers: ["Authorization": "Bearer \(hub.managementKey)", "Accept": "application/json"],
            body: body,
            timeout: 15
        )
        if body != nil {
            request.headers["Content-Type"] = "application/json"
        }
        let response: HTTPResponse
        do {
            response = try await http.send(request)
        } catch {
            throw UsageHubError.connectionFailed
        }
        if ProviderAuthRetry.isAuthFailure(response) {
            throw UsageHubError.unauthorized
        }
        guard (200..<300).contains(response.statusCode) else {
            throw UsageHubError.managementFailed(response.statusCode)
        }
        return response
    }

    /// An `HTTPClient` whose every request travels through the hub's `api-call` for one credential.
    /// Callers pass `tokenPlaceholder` as the access token; the hub substitutes the real one. The
    /// upstream status, headers, and body come back as a normal `HTTPResponse`, so a provider's own
    /// status handling (401 → auth expired, 429 → rate limited) applies unchanged.
    struct Tunnel: HTTPClient {
        let client: UsageHubClient
        let authIndex: String

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            let call = APICall(
                auth_index: authIndex,
                method: request.method,
                url: request.url.absoluteString,
                header: request.headers,
                data: request.body.map { String(decoding: $0, as: UTF8.self) }
            )
            let response = try await client.management("api-call", body: try JSONEncoder().encode(call))
            guard let body = ProviderParse.jsonObject(response.body),
                  let status = ProviderParse.number(body["status_code"]),
                  let text = body["body"] as? String
            else {
                throw UsageHubError.invalidResponse
            }
            let raw = body["header"] as? [String: [String]] ?? [:]
            let headers = raw.reduce(into: [String: String]()) { $0[$1.key.lowercased()] = $1.value.first }
            return HTTPResponse(statusCode: Int(status), headers: headers, body: Data(text.utf8))
        }

        private struct APICall: Encodable {
            var auth_index: String
            var method: String
            var url: String
            var header: [String: String]
            var data: String?
        }
    }
}
