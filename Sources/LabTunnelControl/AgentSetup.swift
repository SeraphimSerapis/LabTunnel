import Foundation

/// Makes the CLI and the agent skill available to the current user.
///
/// - `~/.local/bin/labtunnel` becomes a symlink to the helper inside the app bundle.
/// - `~/.agents/skills/labtunnel/SKILL.md` becomes a copy of the skill shipped in the bundle.
public enum AgentSetup {
    public struct Installed: Equatable {
        public let cliLink: URL
        public let skillFile: URL
    }

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
        init(_ description: String) { self.description = description }
    }

    public static func helperURL(in appBundle: URL) -> URL {
        appBundle.appendingPathComponent("Contents/Helpers/labtunnel")
    }

    public static func skillSourceURL(in appBundle: URL) -> URL {
        appBundle.appendingPathComponent("Contents/Resources/skill/SKILL.md")
    }

    public static func install(
        appBundle: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> Installed {
        let fm = FileManager.default
        let helper = helperURL(in: appBundle)
        let skillSource = skillSourceURL(in: appBundle)
        guard fm.isExecutableFile(atPath: helper.path) else {
            throw Failure("The CLI helper is missing from the app bundle (\(helper.path)). Rebuild and reinstall LabTunnel.")
        }
        guard fm.fileExists(atPath: skillSource.path) else {
            throw Failure("The skill file is missing from the app bundle (\(skillSource.path)). Rebuild and reinstall LabTunnel.")
        }

        let binDirectory = home.appendingPathComponent(".local/bin")
        let link = binDirectory.appendingPathComponent("labtunnel")
        try fm.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        // Replace our own symlink, but never clobber a real file someone put there.
        if let type = try? fm.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType {
            guard type == .typeSymbolicLink else {
                throw Failure("\(link.path) already exists and is not a symlink. Move it away and try again.")
            }
            try fm.removeItem(at: link)
        }
        try fm.createSymbolicLink(at: link, withDestinationURL: helper)

        let skillDirectory = home.appendingPathComponent(".agents/skills/labtunnel")
        let skillFile = skillDirectory.appendingPathComponent("SKILL.md")
        try fm.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
        if fm.fileExists(atPath: skillFile.path) { try fm.removeItem(at: skillFile) }
        try fm.copyItem(at: skillSource, to: skillFile)

        return Installed(cliLink: link, skillFile: skillFile)
    }
}
