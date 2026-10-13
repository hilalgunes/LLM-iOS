//
//  LLMApp.swift
//  LLM
//
//  Created by Hilal Güneş on 8.10.2026.
//

import SwiftUI
import MLX

@main
struct LLMApp: App {
    init() {
        #if !targetEnvironment(simulator)
        Memory.cacheLimit = 20 * 1024 * 1024
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
