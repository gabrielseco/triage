import Foundation
import TriageCore

/// Which API a pull request's actions go through.
extension AppStore {
    /// Who you are on `forge`: "Mine", whose comments are new, what you can approve.
    func viewer(for forge: Forge) -> String? {
        switch forge {
        case .github: viewer
        case .gitlab: gitlabViewer
        }
    }

    /// Whether Triage can do `capability` for this PR yet; views hide what it can't.
    func can(_ capability: ForgeCapabilities, _ pr: PullRequest) -> Bool {
        pr.repo.forge.capabilities.contains(capability)
    }

    /// GitLab projects with an open merge request for you, for the sidebar. They come from the fetch rather
    /// than a list you keep.
    var gitlabProjects: [RepoRef] {
        Set(prs.map(\.repo).filter { $0.forge != .github }).sorted { $0.fullName < $1.fullName }
    }

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
