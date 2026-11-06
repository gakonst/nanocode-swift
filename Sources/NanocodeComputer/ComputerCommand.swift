#if os(macOS)
import AppKit
import ApplicationServices

public enum ComputerCommand {
    static var usage: String {
        let command = ComputerHost.current.command
        return """
        \(command) \(computerVersion): computer use for the Hand's computer tool

        USAGE:
          \(command) [mcp]               MCP server on stdio, one tool per action (default)
          \(command) cua-repl            The cua_repl MCP contract (js, js_reset, turn_ended)
          \(command) doctor [--prompt]   Show (and ask for) Accessibility and Screen Recording
          \(command) call <tool> [json]  Run one tool and print its text result
          \(command) tools               Print the tool schemas
        """
    }

    public static func isHelper(_ host: ComputerHost) -> Bool {
        ComputerHost.current = host
        return HelperBundle.isHelper
    }

    public static func run(_ args: [String], host: ComputerHost) -> Never {
        ComputerHost.current = host
        let command = args.first ?? "mcp"
        if ["-h", "--help", "help"].contains(command) { print(usage); exit(0) }
        if ["-V", "--version"].contains(command) { print("computer use \(computerVersion)"); exit(0) }

        HelperBundle.enter()
        NSApplication.shared.setActivationPolicy(.accessory)

        switch command {
        case "mcp":
            background { MCP.run() }

        case "cua-repl", "repl":
            MCP.mode = "repl"
            background { MCP.run() }

        case "doctor":
            if args.contains("--prompt") {
                _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
                _ = CGRequestScreenCaptureAccess()
            }
            print("computer use \(computerVersion) in \(Bundle.main.bundleIdentifier ?? Bundle.main.executablePath ?? "?")")
            print("accessibility: \(AXIsProcessTrusted() ? "granted" : "missing")")
            print("screen recording: \(CGPreflightScreenCaptureAccess() ? "granted" : "missing")")
            exit(0)

        case "tools":
            let d = try! JSONSerialization.data(withJSONObject: Tools.schemas, options: [.prettyPrinted, .sortedKeys])
            print(String(data: d, encoding: .utf8)!)
            exit(0)

        case "call":
            guard args.count >= 2 else { print(usage); exit(2) }
            let json = args.count >= 3 ? args[2] : "{}"
            background {
                do {
                    let a = (try JSONSerialization.jsonObject(with: Data(json.utf8))) as? JSON ?? [:]
                    let r = try Tools.call(args[1], a)
                    print(r.text)
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
                    exit(1)
                }
            }

        default:
            print(usage)
            exit(2)
        }
    }

    static func background(_ body: @escaping () -> Void) -> Never {
        Thread { body() }.start()
        RunLoop.main.run()
        exit(0)
    }
}
#endif
