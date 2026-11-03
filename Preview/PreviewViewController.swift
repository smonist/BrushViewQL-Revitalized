// SPDX-License-Identifier: GPL-3.0-or-later

import ABRKit
import Cocoa
import QuickLookUI
import SwiftUI

final class PreviewViewController: NSViewController, QLPreviewingController {
    override var nibName: NSNib.Name? { nil }

    override func loadView() {
        view = NSView()
        preferredContentSize = NSSize(width: 720, height: 540)
    }

    func preparePreviewOfFile(at url: URL) async throws {
        // Errors (unsupported version, damaged file) render as a message instead of failing the preview.
        let host = NSHostingView(rootView: BrushGrid(file: Result { try ABRFile(contentsOf: url) }))
        host.frame = view.bounds
        host.autoresizingMask = [.width, .height]
        view.addSubview(host)
    }
}
