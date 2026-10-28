import Foundation
import NanocodeCore
import Observation
import os

public protocol SubscriptionStore: Sendable {
  func load(key: String) async throws -> StoredSubscription
  func compareAndSwap(key: String, expectedRevision: UInt64, payload: String) async throws -> UInt64?
}

public struct StoredSubscription: Sendable, Hashable {
  public var revision: UInt64
  public var payload: String?

  public init(revision: UInt64, payload: String?) {
    self.revision = revision
    self.payload = payload
  }
}

public final class KeychainSubscriptionStore: SubscriptionStore {
  public let service: String
  private let lock = OSAllocatedUnfairLock()

  public init(service: String = "xyz.nanocode.plans") {
    self.service = service
  }

  private func read(_ key: String) -> StoredSubscription {
    guard let data = Keychain.load(service: service, account: key), let json = try? JSON.parse(data) else {
      return StoredSubscription(revision: 0, payload: nil)
    }
    return StoredSubscription(revision: json["revision"]?.uint64 ?? 0, payload: json["payload"]?.string)
  }

  public func load(key: String) async throws -> StoredSubscription {
    lock.withLock { read(key) }
  }

  public func compareAndSwap(key: String, expectedRevision: UInt64, payload: String) async throws -> UInt64? {
    try lock.withLock {
      guard read(key).revision == expectedRevision else { return nil }
      let next = expectedRevision + 1
      let record: JSON = ["revision": .number(Double(next)), "payload": .string(payload)]
      try Keychain.save(record.data(), service: service, account: key)
      return next
    }
  }
}

public struct PlanStatus: Sendable, Hashable {
  public let state: String
  public let accountID: String?
  public let verificationURL: URL?
  public let userCode: String?
  public let expiresAt: Date?

  public var isSignedIn: Bool { state == "authenticated" }
  public var isPending: Bool { state == "pending" || state == "validating" }

  init(_ json: JSON) {
    state = json["state"]?.string ?? "signed_out"
    accountID = json["account_id"]?.string
    verificationURL = json["verification_url"]?.string.flatMap(URL.init(string:))
    userCode = json["user_code"]?.string
    expiresAt = json["expires_at_ms"]?.number.map { Date(timeIntervalSince1970: $0 / 1000) }
  }
}

public struct PlanSignIn: Sendable {
  public enum Step: Sendable, Hashable {
    case openURL(URL)
    case enterCode(URL, code: String)
  }

  public let provider: Provider
  public let step: Step
  let runtime: NanocodeRuntime

  public func complete(_ callbackOrCode: String) async throws -> PlanStatus {
    guard provider == .claude else { return try await status() }
    return PlanStatus(try await runtime.command("plan_sign_in_complete", ["code": .string(callbackOrCode)]))
  }

  public func status() async throws -> PlanStatus {
    try await runtime.planStatus(provider)
  }
}

extension NanocodeRuntime {
  public func signIn(plan provider: Provider, redirectURI: URL? = nil) async throws -> PlanSignIn {
    var body: [String: JSON] = ["provider": .string(provider.rawValue)]
    if let redirectURI { body["redirect_uri"] = .string(redirectURI.absoluteString) }
    let started = try await command("plan_sign_in", .object(body))
    if let url = started["authorization_url"]?.string.flatMap(URL.init(string:)) {
      return PlanSignIn(provider: provider, step: .openURL(url), runtime: self)
    }
    let status = PlanStatus(started)
    guard let page = status.verificationURL, let code = status.userCode else {
      throw NanocodeError("the \(provider.rawValue) sign-in returned no URL or code")
    }
    return PlanSignIn(provider: provider, step: .enterCode(page, code: code), runtime: self)
  }

  public func planStatus(_ provider: Provider) async throws -> PlanStatus {
    PlanStatus(try await command("plan_status", ["provider": .string(provider.rawValue)]))
  }

  public func signOut(plan provider: Provider) async throws {
    _ = try await command("plan_sign_out", ["provider": .string(provider.rawValue)])
  }
}

enum SubscriptionCalls {
  static func answer(_ body: JSON, store: any SubscriptionStore) async throws -> JSON {
    if let load = body["load"], let key = load["key"]?.string {
      let value = try await store.load(key: key)
      return ["revision": .number(Double(value.revision)), "payload": value.payload.map(JSON.string) ?? .null]
    }
    if let swap = body["compare_and_swap"], let key = swap["key"]?.string, let revision = swap["revision"]?.uint64,
       let payload = swap["payload"]?.string {
      return try await store.compareAndSwap(key: key, expectedRevision: revision, payload: payload)
        .map { .number(Double($0)) } ?? .null
    }
    throw NanocodeError("unknown subscription store call")
  }
}

@MainActor
@Observable
public final class PlanMonitor {
  public private(set) var status: [Provider: PlanStatus] = [:]
  public private(set) var signIns: [Provider: PlanSignIn] = [:]
  public private(set) var busy: Set<Provider> = []
  public var error: String?
  @ObservationIgnored private let runtime: NanocodeRuntime
  @ObservationIgnored private var pollers: [Provider: Task<Void, Never>] = [:]

  public init(runtime: NanocodeRuntime, store: some SubscriptionStore = KeychainSubscriptionStore()) {
    self.runtime = runtime
    runtime.setSubscriptionStore(store)
  }

  public func isSignedIn(_ provider: Provider) -> Bool { status[provider]?.isSignedIn ?? false }

  public func refresh() async {
    for provider in Provider.allCases {
      if let status = try? await runtime.planStatus(provider) { self.status[provider] = status }
    }
  }

  public func signIn(_ provider: Provider) async -> PlanSignIn? {
    error = nil
    busy.insert(provider)
    defer { busy.remove(provider) }
    do {
      let signIn = try await runtime.signIn(plan: provider)
      signIns[provider] = signIn
      if provider == .codex { poll(provider) }
      return signIn
    } catch {
      self.error = error.localizedDescription
      return nil
    }
  }

  public func complete(_ provider: Provider, code: String) async {
    guard let signIn = signIns[provider] else { return }
    error = nil
    busy.insert(provider)
    defer { busy.remove(provider) }
    do {
      let status = try await signIn.complete(code.trimmingCharacters(in: .whitespacesAndNewlines))
      self.status[provider] = status
      if status.isSignedIn { signIns[provider] = nil } else { error = "The sign-in is \(status.state.replacingOccurrences(of: "_", with: " "))." }
    } catch {
      self.error = error.localizedDescription
    }
  }

  public func cancel(_ provider: Provider) {
    pollers.removeValue(forKey: provider)?.cancel()
    signIns[provider] = nil
  }

  public func signOut(_ provider: Provider) async {
    cancel(provider)
    do {
      try await runtime.signOut(plan: provider)
      status[provider] = try await runtime.planStatus(provider)
    } catch {
      self.error = error.localizedDescription
    }
  }

  private func poll(_ provider: Provider) {
    pollers[provider]?.cancel()
    pollers[provider] = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        guard let self, let status = try? await self.runtime.planStatus(provider) else { continue }
        self.status[provider] = status
        if !status.isPending {
          self.signIns[provider] = nil
          if !status.isSignedIn { self.error = "The \(provider == .codex ? "ChatGPT" : "Claude") sign-in \(status.state.replacingOccurrences(of: "_", with: " "))." }
          return
        }
      }
    }
  }
}
