//
//  CloseQuitApp.swift
//  CloseQuit
//
//  A menu bar app (LSUIElement, no Dock icon) that quits the apps you list when you close
//  their last window with the red close button or ⌘W.
//

import SwiftUI

@main
struct CloseQuitApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(model: model)
        } label: {
            Image(systemName: model.menuBarSymbol)
                .accessibilityLabel("CloseQuit")
        }
        .menuBarExtraStyle(.window)
    }
}
