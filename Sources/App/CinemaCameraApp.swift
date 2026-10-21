//
//  CinemaCameraApp.swift
//  iPhoneCinemaCamera // Target: iPhone 15 Pro Max (A17 Pro SoC)
//
//  SwiftUI App Entry Point.
//

import SwiftUI

@main
struct CinemaCameraApp: App {
    init() {
        // Prevent screen auto-lock during production camera shoots
        UIApplication.shared.isIdleTimerDisabled = true
    }
    
    var body: some Scene {
        WindowGroup {
            CinemaHUDView()
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
        }
    }
}
