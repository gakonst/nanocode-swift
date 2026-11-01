#if os(iOS)
import Foundation
import Nanocode
import PassKit
import UIKit

extension DeviceKit {
  static var walletActions: [String] { Entitlements.wallet ? ["list", "add", "open", "remove"] : ["add", "open"] }

  static var wallet: HostTool {
    HostTool(
      name: "wallet",
      description: Entitlements.wallet
        ? "Apple Wallet on this \(DeviceTools.here). list: the passes \(DeviceTools.settings.app) may see (boarding passes, tickets, cards of its pass types). add: add a pass (.pkpass) from a URL or a file; the owner confirms. open: open a pass, or Wallet. remove: remove a pass by serial and type."
        : "Apple Wallet on this \(DeviceTools.here). add: add a pass (.pkpass, such as a boarding pass or ticket) from a URL or a file; the owner confirms. open: open Wallet. Listing passes needs a build with the Wallet entitlement.",
      parameters: schema(walletActions, [
        "url": prop("string", "For add: where to download the .pkpass."),
        "container": prop("string", "For add: the files container of a .pkpass."),
        "path": prop("string", "For add: the path of a .pkpass in the files tool."),
        "serial": prop("string", "For open and remove: the pass's serial number."),
        "type": prop("string", "For open and remove: the pass type identifier."),
      ])
    ) { call in try await passes(call.input) }
  }

  static func passes(_ input: JSON) async throws -> ToolResult {
    guard PKPassLibrary.isPassLibraryAvailable() else { throw NanocodeError("Wallet is not available on this \(DeviceTools.here)") }
    let library = PKPassLibrary()
    switch input["action"]?.string {
    case "list" where Entitlements.wallet:
      return .json(.array(library.passes().map(describe)))
    case "add":
      try await foreground("Adding a pass")
      let data: Data
      if let link = text(input, "url") {
        guard let url = URL(string: link), ["http", "https"].contains(url.scheme ?? "") else { throw NanocodeError("url must be http or https") }
        let (bytes, response) = try await URLSession.shared.data(from: url)
        if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) { throw NanocodeError("the pass download answered \(status)") }
        data = bytes
      } else {
        data = try Data(contentsOf: try fileURL(input))
      }
      let pass = try PKPass(data: data)
      let summary = describe(pass)
      if library.containsPass(pass) { return .json(["already_added": .bool(true), "pass": summary]) }
      let added = try await present(pass)
      return .json(["added": .bool(added), "pass": summary])
    case "open":
      try await foreground("Opening Wallet")
      if let serial = text(input, "serial"), let type = text(input, "type"), Entitlements.wallet,
         let pass = library.pass(withPassTypeIdentifier: type, serialNumber: serial), let url = pass.passURL {
        await DeviceTools.open(url)
        return .text("Opened the pass.")
      }
      guard let url = URL(string: "shoebox://") else { throw NanocodeError("Wallet can't be opened") }
      await DeviceTools.open(url)
      return .text("Opened Wallet.")
    case "remove" where Entitlements.wallet:
      let serial = try need(input, "serial", for: "remove")
      let type = try need(input, "type", for: "remove")
      guard let pass = library.pass(withPassTypeIdentifier: type, serialNumber: serial) else { throw NanocodeError("no pass has that serial and type") }
      library.removePass(pass)
      return .json(["removed": .string(serial)])
    default:
      throw unknown("wallet", walletActions)
    }
  }

  static func describe(_ pass: PKPass) -> JSON {
    var object: [String: JSON] = [
      "serial": .string(pass.serialNumber), "type": .string(pass.passTypeIdentifier), "organization": .string(pass.organizationName),
      "description": .string(pass.localizedDescription), "name": .string(pass.localizedName),
    ]
    if let url = pass.passURL { object["url"] = .string(url.absoluteString) }
    if let web = pass.webServiceURL { object["web_service"] = .string(web.absoluteString) }
    if #available(iOS 18.0, *) {
      if let date = pass.relevantDates.first?.date { object["relevant_date"] = DeviceTools.stamp(date) }
    } else if let date = pass.relevantDate {
      object["relevant_date"] = DeviceTools.stamp(date)
    }
    return .object(object)
  }

  @MainActor final class PassSheet: NSObject, @preconcurrency PKAddPassesViewControllerDelegate {
    var done: CheckedContinuation<Void, Never>?
    func addPassesViewControllerDidFinish(_ controller: PKAddPassesViewController) {
      controller.dismiss(animated: true)
      done?.resume()
      done = nil
    }
  }

  @MainActor static func present(_ pass: PKPass) async throws -> Bool {
    guard let controller = PKAddPassesViewController(pass: pass) else { throw NanocodeError("this pass can't be added") }
    let presenter = try DeviceTools.top()
    let sheet = PassSheet()
    controller.delegate = sheet
    await withCheckedContinuation { continuation in
      sheet.done = continuation
      presenter.present(controller, animated: true)
    }
    withExtendedLifetime(sheet) {}
    return PKPassLibrary().containsPass(pass)
  }
}
#endif
