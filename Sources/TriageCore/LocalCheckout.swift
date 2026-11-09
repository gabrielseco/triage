import Foundation

/// Finds the local clone of a repo, which `workbench explain-pr` runs in.
public enum LocalCheckout {
    /// Finds a local clone of `repo` by looking for `<root>/<name>` whose origin points at it.
    public static func find(_ repo: RepoRef, roots: [String]) async -> String? {
        for root in roots {
            let path = (root as NSString).appendingPathComponent(repo.name)
            guard FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".git")),
                let origin = await git(["-C", path, "remote", "get-url", "origin"]),
                originMatches(origin, repo)
            else { continue }
            return path
        }
        return nil
    }

    public static func originMatches(_ origin: String, _ repo: RepoRef) -> Bool {
        let o = origin.lowercased().replacingOccurrences(of: ".git", with: "")
        return o.hasSuffix(":" + repo.fullName.lowercased()) || o.hasSuffix("/" + repo.fullName.lowercased())
    }

    static func git(_ args: [String]) async -> String? {
        guard let out = try? await Subprocess.run("/usr/bin/git", args), out.status == 0 else { return nil }
        return out.trimmedStdout
    }
}
