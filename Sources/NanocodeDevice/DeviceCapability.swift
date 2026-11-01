#if os(iOS)
import AVFoundation
import Contacts
@preconcurrency import CoreBluetooth
import CoreLocation
import CoreMotion
@preconcurrency import CoreNFC
import EventKit
import Intents
import MediaPlayer
import Nanocode
import PassKit
import Photos
import Speech
import UserNotifications

public struct DeviceCapability: Sendable, Hashable, Identifiable {
  public let name: String
  public let label: String
  public let group: String
  public let description: String
  let standardReason: String
  public let tools: [String]
  public let symbol: String
  public var entitlement: String? = nil
  public var id: String { name }

  public var reason: String { DeviceTools.settings.reasons[name] ?? standardReason }

  public var available: Bool { entitlement.map(Entitlements.has) ?? true }

  public static let groups = ["Your data", "Where you are", "Camera and voice", "Home and media", "Nearby", "Alerts"]

  public static let all: [DeviceCapability] = [
    DeviceCapability(name: "contacts", label: "Contacts", group: "Your data", description: "Search, add, edit and group contacts",
                    standardReason: "The assistant can search, add and edit your contacts when you ask it to.",
                    tools: ["contacts"], symbol: "person.crop.circle"),
    DeviceCapability(name: "calendar", label: "Calendars", group: "Your data", description: "Every calendar: read, add, change and delete events",
                    standardReason: "The assistant can read your schedule and add or change events when you ask it to.",
                    tools: ["calendar"], symbol: "calendar"),
    DeviceCapability(name: "reminders", label: "Reminders", group: "Your data", description: "Lists and reminders: add, change, complete",
                    standardReason: "The assistant can read, add, change and complete your reminders when you ask it to.", tools: ["reminders"], symbol: "checklist"),
    DeviceCapability(name: "photos", label: "Photos", group: "Your data", description: "Search, view, read, save, edit and organize photos",
                    standardReason: "The assistant can find, view, save, edit and organize your photos when you ask it to.",
                    tools: ["photos", "photo_library"], symbol: "photo.on.rectangle"),
    DeviceCapability(name: "health", label: "Health", group: "Your data", description: "Read and write Health data, type by type",
                    standardReason: "The assistant can read and record Health data, such as steps, sleep, heart rate and workouts, when you ask it to.",
                    tools: ["health"], symbol: "heart", entitlement: Entitlements.healthKey),
    DeviceCapability(name: "wallet", label: "Wallet", group: "Your data", description: "See and manage Wallet passes",
                    standardReason: "The assistant can list your boarding passes and tickets and add passes to Wallet when you ask it to.",
                    tools: ["wallet"], symbol: "wallet.pass", entitlement: Entitlements.walletKey),
    DeviceCapability(name: "location", label: "Location", group: "Where you are", description: "Where you are, places nearby, directions",
                    standardReason: "The assistant can find where you are, search places nearby and work out directions when you ask it to.",
                    tools: ["location"], symbol: "location"),
    DeviceCapability(name: "location_always", label: "Location in the background", group: "Where you are",
                    description: "Geofences that notify you when you arrive or leave",
                    standardReason: "The assistant can remind you when you arrive at or leave a place, even when \(DeviceTools.settings.app) is closed.",
                    tools: ["geofence"], symbol: "location.circle"),
    DeviceCapability(name: "motion", label: "Motion and fitness", group: "Where you are", description: "Steps, activity, altitude",
                    standardReason: "The assistant can read your steps, activity and altitude when you ask it to.", tools: ["motion"], symbol: "figure.walk"),
    DeviceCapability(name: "camera", label: "Camera", group: "Camera and voice", description: "Take photos and scan documents with you",
                    standardReason: "The assistant can open the camera to take a photo or scan a document for you.", tools: ["camera"], symbol: "camera"),
    DeviceCapability(name: "microphone", label: "Microphone and speech", group: "Camera and voice", description: "Listen, and transcribe audio",
                    standardReason: "The assistant can listen or transcribe audio when you ask it to.",
                    tools: ["listen", "speech"], symbol: "mic"),
    DeviceCapability(name: "home", label: "Home", group: "Home and media", description: "Control accessories and run scenes",
                    standardReason: "The assistant can see and control your Home accessories and scenes when you ask it to.",
                    tools: ["home"], symbol: "house", entitlement: Entitlements.homeKey),
    DeviceCapability(name: "music", label: "Media library", group: "Home and media", description: "Search and play music, podcasts and audiobooks",
                    standardReason: "The assistant can search and play music from your library when you ask it to.", tools: ["music"], symbol: "music.note"),
    DeviceCapability(name: "bluetooth", label: "Bluetooth", group: "Nearby", description: "Find, read and write Bluetooth devices",
                    standardReason: "The assistant can find Bluetooth devices near you and talk to them when you ask it to.",
                    tools: ["bluetooth"], symbol: "dot.radiowaves.left.and.right"),
    DeviceCapability(name: "local_network", label: "Local network", group: "Nearby", description: "Devices and services on your Wi-Fi",
                    standardReason: "The assistant can find printers, speakers, TVs and other devices on your network when you ask it to.",
                    tools: ["local_network"], symbol: "network"),
    DeviceCapability(name: "nfc", label: "NFC tags", group: "Nearby", description: "Read and write NFC tags",
                    standardReason: "The assistant can read and write NFC tags you hold your iPhone to.", tools: ["nfc"], symbol: "wave.3.right",
                    entitlement: Entitlements.nfcKey),
    DeviceCapability(name: "notifications", label: "Notifications", group: "Alerts", description: "Schedule, list and clear notifications",
                    standardReason: "The assistant can remind you with a notification.",
                    tools: ["notification"], symbol: "bell"),
    DeviceCapability(name: "focus", label: "Focus", group: "Alerts", description: "Whether a Focus is on",
                    standardReason: "The assistant can tell whether you have a Focus on before it interrupts you.", tools: ["focus"], symbol: "moon",
                    entitlement: Entitlements.focusKey),
  ]

