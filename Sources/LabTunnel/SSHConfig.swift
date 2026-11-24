import Darwin
import Foundation

/// Reads host aliases out of `~/.ssh/config` so the editor can suggest them.
enum SSHConfig {
    private struct FileStamp: Equatable {
        let sec: Int
        let nsec: Int
        let size: off_t
        let inode: ino_t

        static func of(path: String) -> FileStamp? {
            var st = stat()
            guard stat(path, &st) == 0 else { return nil }
            return FileStamp(
                sec: st.st_mtimespec.tv_sec,
                nsec: st.st_mtimespec.tv_nsec,
                size: st.st_size,
                inode: st.st_ino
            )
        }
    }

    private struct CachedEntry {
        let hosts: [String]
        let stamps: [String: FileStamp?]
    }

    private static let cacheLock = NSLock()
    private static nonisolated(unsafe) var cache: [String: CachedEntry] = [:]

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
        parseHosts(home: home).hosts
    }

    /// Cached variant of `loadHosts(home:)` that checks mtimes of `<home>/.ssh/config`,
    /// visited included files, and watched directories before re-parsing.
    static func loadHostsCached(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        let key = home.standardizedFileURL.path
        let cached = cacheLock.withLock { cache[key] }
        if let cached, isFresh(cached) {
            return cached.hosts
        }

        let parsed = parseHosts(home: home)
        var stamps: [String: FileStamp?] = [:]
        for path in parsed.watchedPaths {
            stamps[path] = FileStamp.of(path: path)
        }
        let entry = CachedEntry(hosts: parsed.hosts, stamps: stamps)
        cacheLock.withLock { cache[key] = entry }
        return parsed.hosts
    }

    private static func isFresh(_ entry: CachedEntry) -> Bool {
        for (path, previous) in entry.stamps {
            if FileStamp.of(path: path) != previous {
                return false
            }
        }
        return true
    }

    private static func parseHosts(home: URL) -> (hosts: [String], watchedPaths: Set<String>) {
        let sshDir = home.appendingPathComponent(".ssh")
        let rootConfig = URL(fileURLWithPath: sshDir.appendingPathComponent("config").path).standardizedFileURL.path
        var found = Set<String>()
        var visited = Set<String>()
        var watched: Set<String> = [
            URL(fileURLWithPath: sshDir.path).standardizedFileURL.path,
            rootConfig,
        ]

        func read(_ path: String, depth: Int) {
            let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
            watched.insert(normalized)
            watched.insert(URL(fileURLWithPath: normalized).deletingLastPathComponent().standardizedFileURL.path)
            guard depth < 5, visited.insert(normalized).inserted,
                  let text = try? String(contentsOfFile: normalized, encoding: .utf8) else { return }
            found.formUnion(hosts(in: text))
            for pattern in includePatterns(in: text) {
                let expanded = expand(pattern, relativeTo: sshDir, home: home)
                if let baseDir = watchDirectory(for: pattern, relativeTo: sshDir, home: home) {
                    watched.insert(baseDir)
                }
                for included in expanded {
                    read(included, depth: depth + 1)
                }
            }
        }

        read(rootConfig, depth: 0)
        let sorted = found.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return (sorted, watched)
    }

    /// Argument lists for each line whose keyword is `name`. ssh accepts `Key value` and `Key=value`.
    private static func directives(in text: String, named name: String) -> [[String]] {
        text.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"),
                  let split = line.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }),
                  line[..<split].lowercased() == name else { return nil }
            var rest = line[line.index(after: split)...]
            if line[split] != "=" {
                while let first = rest.first, first == " " || first == "\t" {
                    rest = rest.dropFirst()
                }
                if rest.first == "=" {
                    rest = rest.dropFirst()
                }
            }
            return tokenizeValues(rest)
        }
    }

    /// Splits a directive's value string on unquoted spaces/tabs, keeping `"..."` quoted segments
    /// and literal `=` characters intact.
    private static func tokenizeValues(_ slice: Substring) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        var index = slice.startIndex

        while index < slice.endIndex {
            let ch = slice[index]
            if ch == "\"" {
                inQuotes.toggle()
            } else if (ch == " " || ch == "\t") && !inQuotes {
                if !current.isEmpty {
                    tokens.append(current)
                    current.removeAll(keepingCapacity: true)
                }
            } else {
                current.append(ch)
            }
            index = slice.index(after: index)
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private static func resolvePattern(_ pattern: String, relativeTo sshDir: URL, home: URL) -> String {
        var path = pattern
        if path == "~" {
            path = home.path
        } else if path.hasPrefix("~/") {
            path = home.path + path.dropFirst(1)
        }
        if !path.hasPrefix("/") && !path.hasPrefix("~") {
            path = sshDir.appendingPathComponent(path).path
        }
        return path
    }

    private static func watchDirectory(for pattern: String, relativeTo sshDir: URL, home: URL) -> String? {
        let resolved = resolvePattern(pattern, relativeTo: sshDir, home: home)
        if resolved.hasPrefix("~") { return nil }
        let prefix = resolved.prefix(while: { $0 != "*" && $0 != "?" && $0 != "[" })
        let url = URL(fileURLWithPath: String(prefix)).standardizedFileURL
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return url.path
        }
        return url.deletingLastPathComponent().path
    }

    /// Expands `~`, resolves relative paths against ~/.ssh (as ssh does for user config), and globs.
    private static func expand(_ pattern: String, relativeTo sshDir: URL, home: URL) -> [String] {
        let path = resolvePattern(pattern, relativeTo: sshDir, home: home)
        var result = glob_t()
        defer { globfree(&result) }
        guard glob(path, GLOB_TILDE, nil, &result) == 0 else { return [] }
        return (0..<Int(result.gl_pathc)).compactMap { result.gl_pathv[$0].map { String(cString: $0) } }
    }
}
