#if os(iOS) || os(macOS)
import AVFoundation
import Foundation
import Nanocode
import Speech

extension DeviceKit {
  static let speechActions = ["transcribe", "voices", "languages"]

  static let speech = HostTool(
    name: "speech",
    description: "Speech on this \(DeviceTools.here) beyond listen and speak. transcribe: the words in an audio or video file from the files tool (on this \(DeviceTools.here) when it can). voices: the voices speak can use. languages: the languages transcription supports.",
    parameters: schema(speechActions, [
      "container": prop("string", "For transcribe: the files container."),
      "path": prop("string", "For transcribe: the file's path."),
      "language": prop("string", "A BCP 47 language such as en-US or el-GR; the \(DeviceTools.here)'s by default."),
    ])
  ) { call in try await voice(call.input) }

  static func voice(_ input: JSON) async throws -> ToolResult {
    switch input["action"]?.string {
    case "transcribe":
      try await DeviceTools.gate("microphone")
      let url = try fileURL(input)
      guard FileManager.default.fileExists(atPath: url.path) else { throw NanocodeError("nothing is at \(input["path"]?.string ?? "")") }
      let language = text(input, "language")
      guard let recognizer = language.map({ SFSpeechRecognizer(locale: Locale(identifier: $0)) }) ?? SFSpeechRecognizer(), recognizer.isAvailable else {
        throw NanocodeError("speech recognition is not available for this language right now")
      }
      let request = SFSpeechURLRecognitionRequest(url: url)
      request.shouldReportPartialResults = false
      request.addsPunctuation = true
      request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
      let text = try await transcribe(recognizer, request)
      return .json(["text": .string(text), "on_device": .bool(request.requiresOnDeviceRecognition)])
    case "voices":
      let language = text(input, "language")
      let voices = AVSpeechSynthesisVoice.speechVoices().filter { language == nil || $0.language.hasPrefix(language ?? "") }
      return .json(.array(voices.map { voice in
        let quality = switch voice.quality {
        case .premium: "premium"
        case .enhanced: "enhanced"
        default: "default"
        }
        return ["id": .string(voice.identifier), "name": .string(voice.name), "language": .string(voice.language), "quality": .string(quality)]
      }))
    case "languages":
      return .json(.array(SFSpeechRecognizer.supportedLocales().map(\.identifier).sorted().map(JSON.string)))
    default:
      throw unknown("speech", speechActions)
    }
  }

  static func transcribe(_ recognizer: SFSpeechRecognizer, _ request: SFSpeechURLRecognitionRequest) async throws -> String {
    let once = Once()
    nonisolated(unsafe) var task: SFSpeechRecognitionTask?
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
        task = recognizer.recognitionTask(with: request) { @Sendable result, error in
          if let result, result.isFinal {
            if once.take() { continuation.resume(returning: result.bestTranscription.formattedString) }
          } else if let error {
            if once.take() { continuation.resume(throwing: error) }
          }
        }
      }
    } onCancel: {
      task?.cancel()
    }
  }
}
#endif
