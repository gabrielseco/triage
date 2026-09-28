import Foundation
import TriageCore

/// Which API a pull request's actions go through.
extension AppStore {
    /// The client for `forge`, fetching `repos` on refresh. Throws when there's no token.
    func forgeClient(_ forge: Forge, repos: [RepoRef] = []) async throws -> any ForgeClient {
        switch forge {
        case .github:
            guard let token = await GitHubAuth.resolveToken() else { throw GitHubError.noToken }
            return GitHubForge(token: token, repos: repos)
        case .gitlab(let host):
            guard let token = cachedGitLabToken ?? GitLabAuth.token(host: host) else { throw GitLabError.noToken }
            cachedGitLabToken = token
            return GitLabForge(host: host, token: token)
        }
    }

    /// Saves a pasted token for the current host, or removes it when empty, and shows its merge requests.
    func saveGitLabToken(_ token: String) throws {
        try Keychain.set(token, for: gitlabHost, service: GitLabAuth.keychainService)
        cachedGitLabToken = nil
        gitlabViewer = nil
        Task { await refresh() }
    }
}
