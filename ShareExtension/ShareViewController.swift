//
//  ShareViewController.swift
//  ShareExtension
//
//  Created by Paul Gessinger on 10.03.23.
//

import AppShared
import AppViews
import Social
import SwiftUI
import UIKit
import os

class ShareViewController: UIViewController {
  @IBOutlet var container: UIView!

  let attachmentManager = AttachmentManager()

  var childView: UIViewController? = nil

  override func viewDidLoad() {
    super.viewDidLoad()
    Logger.shared.notice("Paperless share extension viewDidLoad fired")

    let shareView = ShareView(
      attachmentManager: attachmentManager,
      callback: {
        #if canImport(FileProvider)
          // The extension may be ended right after completing, before a
          // coalesced trailing signal is due; send it first.
          Task { @MainActor in
            await FileProviderSignaler.shared.flush()
            self.extensionContext!.completeRequest(returningItems: nil, completionHandler: nil)
          }
        #else
          self.extensionContext!.completeRequest(returningItems: nil, completionHandler: nil)
        #endif
      })

    childView = UIHostingController(rootView: shareView)
    guard let childView else {
      fatalError("Inconsistency")
    }
    addChild(childView)
    container.addSubview(childView.view)
    childView.didMove(toParent: self)

    Logger.shared.notice("Receiving shared items")
    if let item = extensionContext?.inputItems.first as? NSExtensionItem {
      if let attachments = item.attachments {
        Logger.shared.debug("Recived item(s): \(attachments)")
        attachmentManager.receive(attachments: attachments)
      } else {
        Logger.shared.warning("Attachment was nil")
      }
    } else {
      Logger.shared.warning("Did not receive any items")
    }
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
  }

  override public func viewDidLayoutSubviews() {
    // offset is empirical and probably wrong
    let offset: CGFloat =
      if traitCollection.horizontalSizeClass == .regular {
        40
      } else {
        80
      }
    childView?.view.frame = CGRect(
      x: container.bounds.origin.x, y: container.bounds.origin.y, width: container.bounds.width,
      height: container.bounds.height + offset)
  }
}
