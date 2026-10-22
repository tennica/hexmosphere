// SPDX-License-Identifier: Apache-2.0
// Hexmosphere: where your photos were taken, as H3 hexagons. Everything stays on this Mac.

import SwiftUI

@main
struct HexmosphereApp: App {
    var body: some Scene {
        WindowGroup("Hexmosphere") {
            #if os(macOS)
            ContentView()
                .frame(minWidth: 800, minHeight: 560)
            #else
            ContentView()
            #endif
        }
    }
}
