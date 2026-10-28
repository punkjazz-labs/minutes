import MinutesCore
import SwiftUI

/// The menu bar panel.
///
/// The meeting comes first: its title, and the notes typed for it, which steer
/// the notes the model writes. The controls sit in a bar pinned to the bottom,
/// so Record and Stop are always in the same place however much is above
/// them. While recording, the bar is where the recording is said: a red dot
/// and a running clock, a level for each side of the meeting, and Stop. A
/// Core Audio tap shows no indicator of its own, so the app makes this one
/// unmistakable.
struct MenuView: View {
    @ObservedObject var controller: RecordingController
    @Environment(\.openWindow) private var openWindow

    @State private var pendingDiscard: RecoverableRecording?

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            HLine()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if controller.firstRunNoticeNeeded {
                        Callout(
                            systemImage: "lock.shield",
                            text: "Audio is transcribed on this Mac. Text is sent to your model gateway for notes.",
                            title: "Before your first meeting"
                        ) {
                            TextAction(title: "Continue", prominent: true) { controller.acknowledgeFirstRunNotice() }
                        }
                    }

                    ForEach(controller.recoverable) { item in
                        recoveryCallout(item)
                    }

                    meeting

                    notices

                    notesEditor

                    if !controller.log.isEmpty {
                        detailsSection
                    }
                }
                .padding(16)
            }
            .scrollContentBackground(.hidden)

            HLine()
            controlBar
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            HLine()
            footer
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
        .frame(width: 400, height: 560)
        .background(Ink.surface)
        .foregroundStyle(Ink.ink)
        .preferredColorScheme(.dark)
        .onAppear {
            controller.refreshPermissions()
            if controller.endpointStatus == nil {
                controller.testEndpoint()
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            controller.refreshPermissions()
        }
        .confirmationDialog(
            "Delete this recording?",
            isPresented: Binding(
                get: { pendingDiscard != nil },
                set: { if !$0 { pendingDiscard = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete the recording", role: .destructive) {
                if let item = pendingDiscard { controller.discard(item) }
                pendingDiscard = nil
            }
            Button("Cancel", role: .cancel) { pendingDiscard = nil }
        } message: {
            Text("The audio and the notes typed for it are removed. This cannot be undone.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.ui(13, weight: .semibold))
                .foregroundStyle(Ink.accentDeep)
            Text("Minutes")
                .font(.ui(15, weight: .semibold))
                .foregroundStyle(Ink.ink)
            Spacer()
            statePill
        }
    }

    /// What the app is doing, in two words, where the eye lands first.
    @ViewBuilder
    private var statePill: some View {
        if controller.isRecording {
            HStack(spacing: 5) {
                Circle().fill(Color.red).frame(width: 6, height: 6)
                Text("REC").font(.ui(Size.tiny, weight: .bold)).tracking(0.8)
            }
            .foregroundStyle(Color.red)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.red.opacity(0.14)))
            .accessibilityLabel("Recording")
        }
    }

    // MARK: - The meeting

    private var meeting: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("", text: $controller.draft.title, prompt: Text("Untitled meeting").foregroundStyle(Ink.faint))
                .textFieldStyle(.plain)
                .font(.title(22))
                .foregroundStyle(Ink.ink)
                .disabled(controller.phase == .starting || controller.phase.isBusy)

            if !controller.isRecording {
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 6, height: 6)
                    Text(controller.statusLine)
                        .font(.ui(Size.small))
                        .foregroundStyle(controller.userError == nil ? Ink.muted : Ink.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var statusColor: Color {
        if controller.userError != nil || controller.microphoneBlocked { return Ink.warn }
        if !controller.writingUp.isEmpty { return Ink.accentDeep }
        return Ink.faint
    }

    @ViewBuilder
    private var notices: some View {
        if controller.microphoneBlocked {
            Callout(
                systemImage: "mic.slash.fill",
                text: "minutes cannot hear your microphone until macOS allows it.",
                title: "Microphone blocked", tone: .problem
            ) {
                HStack(spacing: 14) {
                    TextAction(title: "Open Microphone Settings", prominent: true) {
                        controller.openMicrophoneSettings()
                    }
                    TextAction(title: "Recheck") { controller.refreshPermissions() }
                }
            }
        }
        if controller.isRecording, controller.microphoneStarved || controller.capturedSilence {
            Callout(systemImage: "mic.badge.xmark", text: controller.statusLine, tone: .warning)
        }
        if controller.isRecording, let notice = controller.systemAudioNotice {
            Callout(systemImage: "speaker.slash", text: notice, title: "No system audio yet", tone: .warning)
        }
        if !controller.modelReady && !controller.isRecording {
            Callout(
                systemImage: "arrow.down.circle",
                text: "The speech model runs on this Mac. It is downloaded once.",
                title: "Speech model not downloaded", tone: .warning
            ) {
                TextAction(title: "Open Settings", prominent: true) { openSettings() }
            }
        }
    }

    private var notesEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                PaneLabel(text: "Your notes")
                Spacer()
                Text("Kept word for word")
                    .font(.ui(Size.tiny))
                    .foregroundStyle(Ink.faint)
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $controller.draft.bullets)
                    .font(.ui(14))
                    .foregroundStyle(Ink.ink)
                    .scrollContentBackground(.hidden)
                    .disabled(controller.phase == .starting || controller.phase.isBusy)
                if controller.draft.bullets.isEmpty {
                    Text("Write the points you care about. They steer the notes; the transcript is the evidence.")
                        .font(.ui(14))
                        .foregroundStyle(Ink.faint)
                        .padding(.horizontal, 5)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 150)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Ink.panel)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Ink.line)))
        }
    }

    private func recoveryCallout(_ item: RecoverableRecording) -> some View {
        Callout(
            systemImage: "waveform.badge.exclamationmark",
            text:
                "\(item.manifest.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(Timecode.string(from: item.duration)) of audio and your notes were kept.",
            title: item.manifest.title.isEmpty ? "A recording was not written up" : item.manifest.title,
            tone: .warning
        ) {
            HStack(spacing: 14) {
                TextAction(title: "Write it up", prominent: true) { controller.recover(item) }
                TextAction(title: "Delete…") { pendingDiscard = item }
            }
        }
    }

    private var detailsSection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(controller.log.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.ui(Size.tiny))
                        .foregroundStyle(Ink.faint)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .padding(.top, 4)
        } label: {
            Text("Details")
                .font(.ui(Size.small))
                .foregroundStyle(Ink.faint)
        }
        .tint(Ink.faint)
    }

    // MARK: - The control bar

    @ViewBuilder
    private var controlBar: some View {
        if controller.isRecording {
            HStack(spacing: 12) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(controller.capturedSilence ? Ink.warn : Color.red)
                        .frame(width: 8, height: 8)
                    Text(Timecode.string(from: controller.elapsed))
                        .font(.mono(13))
                        .monospacedDigit()
                        .foregroundStyle(Ink.ink)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Recording for \(Timecode.string(from: controller.elapsed))")

                Spacer(minLength: 4)

                trackLevel("You", controller.level, color: Ink.accentDeep, active: !controller.microphoneStarved)
                trackLevel(
                    "Others", controller.systemLevel, color: Ink.them,
                    active: !controller.systemAudioStarved && controller.systemAudioNotice == nil)

                Button {
                    controller.toggleRecording()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "stop.fill").font(.system(size: 10))
                        Text("Stop").font(.ui(13, weight: .semibold))
                    }
                    .foregroundStyle(Ink.bg)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Ink.ink))
                }
                .buttonStyle(.plain)
                .keyboardShortcut("r")
                .help("Stop both tracks and write the meeting up (⌘R)")
            }
        } else {
            Button {
                controller.toggleRecording()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "circle.fill").font(.ui(11))
                    Text(controller.phase == .starting ? "Starting…" : "Record")
                        .font(.ui(14, weight: .semibold))
                    Spacer().frame(width: 2)
                    Text("⌘R").font(.ui(Size.tiny)).opacity(0.65)
                }
                .foregroundStyle(Ink.accentInk)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Ink.accent))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("r")
            .disabled(controller.phase == .starting || controller.phase.isBusy)
            .opacity(controller.phase == .starting || controller.phase.isBusy ? 0.45 : 1)
            .help("Record your microphone and what this Mac plays (⌘R)")
        }
    }

    private func trackLevel(_ name: String, _ level: Float, color: Color, active: Bool) -> some View {
        HStack(spacing: 5) {
            Text(name)
                .font(.ui(Size.tiny, weight: .medium))
                .foregroundStyle(active ? Ink.muted : Ink.warn)
            LevelBars(level: level, color: color, active: active)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) level")
        .accessibilityValue(active ? "\(Int((min(1, level) * 100).rounded())) percent" : "no audio")
    }

    // MARK: - Footer

    private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: "settings")
    }

    private var footer: some View {
        HStack(spacing: 2) {
            footerButton(icon: "rectangle.stack", title: "Meetings") {
                // An accessory app has no dock icon, so a window it opens has
                // to be brought forward by hand.
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: MinutesWindow.library)
            }
            footerButton(
                icon: "folder", title: controller.lastMeetingURL == nil ? "Notes folder" : "Last meeting",
                labelVisible: false
            ) { controller.openNotesFolder() }

            Spacer()

            footerButton(icon: "gearshape", title: "Settings", labelVisible: false) { openSettings() }
                .keyboardShortcut(",")
            footerButton(icon: "power", title: "Quit", labelVisible: false) {
                NSApplication.shared.terminate(nil)
            }
            .disabled(controller.isRecording)
            .help(controller.isRecording ? "Stop the recording before quitting" : "Quit")
        }
    }

    private func footerButton(
        icon: String, title: String, labelVisible: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.ui(Size.small))
                if labelVisible {
                    Text(title).font(.ui(Size.small))
                }
            }
            .foregroundStyle(Ink.muted)
            .padding(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
    }
}
