import Foundation

/// GitLab's write actions, over REST. They need a token with the `api` scope; watching needs only `read_api`.
extension GitLabClient {
    /// Approves as the viewer, only if the source branch is still at `sha`, so the approval is for the commit
    /// that was seen (GitLab answers 409 otherwise).
    public func approve(_ pr: PullRequest) async throws {
        do {
            _ = try await send(try approveRequest(pr))
        } catch GitLabError.http(401, _) {
            // On this endpoint 401 means "not allowed to approve", not a bad token: that would have failed the
            // refresh already.
            throw GitLabError.cannotApprove
        }
    }

    func approveRequest(_ pr: PullRequest) throws -> URLRequest {
        var req = try restRequest("projects/\(Self.projectID(pr.repo))/merge_requests/\(pr.number)/approve")
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["sha": pr.headSha])
        return req
    }

    /// Merges, squashing for `.squash`, only if the source branch is still at `pr.headSha`: a push after you
    /// looked is refused (409). GitLab's merge checks apply; a failing one comes back as its message.
    public func merge(_ pr: PullRequest, method: MergeMethod) async throws {
        do {
            _ = try await send(try acceptRequest(pr, method: method))
        } catch GitLabError.http(401, _) {
            // As with approve: the token was fine for the refresh, so this is "not allowed to merge".
            throw GitLabError.cannotMerge
        }
    }

    /// GitLab calls merging "accepting" the merge request.
    func acceptRequest(_ pr: PullRequest, method: MergeMethod) throws -> URLRequest {
        var req = try restRequest("projects/\(Self.projectID(pr.repo))/merge_requests/\(pr.number)/merge")
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "sha": pr.headSha, "squash": method == .squash,
        ])
        return req
    }

    /// REST takes a project's full path as its id, with the slashes encoded.
    static func projectID(_ repo: RepoRef) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return repo.fullName.addingPercentEncoding(withAllowedCharacters: allowed) ?? repo.fullName
    }

    func restRequest(_ path: String) throws -> URLRequest {
        // `path` is already percent-encoded, so it's appended as text, not through appendingPathComponent.
        guard let url = URL(string: "https://\(host)/api/v4/\(path)") else { throw GitLabError.graphql("bad host") }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 30
        return req
    }

    func send(_ req: URLRequest) async throws -> Data {
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw GitLabError.http(code, String(decoding: data, as: UTF8.self)) }
        return data
    }
}
