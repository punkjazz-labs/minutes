import MinutesCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var controller: RecordingController

    var body: some View {
        Form {
            Section("Notes") {
                TextField("Endpoint", text: $controller.settings.notesBaseURL)
                    .onSubmit { controller.saveSettings() }
                Text("An OpenAI-compatible base URL. The default is the LiteLLM gateway on this machine.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                TextField("Model", text: $controller.settings.notesModel)
                    .onSubmit { controller.saveSettings() }
                Text("A profile alias such as profile/general, so the app does not depend on which model is behind it.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                SecureField("API key", text: $controller.apiKeyField)
                HStack {
                    Button("Save key to keychain") { controller.saveAPIKey() }
                    Button("Test endpoint") { controller.testEndpoint() }
                }
                Text("Leave the key empty for a local gateway that does not check it. minutes then sends a documented non-secret placeholder.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if let status = controller.endpointStatus {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Speech") {
                Picker("Model", selection: $controller.settings.asrModel) {
                    ForEach(ASRModelChoice.allCases, id: \.self) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                .onChange(of: controller.settings.asrModel) { _, _ in controller.saveSettings() }

                if let progress = controller.modelDownloadProgress {
                    ProgressView(value: progress)
                    Text("Downloading the speech model.").font(.caption2).foregroundStyle(.secondary)
                } else if controller.modelReady {
                    Text("The model is on this Mac. Transcription runs offline.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Download the speech model") { controller.downloadModel() }
                    Text("A few hundred megabytes, fetched once from Hugging Face.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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
                }
                if let warning = controller.syncWarning {
                    Text(warning).font(.caption).foregroundStyle(.orange)
                }
                Toggle("Keep the audio after transcription", isOn: $controller.settings.keepAudioAfterTranscription)
                    .onChange(of: controller.settings.keepAudioAfterTranscription) { _, _ in controller.saveSettings() }
                Text("Off means the recording is deleted once the transcript exists. The transcript is what remains.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("What this build does") {
                Text("Microphone capture works. System audio, meaning the other people in the meeting, is not captured in v0.1.")
                    .font(.caption)
                Text(controller.privacyClaim)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 620)
        .onDisappear { controller.saveSettings() }
    }
}
