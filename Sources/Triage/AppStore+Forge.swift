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
        }
    }
}
