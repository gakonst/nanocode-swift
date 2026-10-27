import Foundation
import Nanocode

setbuf(stdout, nil)

let arguments = CommandLine.arguments.dropFirst()
if arguments.first == "wallet" {
  let runtime = try NanocodeRuntime(dataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("nanocode-console-wallet", isDirectory: true))
  let events = runtime.events
  Task {
    for await event in events {
      if case .walletPrompt(let prompt) = event {
        print("[wallet] approve \(prompt.userCode) at \(prompt.verificationURIComplete ?? prompt.verificationURI)")
      }
    }
  }
  let record = try await Wallet(runtime: runtime).connect(name: "nanocode console", website: "https://nanocode.xyz")
  print("[wallet] connected \(record.account) with key \(record.keyAddress)")
  exit(0)
}
if arguments.first == "hand" || arguments.first == "runner" {
  let values = Array(arguments.dropFirst())
  guard values.count >= 2 else {
    print("usage: Console hand|runner <url> <token> [name]")
    exit(2)
  }
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nanocode-console-hand", isDirectory: true)
  let runtime = try NanocodeRuntime(dataDirectory: directory)
  let events = runtime.events
  let clock = HostTool(
    name: "clock",
    description: "Returns the current date and time on the device that runs this hand.",
    parameters: ["type": "object", "properties": [:], "additionalProperties": false]
  ) { _ in .text(Date().formatted(date: .complete, time: .complete)) }
  if arguments.first == "hand" {
    let status = try await runtime.startHand(HandConfiguration(url: values[0], token: values[1], name: values.count > 2 ? values[2] : "console", tools: [clock]))
    print("[hand] \(status?.directory ?? "")")
  } else {
    print("[runner] \(try await runtime.startRunner(RunnerConfiguration(url: values[0], token: values[1], tools: [clock])).text())")
  }
  for await event in events {
    switch event {
    case .hand(_, let event), .runner(_, let event): print("[event] \(event.text())")
    case .handStopped(_, let error), .runnerStopped(_, let error):
      print("[stopped] \(error ?? "")")
      exit(0)
    default: break
    }
  }
  exit(0)
}
let provider = Provider(rawValue: ProcessInfo.processInfo.environment["NANOCODE_PROVIDER"] ?? "claude") ?? .claude
let model = ProcessInfo.processInfo.environment["NANOCODE_MODEL"]
let prompt = arguments.joined(separator: " ").isEmpty ? "Say hi in five words." : arguments.joined(separator: " ")
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nanocode-console", isDirectory: true)

let runtime = try NanocodeRuntime(dataDirectory: directory)
let events = runtime.events
Task {
  for await event in events {
    switch event {
    case .notice(let notice): print("[payments] \(notice)")
    case .payments(let status): print("[spend] \(PaymentStatus(status).total) MACH")
    case .log(let line): print("[log] \(line)")
    default: break
    }
  }
}
let wallet = Wallet(runtime: runtime)
let authentication: Authentication
if let key = ProcessInfo.processInfo.environment[provider == .claude ? "ANTHROPIC_API_KEY" : "OPENAI_API_KEY"] {
  authentication = .apiKey(key)
} else {
  let status = try await wallet.useTempoCLI()
  print("[wallet] \(status.account ?? "none") via \(status.source ?? "")")
  authentication = .tempo
}
let clock = HostTool(
  name: "clock",
  description: "Returns the current date and time on this device.",
  parameters: ["type": "object", "properties": [:], "additionalProperties": false]
) { _ in .text(Date().formatted(date: .complete, time: .complete)) }
var configuration = SessionConfiguration(provider: provider, model: model, authentication: authentication, tools: [clock])
if let token = ProcessInfo.processInfo.environment["NANOCODE_RELAY_TOKEN"] {
  let relay = HandRelay(token: token)
  configuration.hands = [relay.brain()]
  print("[relay] \(relay.short)")
}
let session = try await runtime.open(configuration)
print("[session] \(session.id) \(session.model)")
let chat = await Chat(revealMs: 0)
await chat.attach(session, history: false)
await chat.send(prompt)
var printed = 0
while true {
  try await Task.sleep(nanoseconds: 200_000_000)
  let (entries, pending, error) = await MainActor.run { (chat.entries, chat.pending, chat.error) }
  for entry in entries.dropFirst(printed) {
    switch entry.kind {
    case .tool: print("⏺ \(entry.text)")
    case .user: print("› \(entry.text)")
    default: print("[\(entry.kind.rawValue)] \(entry.text)")
    }
  }
  printed = entries.count
  if let error { print("[error] \(error)") }
  if !pending, printed > 1 { break }
}
let status = try await wallet.status()
print("[spend] total \(status.total) MACH across \(status.services.count) services")
