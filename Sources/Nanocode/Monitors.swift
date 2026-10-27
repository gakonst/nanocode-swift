import Foundation
import Observation

@MainActor
@Observable
public final class WalletMonitor {
  public private(set) var status: PaymentStatus?
  public private(set) var prompt: DevicePrompt?
  public private(set) var connecting = false
  public private(set) var notices: [String] = []
  public var error: String?
  @ObservationIgnored public let wallet: Wallet
  @ObservationIgnored private var listener: Task<Void, Never>?
  @ObservationIgnored public var name: String
  @ObservationIgnored public var website: String?

  public init(runtime: NanocodeRuntime, name: String = "nanocode", website: String? = "https://nanocode.xyz") {
    wallet = Wallet(runtime: runtime)
    self.name = name
    self.website = website
    let events = runtime.events
    listener = Task { @MainActor [weak self] in
      for await event in events {
        guard let self else { return }
        switch event {
        case .payments(let status): self.status = PaymentStatus(status)
        case .walletPrompt(let prompt): self.prompt = prompt
        case .notice(let notice): self.notices = Array((self.notices + [notice]).suffix(20))
        default: break
        }
      }
    }
  }

  public var connected: Bool { status?.connected == true }

  public func restore() async {
    if let restored = await wallet.restore() { status = restored }
    else { status = try? await wallet.status() }
  }

  public func connect() async {
    connecting = true
    error = nil
    defer {
      connecting = false
      prompt = nil
    }
    do {
      _ = try await wallet.connect(name: name, website: website)
      status = try await wallet.status()
    } catch {
      self.error = error.localizedDescription
    }
  }

  public func useTempoCLI() async {
    error = nil
    do { status = try await wallet.useTempoCLI() } catch { self.error = error.localizedDescription }
  }

  public func disconnect() async {
    do {
      try await wallet.disconnect()
      status = try await wallet.status()
    } catch {
      self.error = error.localizedDescription
    }
  }

  public func fundingURL() async -> URL? {
    guard let account = status?.account else { return nil }
    return try? await wallet.fundingURL(account: account)
  }
}

@MainActor
@Observable
public final class HandMonitor {
  public private(set) var state: HandState = .idle
  public private(set) var status: HandStatus?
  public private(set) var running = false
  public var error: String?
  @ObservationIgnored private let runtime: NanocodeRuntime
  @ObservationIgnored private var listener: Task<Void, Never>?
  @ObservationIgnored private var poller: Task<Void, Never>?
  @ObservationIgnored public let id: String

  public init(runtime: NanocodeRuntime, id: String = "default") {
    self.runtime = runtime
    self.id = id
    let events = runtime.events
    listener = Task { @MainActor [weak self] in
      for await event in events {
        guard let self else { return }
        switch event {
        case .hand(let hand, let event) where hand == self.id:
          self.state = HandState(event)
        case .handStopped(let hand, let error) where hand == self.id:
          self.running = false
          self.state = .stopped(error: error)
          self.poller?.cancel()
        default: break
        }
      }
    }
  }

  public func start(_ configuration: HandConfiguration) async {
    var configuration = configuration
    configuration.id = id
    error = nil
    do {
      status = try await runtime.startHand(configuration)
      running = true
      state = .connecting
      poll()
    } catch {
      self.error = error.localizedDescription
    }
  }

  public func stop() async {
    poller?.cancel()
    try? await runtime.stopHand(id)
    running = false
    state = .idle
    status = nil
  }

  private func poll() {
    poller?.cancel()
    poller = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        guard let self, self.running else { return }
        self.status = try? await self.runtime.hands().first { $0.id == self.id }
      }
    }
  }
}
