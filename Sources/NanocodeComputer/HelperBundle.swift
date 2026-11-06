#if os(macOS)
import Foundation

enum HelperBundle {
    static let suffix = ".computer"
    static var appKey: String { ComputerHost.current.helperKey }
    static var marker: String { ComputerHost.current.environment + "_HELPER" }

    static var appIdentifier: String? {
        Bundle.main.object(forInfoDictionaryKey: appKey) as? String ?? Bundle.main.bundleIdentifier
    }

    static var isHelper: Bool { Bundle.main.object(forInfoDictionaryKey: appKey) != nil }

    static func enter(arguments: [String] = CommandLine.arguments) {
        let main = Bundle.main
        guard ProcessInfo.processInfo.environment[marker] == nil,
              main.bundleURL.pathExtension == "app",
              main.object(forInfoDictionaryKey: appKey) == nil,
              let appID = main.bundleIdentifier,
              let executable = main.executableURL?.resolvingSymlinksInPath()
        else { return }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let name = main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? executable.lastPathComponent
        do {
            let helper = try install(executable: executable, appID: appID, name: name,
                                     in: support.appendingPathComponent(appID, isDirectory: true))
            setenv(marker, "1", 1)
            let first = main.executableURL?.path ?? executable.path
            var argv = ([first] + arguments.dropFirst()).map { strdup($0) } + [nil]
            execv(helper.path, &argv)
            throw CUAError("execv: \(String(cString: strerror(errno)))")
        } catch {
            FileHandle.standardError.write(Data("computer use: running without its own bundle (\(error))\n".utf8))
        }
    }

    static func install(executable: URL, appID: String, name: String, in folder: URL) throws -> URL {
        let fm = FileManager.default
        let bundle = folder.appendingPathComponent("Computer", isDirectory: true)
            .appendingPathComponent(stableHash(executable.path), isDirectory: true)
            .appendingPathComponent("\(name) Computer.app", isDirectory: true)
        let link = bundle.appendingPathComponent("Contents/MacOS/\(executable.lastPathComponent)")
        let plist = try infoPlist(appID: appID, name: name, executable: executable.lastPathComponent)
        let current = {
            (try? fm.destinationOfSymbolicLink(atPath: link.path)) == executable.path
                && (try? Data(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))) == plist
        }
        if current() { return link }
        let staging = bundle.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).app", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try plist.write(to: staging.appendingPathComponent("Contents/Info.plist"))
        try fm.createSymbolicLink(atPath: staging.appendingPathComponent("Contents/MacOS/\(executable.lastPathComponent)").path,
                                  withDestinationPath: executable.path)
        if current() { return link }
        try? fm.removeItem(at: bundle)
        if rename(staging.path, bundle.path) != 0, (try? fm.destinationOfSymbolicLink(atPath: link.path)) != executable.path {
            throw CUAError("couldn’t create \(bundle.path): \(String(cString: strerror(errno)))")
        }
        return link
    }

    static func infoPlist(appID: String, name: String, executable: String) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": appID + suffix,
            "CFBundleName": name,
            "CFBundleExecutable": executable,
            "CFBundlePackageType": "APPL",
            "LSUIElement": true,
            appKey: appID,
        ] as [String: Any], format: .xml, options: 0)
    }

    static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return String(hash, radix: 16)
    }
}
#endif
