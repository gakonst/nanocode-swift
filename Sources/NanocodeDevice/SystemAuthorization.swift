#if os(iOS) || os(macOS)
import Foundation
import Intents
import Speech

enum SystemAuthorization {
  nonisolated static func speech() async -> SFSpeechRecognizerAuthorizationStatus {
    await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
      SFSpeechRecognizer.requestAuthorization { @Sendable status in continuation.resume(returning: status) }
    }
  }

  nonisolated static func focus() async -> INFocusStatusAuthorizationStatus {
    await withCheckedContinuation { (continuation: CheckedContinuation<INFocusStatusAuthorizationStatus, Never>) in
      INFocusStatusCenter.default.requestAuthorization { @Sendable status in continuation.resume(returning: status) }
    }
  }
}
#endif
