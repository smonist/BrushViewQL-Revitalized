// SPDX-License-Identifier: GPL-3.0-or-later

import ABRKit
import QuickLookThumbnailing

/// The first brush, or a 2×2 of the first four, letterboxed on white.
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        do {
            let brushes = try ABRFile(contentsOf: request.fileURL).brushes.prefix(4)
            guard !brushes.isEmpty else { throw ABRError.noSampleSection }
            let size = request.maximumSize
            let cells = brushes.count == 1 ? 1 : 2
            let cell = CGSize(width: size.width / CGFloat(cells), height: size.height / CGFloat(cells))
            // Only these (at most four) brushes are decoded, at the size they're drawn.
            let images = brushes.compactMap { $0.image(maxPixelSize: Int(max(cell.width, cell.height) * request.scale)) }

            handler(QLThumbnailReply(contextSize: size) { ctx in
                ctx.setFillColor(.white)
                ctx.fill(CGRect(origin: .zero, size: size))
                for (i, image) in images.enumerated() {
                    let slot = CGRect(
                        x: CGFloat(i % cells) * cell.width,
                        y: size.height - CGFloat(i / cells + 1) * cell.height,
                        width: cell.width, height: cell.height
                    ).insetBy(dx: cell.width * 0.06, dy: cell.height * 0.06)
                    let s = min(slot.width / CGFloat(image.width), slot.height / CGFloat(image.height))
                    let w = CGFloat(image.width) * s, h = CGFloat(image.height) * s
                    ctx.draw(image, in: CGRect(x: slot.midX - w / 2, y: slot.midY - h / 2, width: w, height: h))
                }
                return true
            }, nil)
        } catch {
            handler(nil, error)
        }
    }
}
