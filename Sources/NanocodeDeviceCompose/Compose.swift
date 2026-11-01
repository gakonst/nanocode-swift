#if os(iOS) || os(macOS)
import Foundation
import Nanocode
import NanocodeDevice
#if os(iOS)
@preconcurrency import MessageUI
import UIKit
#else
import AppKit
#endif

extension DeviceComposer {
  #if os(iOS)
  public static let system = DeviceComposer(
    available: { kind in kind == "email" ? MFMailComposeViewController.canSendMail() : MFMessageComposeViewController.canSendText() },
    compose: { kind, to, subject, body, presenter in
      let composer = Composer()
      let controller: UIViewController
      if kind == "email" {
        let mail = MFMailComposeViewController()
        mail.mailComposeDelegate = composer
        mail.setToRecipients(to)
        mail.setSubject(subject)
        mail.setMessageBody(body, isHTML: false)
        controller = mail
      } else {
        let message = MFMessageComposeViewController()
        message.messageComposeDelegate = composer
        message.recipients = to
        message.body = body
        controller = message
      }
      let result = await withCheckedContinuation { continuation in
        composer.done = continuation
        presenter.present(controller, animated: true)
      }
      withExtendedLifetime(composer) {}
      return result
    }
  )

  @MainActor final class Composer: NSObject, @preconcurrency MFMessageComposeViewControllerDelegate, @preconcurrency MFMailComposeViewControllerDelegate {
    var done: CheckedContinuation<String, Never>?

    func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
      controller.dismiss(animated: true)
      done?.resume(returning: result == .sent ? "sent" : result == .cancelled ? "cancelled" : "failed")
      done = nil
    }

    func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
      controller.dismiss(animated: true)
      done?.resume(returning: result == .sent ? "sent" : result == .saved ? "saved as a draft" : result == .cancelled ? "cancelled" : "failed")
      done = nil
    }
  }
  #else
  public static let system = DeviceComposer(
    available: { kind in
      guard let service = NSSharingService(named: kind == "email" ? .composeEmail : .composeMessage) else { return false }
      return service.canPerform(withItems: [""])
    },
    compose: { kind, to, subject, body, _ in
      guard let service = NSSharingService(named: kind == "email" ? .composeEmail : .composeMessage) else {
        throw NanocodeError("this Mac cannot compose that")
      }
      service.recipients = to
      service.subject = subject
      service.perform(withItems: [body])
      return "opened for the owner to send"
    }
  )
  #endif
}
#endif
