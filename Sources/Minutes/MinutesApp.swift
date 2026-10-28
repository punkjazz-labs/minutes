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

        // One window: the meetings in a list, and the one selected open beside
        // it, so reading three meetings never leaves three windows on screen.
        Window("minutes", id: MinutesWindow.library) {
            LibraryWindow()
        }
        .defaultSize(width: 1_240, height: 760)

        Window("Settings", id: "settings") {
            SettingsView(controller: controller)
        }
        .defaultSize(width: 480, height: 640)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only. The Info.plist in packaging/macos says the same with
        // LSUIElement, this covers a run without that plist.
        NSApp.setActivationPolicy(.accessory)
        #if DEBUG
        // `swift run minutes --render-snapshots <dir>` draws the app's views
        // from a made-up notes folder and quits. Not in a release build.
        _ = MainActor.assumeIsolated { SnapshotRenderer.runIfAsked() }
        #endif
    }
}
