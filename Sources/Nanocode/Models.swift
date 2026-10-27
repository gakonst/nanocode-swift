import Foundation

public struct ModelEntry: Sendable, Hashable, Identifiable {
  public let id: String
  public let name: String
  public let efforts: [String]
  public let effort: String
  public let priority: Bool
  public let serviceTiers: [String]
  public let contextWindowTokens: Int
  public let provider: Provider
}

public struct ModelCatalog: Sendable {
  public let models: [Provider: [ModelEntry]]

  public init(_ json: JSON) throws {
    var models: [Provider: [ModelEntry]] = [:]
    for harness in json["harnesses"]?.array ?? [] {
      guard let provider = harness["id"]?.string.flatMap(Provider.init(rawValue:)) else { continue }
      models[provider] = (harness["models"]?.array ?? []).compactMap { model in
        guard let id = model["id"]?.string else { return nil }
        return ModelEntry(
          id: id, name: model["name"]?.string ?? id,
          efforts: model["efforts"]?.array?.compactMap(\.string) ?? [],
          effort: model["effort"]?.string ?? "",
          priority: model["priority"]?.bool ?? false,
          serviceTiers: model["service_tiers"]?.array?.compactMap(\.string) ?? [],
          contextWindowTokens: model["context_window_tokens"]?.int ?? 0,
          provider: provider)
      }
    }
    self.models = models
  }

  public func model(_ id: String) -> ModelEntry? {
    models.values.lazy.flatMap { $0 }.first { $0.id == id }
  }
}
