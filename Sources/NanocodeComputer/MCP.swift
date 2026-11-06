#if os(macOS)
import Foundation

enum MCP {
    static var mode = "direct"

    static let out = FileHandle.standardOutput

    static func send(_ obj: JSON) {
        guard var d = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return }
        d.append(0x0A)
        out.write(d)
    }

    static func reply(_ id: Any, _ result: JSON) { send(["jsonrpc": "2.0", "id": id, "result": result]) }
    static func fail(_ id: Any, _ code: Int, _ msg: String) { send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": msg]]) }

    static func run() {
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty, let data = line.data(using: .utf8),
                  let msg = (try? JSONSerialization.jsonObject(with: data)) as? JSON else { continue }
            handle(msg)
        }
        exit(0)
    }

    static func handle(_ m: JSON) {
        guard let id = m["id"], !(id is NSNull) else { return }
        let method = m["method"] as? String ?? ""
        let params = m["params"] as? JSON ?? [:]
        switch method {
        case "initialize":
            reply(id, [
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": mode == "repl" ? "cua_repl" : ComputerHost.current.server, "version": computerVersion],
                "instructions": mode == "repl" ? JSRuntime.description : Tools.instructions,
            ])
        case "ping":
            reply(id, [:])
        case "tools/list":
            reply(id, ["tools": mode == "repl" ? replSchemas : Tools.schemas])
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? JSON ?? [:]
            if mode == "repl" { reply(id, callRepl(name, args)); return }
            do {
                let r = try Tools.call(name, args)
                var content: [JSON] = [["type": "text", "text": r.text]]
                if let png = r.png { content.append(["type": "image", "data": png.base64EncodedString(), "mimeType": imageMime]) }
                reply(id, ["content": content, "isError": false])
            } catch {
                reply(id, ["content": [["type": "text", "text": "\(error)"]], "isError": true])
            }
        default:
            fail(id, -32601, "method not found: \(method)")
        }
    }

    static var replSchemas: [JSON] {
        [
            ["name": "js", "description": JSRuntime.description,
             "inputSchema": ["type": "object", "additionalProperties": false, "required": ["code"], "properties": [
                "code": ["type": "string", "description": "JavaScript to run in the persistent REPL."],
                "title": ["type": "string", "maxLength": 120, "description": "Short user-facing description of what the code does."],
                "timeout_ms": ["type": "integer", "minimum": 1, "description": "Timeout in milliseconds, default 30000."],
             ] as JSON] as JSON],
            ["name": "js_reset", "description": JSRuntime.resetDescription,
             "inputSchema": ["type": "object", "additionalProperties": false, "properties": [:] as JSON] as JSON],
            ["name": "turn_ended", "description": "Host notification that an agent turn ended. Clears per-turn state.",
             "inputSchema": ["type": "object", "additionalProperties": false, "required": ["hook_event_name", "session_id", "turn_id"],
                             "properties": ["hook_event_name": ["type": "string", "minLength": 1], "session_id": ["type": "string", "minLength": 1],
                                            "turn_id": ["type": "string", "minLength": 1]] as JSON] as JSON],
        ]
    }

    static func callRepl(_ name: String, _ args: JSON) -> JSON {
        switch name {
        case "js":
            guard let code = args["code"] as? String else {
                return ["content": [["type": "text", "text": "code is required"]], "isError": true]
            }
            let r = JSRuntime.shared.run(code, timeoutMs: argInt(args, "timeout_ms") ?? 30_000)
            return ["content": r.content, "isError": r.isError]
        case "js_reset":
            JSRuntime.shared.reset()
            return ["content": [["type": "text", "text": "REPL reset."]], "isError": false]
        case "turn_ended":
            return ["content": [["type": "text", "text": "ok"]], "isError": false]
        default:
            return ["content": [["type": "text", "text": "unknown tool \(name)"]], "isError": true]
        }
    }
}
#endif
