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
  public var error: String?
  @ObservationIgnored private let runtime: NanocodeRuntime
  @ObservationIgnored private var listener: Task<Void, Never>?
  @ObservationIgnored private var poller: Task<Void, Never>?
  @ObservationIgnored private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
  @ObservationIgnored public let id: String

  public var running: Bool { state.running }

  public init(runtime: NanocodeRuntime, id: String = "default") {
    self.runtime = runtime
    self.id = id
    let events = runtime.events
    listener = Task { @MainActor [weak self] in
      for await event in events {
        guard let self else { return }
        switch event {
        case .hand(let hand, let event) where hand == self.id:
          if let next = HandState(event) { self.move(next) }
        case .handStopped(let hand, let error) where hand == self.id:
          self.move(.stopped(error: error))
          self.poller?.cancel()
        case .runner(let runner, let event) where runner == self.id:
          if let next = HandState(event) { self.move(next) }
        case .runnerStopped(let runner, let error) where runner == self.id:
          self.move(.stopped(error: error))
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
      move(.connecting)
      poll()
    } catch {
      self.error = error.localizedDescription
    }
  }

  public func start(runner configuration: RunnerConfiguration) async {
    var configuration = configuration
    configuration.id = id
    error = nil
    do {
      _ = try await runtime.startRunner(configuration)
      move(.connecting)
    } catch {
      self.error = error.localizedDescription
    }
  }

  public func stop() async {
    poller?.cancel()
    try? await runtime.stopRunner(id)
    try? await runtime.stopHand(id)
    move(.idle)
    status = nil
  }

  public func online(within timeout: Duration) async -> Bool {
    if state.online { return true }
    guard state.running else { return false }
    let key = UUID()
    let timer = Task { @MainActor [weak self] in
      try? await Task.sleep(for: timeout)
      self?.waiters.removeValue(forKey: key)?.resume(returning: false)
    }
    defer { timer.cancel() }
    return await withCheckedContinuation { waiters[key] = $0 }
  }

  private func move(_ next: HandState) {
    state = next
    guard next.online || !next.running else { return }
    let waiting = waiters
    waiters = [:]
    for waiter in waiting.values { waiter.resume(returning: next.online) }
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
