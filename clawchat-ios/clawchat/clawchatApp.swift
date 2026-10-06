//
//  clawchatApp.swift
//  clawchat
//
//  Created by Changer Ding on 2026/4/12.
//

import SwiftUI

@main
struct clawchatApp: App {
    @UIApplicationDelegateAdaptor(ChatPushAppDelegate.self) private var appDelegate
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
