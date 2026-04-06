//
//  hipApp.swift
//  hip
//
//  Created by Mikel Lucyšyn on 3/30/26.
//

import SwiftUI


@main
struct hipApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        WindowGroup(id: "hip-toolkit.preview", for: URL.self) { $url in
            if let url { FilePreviewWindowView(url: url) }
        }
        .defaultSize(width: 720, height: 520)
        .restorationBehavior(.disabled)
    }
}
