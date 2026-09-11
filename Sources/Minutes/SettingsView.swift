import MinutesCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var controller: RecordingController

    var body: some View {
        Form {
            Section("Connection") {
                TextField("Endpoint", text: $controller.settings.notesBaseURL)
                    .disabled(controller.settingsLocked)
                    .onSubmit { controller.saveSettings() }

                TextField("Model", text: $controller.settings.notesModel)
                    .disabled(controller.settingsLocked)
                    .onSubmit { controller.saveSettings() }

                SecureField("API key (optional)", text: $controller.apiKeyField)
                    .disabled(controller.settingsLocked)
                HStack {
                    Button("Save key") { controller.saveAPIKey() }
                        .disabled(controller.settingsLocked)
                    Button("Test connection") { controller.testEndpoint() }
                        .disabled(controller.settingsLocked || controller.isTestingEndpoint)
                    if controller.isTestingEndpoint {
                        ProgressView().controlSize(.small)
                    }
                }

                if let status = controller.endpointStatus {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }

                ForEach(controller.settings.problems, id: \.self) { problem in
                    Text(problem).font(.caption).foregroundStyle(.orange)
                }

                HStack {
                    Button("Save") { controller.saveSettings() }
                        .buttonStyle(.borderedProminent)
                        .disabled(controller.settingsLocked || !controller.settings.problems.isEmpty)
                    if controller.settingsLocked {
                        ProgressView().controlSize(.small)
                    }
                }
                if let message = controller.settingsMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Microphone") {
                switch controller.microphonePermission {
                case .granted:
                    Text("Allowed").font(.caption).foregroundStyle(.secondary)
                case .undetermined:
                    Text("Not requested").font(.caption).foregroundStyle(.secondary)
                case .denied, .restricted:
                    Text("Access blocked").font(.caption).foregroundStyle(.secondary)
                default:
                    EmptyView()
                }
                if controller.microphoneBlocked {
                    HStack {
                        Button("Open settings") { controller.openMicrophoneSettings() }
                        Button("Recheck") { controller.refreshPermissions() }
                    }
                }
            }

            Section("Transcription") {
                Picker("Model", selection: $controller.settings.asrModel) {
                    ForEach(ASRModelChoice.allCases, id: \.self) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                .disabled(controller.settingsLocked || controller.modelDownloadProgress != nil)
                .onChange(of: controller.settings.asrModel) { _ in controller.saveSettings() }

                if let progress = controller.modelDownloadProgress {
                    ProgressView(value: progress)
                    Text("Downloading…").font(.caption2).foregroundStyle(.secondary)
                } else if controller.modelReady {
                    Text("Ready").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Button("Download model") { controller.downloadModel() }
                        .disabled(controller.settingsLocked)
                }
            }

            Section("Storage") {
                HStack {
                    Text(controller.settings.notesFolderPath)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer()
                    Button("Choose") { controller.chooseNotesFolder() }
                        .disabled(controller.settingsLocked)
                }
                if let warning = controller.syncWarning {
                    Text(warning).font(.caption).foregroundStyle(.orange)
                }
                Toggle(
                    "Keep audio",
                    isOn: $controller.settings.keepAudioAfterTranscription
                )
                .disabled(controller.settingsLocked)
                .onChange(of: controller.settings.keepAudioAfterTranscription) { _ in
                    controller.saveSettings()
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Ink.surface)
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .tint(Ink.accentDeep)
        .frame(width: 480, height: 550)
    }
}
