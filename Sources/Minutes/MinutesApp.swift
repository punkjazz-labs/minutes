import AppKit
import MinutesCore
import SwiftUI

@main
struct MinutesApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var controller = RecordingController()

    var body: some Scene {
        MenuBarExtra {
            MenuView(controller: controller)
        } label: {
            // A dot the owner can see from across the room. Core Audio taps
            // show no menu bar indicator of their own, so the recording state
            // is this app's job to make unmistakable.
            Label(
                controller.isRecording ? "minutes is recording" : "minutes",
                systemImage: controller.isRecording ? "record.circle.fill" : "text.append"
            )
        }
        .menuBarExtraStyle(.window)

        // One window. A meeting opens inside it and the back control returns
        // to the list, so reading three meetings never leaves three windows
        // on screen.
        Window("minutes", id: MinutesWindow.library) {
            LibraryWindow()
        }
        .defaultSize(width: 1_020, height: 620)

        Settings {
            SettingsView(controller: controller)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only. The Info.plist in packaging/macos says the same with
        // LSUIElement, this covers a run without that plist.
        NSApp.setActivationPolicy(.accessory)
    }
}