  public static var available: [DeviceCapability] { all.filter(\.available) }

  public static let open: [(tool: String, label: String, symbol: String)] = [
    ("device_info", "Device info", "iphone"), ("open_url", "Open links", "safari"), ("clipboard", "Clipboard", "doc.on.clipboard"),
    ("speak", "Speak aloud", "speaker.wave.2"), ("compose", "Message and email drafts", "square.and.pencil"), ("shortcut", "Run Shortcuts", "square.stack.3d.up"),
    ("files", "Files and the document picker", "folder"), ("screen", "Brightness, haptics and torch", "sun.max"), ("wallet", "Add Wallet passes", "wallet.pass"),
  ]

  public static func named(_ name: String) -> DeviceCapability? { all.first { $0.name == name } }

  public static func hand(ask: @escaping @Sendable (_ capability: String, _ reason: String) async -> Bool) -> [HandCapability] {
    available.map { capability in
      let name = capability.name
      return HandCapability(name: name, description: capability.description, tools: capability.tools,
                            permission: { await permission(name) },
                            request: { reason in
                              let current = await permission(name)
                              guard current == .prompt else { return current }
                              guard await ask(name, reason) else { return .denied }
                              return await system(name)
                            })
    }
  }

  static let alwaysAskedKey = "PhoneLocationAlwaysAsked"

