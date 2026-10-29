import Darwin
import Foundation

/// Reads host aliases out of `~/.ssh/config` so the editor can suggest them.
enum SSHConfig {
    /// Concrete `Host` aliases in `text`. Wildcard and negated patterns are skipped
    /// because they aren't something you can connect to.
    static func hosts(in text: String) -> [String] {
        directives(in: text, named: "host").flatMap { $0 }.filter {
            !$0.contains("*") && !$0.contains("?") && !$0.hasPrefix("!")
        }
    }

    /// Raw `Include` patterns in `text`, in order.
    static func includePatterns(in text: String) -> [String] {
        directives(in: text, named: "include").flatMap { $0 }
    }

    /// All aliases from `<home>/.ssh/config` and the files it includes, sorted and de-duplicated.
    static func loadHosts(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        let sshDir = home.appendingPathComponent(".ssh")
        var found = Set<String>()
        var visited = Set<String>()

        func read(_ path: String, depth: Int) {
            guard depth < 5, visited.insert(path).inserted,
                  let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
            found.formUnion(hosts(in: text))
            for pattern in includePatterns(in: text) {
                for included in expand(pattern, relativeTo: sshDir, home: home) { read(included, depth: depth + 1) }
            }
        }
        read(sshDir.appendingPathComponent("config").path, depth: 0)
        return found.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Argument lists for each line whose keyword is `name`. ssh accepts `Key value` and `Key=value`.
    private static func directives(in text: String, named name: String) -> [[String]] {
        text.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"),
                  let split = line.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }),
                  line[..<split].lowercased() == name else { return nil }
            let rest = line[line.index(after: split)...]
            return rest.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
                .filter { !$0.isEmpty }
        }
    }

    /// Expands `~`, resolves relative paths against ~/.ssh (as ssh does for user config), and globs.
    private static func expand(_ pattern: String, relativeTo sshDir: URL, home: URL) -> [String] {
        var path = pattern
        if path.hasPrefix("~/") { path = home.path + path.dropFirst(1) }
        if !path.hasPrefix("/") { path = sshDir.appendingPathComponent(path).path }

        var result = glob_t()
        defer { globfree(&result) }
        guard glob(path, 0, nil, &result) == 0 else { return [] }
        return (0..<Int(result.gl_pathc)).compactMap { result.gl_pathv[$0].map { String(cString: $0) } }
    }
}
