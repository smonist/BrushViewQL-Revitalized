// SPDX-License-Identifier: GPL-3.0-or-later

import ABRKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct BrushViewQLApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
            .windowResizability(.contentSize)
    }
}

struct ContentView: View {
    @State private var file: Result<ABRFile, Error>?
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("BrushViewQL Revitalized").font(.largeTitle.bold())
            Text("Quick Look previews and Finder thumbnails for Photoshop brush files (.abr). Select one in Finder and press Space.")
            Link("A modern rebuild of BrushViewQL by Little Potato Software",
                 destination: URL(string: "https://www.littlepotatosoftware.com/products/brushviewer.html")!)
            Text("Launch this app once so macOS registers its extensions. If previews still don't appear, enable them in System Settings → General → Login Items & Extensions → Quick Look.")
                .foregroundStyle(.secondary)
            Button("Open a brush file to test the parser…") { importing = true }
            if let file {
                BrushGrid(file: file).frame(minHeight: 420).clipShape(.rect(cornerRadius: 8))
            }
        }
        .padding(24)
        .frame(width: 640)
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(importedAs: "com.adobe.photoshop.brush")]) { result in
            file = Result { try ABRFile(contentsOf: result.get()) }
        }
    }
}
