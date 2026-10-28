import Foundation
import NanocodeCore

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

public struct PlanStatus: Sendable, Hashable {
  public let state: String
  public let accountID: String?
  public let verificationURL: URL?
  public let userCode: String?
  public let expiresAt: Date?

  public var isSignedIn: Bool { state == "authenticated" }

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
