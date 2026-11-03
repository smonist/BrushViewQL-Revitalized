// Shared by the Quick Look preview and the host app's debug view.
// SPDX-License-Identifier: GPL-3.0-or-later

import ABRKit
import SwiftUI

/// Every bitmap brush in a file, with its pixel dimensions; reflows with the window width.
struct BrushGrid: View {
    let file: Result<ABRFile, Error>

    var body: some View {
        Group {
            switch file {
            case .failure(let error):
                Text((error as? ABRError)?.description ?? error.localizedDescription)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .success(let file):
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 16)], spacing: 16) {
                        ForEach(file.brushes.indices, id: \.self) { BrushCell(brush: file.brushes[$0]) }
                    }
                    .padding()
                    ForEach(notes(file), id: \.self) {
                        Text($0).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 4)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func notes(_ file: ABRFile) -> [String] {
        var notes: [String] = []
        if file.brushes.isEmpty { notes.append("This file contains no bitmap brushes.") }
        if file.skipped > 0 { notes.append("\(file.skipped) non-bitmap or unsupported brush\(file.skipped == 1 ? "" : "es") not shown") }
        if file.isDamaged { notes.append("The file appears damaged; later brushes are missing.") }
        return notes
    }
}

private struct BrushCell: View {
    let brush: Brush
    @State private var image: CGImage?
    @State private var failed = false

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let image {
                    // Template mode tints the alpha mask: dark ink in light mode, light ink in dark mode.
                    Image(decorative: image, scale: 1).renderingMode(.template).resizable().scaledToFit()
                        .frame(maxWidth: CGFloat(brush.width), maxHeight: CGFloat(brush.height))  // don't upscale
                } else if failed {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 128, height: 128)
            Text("\(brush.width) × \(brush.height)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .task {
            // Lazy: only cells scrolled into view decode, downsampled to 2× the cell for Retina.
            image = await Task.detached(priority: .userInitiated) { [brush] in brush.image(maxPixelSize: 256) }.value
            failed = image == nil
        }
    }
}