  public static func permission(_ name: String) async -> HandPermission {
    if let capability = named(name), !capability.available { return .denied }
    switch name {
    case "photos":
      switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
      case .authorized, .limited: return .granted
      case .denied, .restricted: return .denied
      default: return .prompt
      }
    case "contacts":
      switch CNContactStore.authorizationStatus(for: .contacts) {
      case .authorized, .limited: return .granted
      case .denied, .restricted: return .denied
      default: return .prompt
      }
    case "calendar": return events(.event)
    case "reminders": return events(.reminder)
    case "health": return await DeviceKit.healthPermission()
    case "wallet": return PKPassLibrary.isPassLibraryAvailable() ? .granted : .denied
    case "location":
      switch await MainActor.run(body: { DeviceTools.locator.authorizationStatus }) {
      case .authorizedAlways, .authorizedWhenInUse: return .granted
      case .denied, .restricted: return .denied
      default: return .prompt
      }
    case "location_always":
      switch await MainActor.run(body: { DeviceTools.locator.authorizationStatus }) {
      case .authorizedAlways: return .granted
      case .denied, .restricted: return .denied
      case .authorizedWhenInUse: return UserDefaults.standard.bool(forKey: alwaysAskedKey) ? .denied : .prompt
      default: return .prompt
      }
    case "notifications":
      switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
      case .notDetermined: return .prompt
      case .denied: return .denied
      default: return .granted
      }
    case "focus":
      switch INFocusStatusCenter.default.authorizationStatus {
      case .authorized: return .granted
      case .denied, .restricted: return .denied
      default: return .prompt
      }
    case "microphone":
      let speech = SFSpeechRecognizer.authorizationStatus()
      let microphone = AVCaptureDevice.authorizationStatus(for: .audio)
      if speech == .authorized && microphone == .authorized { return .granted }
      if [.denied, .restricted].contains(speech) || [.denied, .restricted].contains(microphone) { return .denied }
      return .prompt
    case "camera":
      switch AVCaptureDevice.authorizationStatus(for: .video) {
      case .authorized: return .granted
      case .denied, .restricted: return .denied
      default: return .prompt
      }
    case "motion":
      switch CMMotionActivityManager.authorizationStatus() {
      case .authorized: return .granted
      case .denied, .restricted: return .denied
      default: return .prompt
      }
    case "home": return await HomeHub.shared.permission()
    case "music":
      switch MPMediaLibrary.authorizationStatus() {
      case .authorized: return .granted
      case .denied, .restricted: return .denied
      default: return .prompt
      }
    case "bluetooth":
      switch CBManager.authorization {
      case .allowedAlways: return .granted
      case .denied, .restricted: return .denied
      default: return .prompt
      }
    case "local_network": return DeviceKit.localNetworkPermission()
    case "nfc": return NFCNDEFReaderSession.readingAvailable ? .granted : .denied
    default: return .denied
    }
  }

  static func events(_ type: EKEntityType) -> HandPermission {
    switch EKEventStore.authorizationStatus(for: type) {
    case .fullAccess: .granted
    case .denied, .restricted, .writeOnly: .denied
    default: .prompt
    }
  }

  public static func system(_ name: String) async -> HandPermission {
    if let capability = named(name), !capability.available { return .denied }
    switch name {
    case "photos": _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    case "contacts": _ = try? await CNContactStore().requestAccess(for: .contacts)
    case "calendar": _ = try? await DeviceTools.events.requestFullAccessToEvents()
    case "reminders": _ = try? await DeviceTools.events.requestFullAccessToReminders()
    case "health": return await DeviceKit.askHealth()
    case "location":
      await MainActor.run { DeviceTools.locator.requestWhenInUseAuthorization() }
      await settle(name)
    case "location_always":
      let before = await MainActor.run { DeviceTools.locator.authorizationStatus }
      await MainActor.run { DeviceTools.locator.requestAlwaysAuthorization() }
      if before == .authorizedWhenInUse { UserDefaults.standard.set(true, forKey: alwaysAskedKey) }
      for _ in 0..<600 {
        guard await MainActor.run(body: { DeviceTools.locator.authorizationStatus }) == before else { break }
        try? await Task.sleep(for: .milliseconds(100))
      }
      if await MainActor.run(body: { DeviceTools.locator.authorizationStatus }) == .authorizedWhenInUse {
        UserDefaults.standard.set(true, forKey: alwaysAskedKey)
      }
    case "notifications": _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    case "focus":
      _ = await SystemAuthorization.focus()
    case "microphone":
      _ = await SystemAuthorization.speech()
      _ = await AVCaptureDevice.requestAccess(for: .audio)
    case "camera": _ = await AVCaptureDevice.requestAccess(for: .video)
    case "motion":
      let now = Date()
      _ = try? await DeviceTools.steps(now.addingTimeInterval(-60), now)
    case "home": return await HomeHub.shared.ask()
    case "music": _ = await MPMediaLibrary.requestAuthorization()
    case "bluetooth": _ = try? await DeviceKit.BLE().scan(seconds: 1, services: [])
    case "local_network": return await DeviceKit.askLocalNetwork()
    default: break
    }
    return await permission(name)
  }

  static func settle(_ name: String) async {
    for _ in 0..<600 {
      guard await permission(name) == .prompt else { break }
      try? await Task.sleep(for: .milliseconds(100))
    }
  }
}
#endif
