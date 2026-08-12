import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Whatever is feeding the system audio track. The real one is a Core Audio
/// process tap; the checks use a fake, which is why this protocol exists at
/// all. No check needs a permission grant or a sound card.
public protocol SystemAudioSource: AnyObject {

    /// The device being listened to, named for the activity log.
    var outputDeviceName: String { get }

    /// Starts feeding buffers. The handler is called on an audio thread.
    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws

    /// Tears everything down. Safe to call when nothing was started.
    func stop()
}

/// A Core Audio process tap on everything this Mac plays, minus this app.
///
/// The shape is fixed by the platform and every part of it matters:
///
/// - The aggregate device uses the real output device as its main sub-device
///   and carries the tap as a sub-tap. An aggregate with the tap as its main
///   device and no sub-devices produces silence and no error at all.
/// - `kAudioAggregateDeviceTapAutoStartKey` is true, and the aggregate is
///   private, which that key requires.
/// - The IO proc is created with `AudioDeviceCreateIOProcIDWithBlock`, because
///   `AVAudioEngine` cannot be pointed at an arbitrary HAL device.
///
/// This is a tap, not a reroute: the owner keeps hearing the meeting.
///
/// Written against the API usage in insidegui/AudioCap, which is BSD-2.
public final class CoreAudioProcessTap: SystemAudioSource, @unchecked Sendable {

    private let ioQueue: DispatchQueue
    private var tapID = CoreAudioObject.unknown
    private var aggregateID = CoreAudioObject.unknown
    private var procID: AudioDeviceIOProcID?
    private var format: AVAudioFormat?
    private var deviceName = "the output device"

    public init(ioQueue: DispatchQueue = DispatchQueue(label: "minutes.system-audio.io", qos: .userInitiated)) {
        self.ioQueue = ioQueue
    }

    public var outputDeviceName: String { deviceName }

    /// The format the tap delivers, known only once it exists.
    public var tapFormat: AVAudioFormat? { format }

    public func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        stop()

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excludedProcesses())
        description.name = "minutes meeting tap"
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        // A private tap is visible only to this process, and the auto-start key
        // on the aggregate requires it.
        description.isPrivate = true

        var createdTapID = CoreAudioObject.unknown
        let tapStatus = AudioHardwareCreateProcessTap(description, &createdTapID)
        guard tapStatus == noErr, createdTapID != CoreAudioObject.unknown else {
            throw CoreAudioFailure(what: "create the system audio tap", status: tapStatus)
        }
        tapID = createdTapID

        var streamDescription = try CoreAudioObject.tapStreamDescription(tapID)
        guard let tapFormat = AVAudioFormat(streamDescription: &streamDescription) else {
            stop()
            throw CoreAudioFailure(what: "read the format the tap delivers", status: kAudioHardwareUnspecifiedError)
        }
        format = tapFormat

        let outputDeviceID = try CoreAudioObject.defaultOutputDevice()
        let outputUID = try CoreAudioObject.deviceUID(outputDeviceID)
        deviceName = CoreAudioObject.deviceName(outputDeviceID)

        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "minutes meeting aggregate",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            // The real output device is the main sub-device and the time base.
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                ]
            ],
        ]

        var createdAggregateID = CoreAudioObject.unknown
        let aggregateStatus = AudioHardwareCreateAggregateDevice(
            composition as CFDictionary, &createdAggregateID)
        guard aggregateStatus == noErr, createdAggregateID != CoreAudioObject.unknown else {
            stop()
            throw CoreAudioFailure(what: "create the aggregate device around the tap", status: aggregateStatus)
        }
        aggregateID = createdAggregateID

        var createdProcID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&createdProcID, aggregateID, ioQueue) {
            _, inputData, _, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: tapFormat, bufferListNoCopy: inputData, deallocator: nil)
            else { return }
            onBuffer(buffer)
        }
        guard procStatus == noErr, let createdProcID else {
            stop()
            throw CoreAudioFailure(what: "attach a reader to the aggregate device", status: procStatus)
        }
        procID = createdProcID

        let startStatus = AudioDeviceStart(aggregateID, createdProcID)
        guard startStatus == noErr else {
            stop()
            throw CoreAudioFailure(what: "start the aggregate device", status: startStatus)
        }
    }

    public func stop() {
        if aggregateID != CoreAudioObject.unknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = CoreAudioObject.unknown
        }
        procID = nil

        if tapID != CoreAudioObject.unknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = CoreAudioObject.unknown
        }
        format = nil
    }

    deinit { stop() }

    /// This app's own audio, so a notification sound from minutes never lands
    /// in the recording of the other side. minutes plays nothing today, and
    /// excluding it anyway costs nothing and stops that from becoming a bug.
    private func excludedProcesses() -> [AudioObjectID] {
        guard let objectID = try? CoreAudioObject.processObject(forPID: getpid()) else { return [] }
        return [objectID]
    }
}
