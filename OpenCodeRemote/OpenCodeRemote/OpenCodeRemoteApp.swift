//
//  OpenCodeRemoteApp.swift
//  OpenCodeRemote
//
//  Created by Tim Laing on 17/10/2026.
//

import SwiftUI
import UserNotifications

@main
struct OpenCodeRemoteApp: App {
    /// Strong reference for the process's lifetime: iOS delivers an
    /// app-posted notification SILENTLY while the app is still
    /// foreground-ish (app switcher, Control Center) unless this
    /// delegate answers `willPresent` — the exact window S17
    /// banners target (review W16 r10).
    private let notificationPresenter = ExecutionNotificationPresenter()

    init() {
        UNUserNotificationCenter.current().delegate = notificationPresenter
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
