import Foundation

public enum HandPermission: String, Sendable {
  case granted
  case prompt
  case denied
}

public struct HandEnvironment: Sendable {
  public var platform: String?
  public var osVersion: String?
  public var shell: String?

  public init(platform: String? = nil, osVersion: String? = nil, shell: String? = nil) {
    self.platform = platform
    self.osVersion = osVersion
    self.shell = shell
  }

  var json: JSON {
    var object: [String: JSON] = [:]
    if let platform { object["platform"] = .string(platform) }
    if let osVersion { object["os_version"] = .string(osVersion) }
    if let shell { object["shell"] = .string(shell) }
    return .object(object)
  }
}

public struct HandCapability: Sendable {
  public var name: String
  public var description: String
  public var tools: [String]
  public var permission: @Sendable () async -> HandPermission
  public var request: (@Sendable (_ reason: String) async -> HandPermission)?

  public init(name: String, description: String, tools: [String] = [],
              permission: @escaping @Sendable () async -> HandPermission,
              request: (@Sendable (_ reason: String) async -> HandPermission)? = nil) {
    self.name = name
    self.description = description
    self.tools = tools
    self.permission = permission
    self.request = request
  }

  var spec: JSON {
    ["name": .string(name), "description": .string(description), "tools": .array(tools.map(JSON.string))]
  }
}

extension Router {
  func answerCapability(id: UInt64, body: JSON) {
    let hand = body["hand"]?.string ?? ""
    let capabilities = state.withLock { $0.capabilities[hand] ?? [] }
    Task.detached { [weak self] in
      let reply: JSON
      switch body["op"]?.string {
      case "list":
        var permissions: [String: JSON] = [:]
        for capability in capabilities { permissions[capability.name] = .string(await capability.permission().rawValue) }
        reply = ["id": .number(Double(id)), "ok": .object(permissions)]
      case "request":
        let name = body["name"]?.string ?? ""
        if let capability = capabilities.first(where: { $0.name == name }) {
          let reason = body["reason"]?.string ?? ""
          var answer: HandPermission
          if let request = capability.request { answer = await request(reason) } else { answer = await capability.permission() }
          reply = ["id": .number(Double(id)), "ok": .string(answer.rawValue)]
        } else {
          reply = ["id": .number(Double(id)), "error": .string("this hand offers no capability named \(name)")]
        }
      default:
        reply = ["id": .number(Double(id)), "error": "this app does not answer that capability call"]
      }
      self?.send(["command": ["reply": reply]])
    }
  }
}
