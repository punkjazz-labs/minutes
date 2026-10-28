import AudioToolbox
import CoreAudio
import Foundation

/// The few Core Audio property reads the tap needs, in one place.
///
/// Core Audio is a C API with an out-parameter for everything, and the tap code
/// below reads half a dozen properties. Reading them through these helpers
/// keeps the tap itself readable and keeps every status code checked.
enum CoreAudioObject {

    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = AudioObjectID(kAudioObjectUnknown)

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
    }

    /// Reads a fixed-size property value.
    static func read<Value>(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        default fallback: Value
    ) throws -> Value {
        var propertyAddress = address(selector)
        var size = UInt32(MemoryLayout<Value>.size)
        var value = fallback
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &propertyAddress, 0, nil, &size, pointer)
        }
        guard status == noErr else {
            throw CoreAudioFailure(what: "read property \(fourCharacters(selector))", status: status)
        }
        return value
    }

    static func readString(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector
    ) throws -> String {
        let value: CFString = try read(objectID, selector, default: "" as CFString)
        return value as String
    }

    /// Reads a property that takes a qualifier, which is how a process ID is
    /// turned into the audio object that represents that process.
    static func read<Value, Qualifier>(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        qualifier: Qualifier,
        default fallback: Value
    ) throws -> Value {
        var propertyAddress = address(selector)
        var qualifierValue = qualifier
        let qualifierSize = UInt32(MemoryLayout<Qualifier>.size)
        var size = UInt32(MemoryLayout<Value>.size)
        var value = fallback
        let status = withUnsafeMutablePointer(to: &qualifierValue) { qualifierPointer in
            withUnsafeMutablePointer(to: &value) { pointer in
                AudioObjectGetPropertyData(objectID, &propertyAddress, qualifierSize, qualifierPointer, &size, pointer)
            }
        }
        guard status == noErr else {
            throw CoreAudioFailure(what: "read property \(fourCharacters(selector))", status: status)
        }
        return value
    }

    /// The device macOS is currently playing through. This is the device the
    /// aggregate has to use as its main sub-device.
    static func defaultOutputDevice() throws -> AudioObjectID {
        try read(system, kAudioHardwarePropertyDefaultSystemOutputDevice, default: unknown)
    }

    static func deviceUID(_ deviceID: AudioObjectID) throws -> String {
        try readString(deviceID, kAudioDevicePropertyDeviceUID)
    }

    static func deviceName(_ deviceID: AudioObjectID) -> String {
        (try? readString(deviceID, kAudioObjectPropertyName)) ?? "the output device"
    }

    /// The audio object that stands for a running process, which is what the
    /// tap description wants in its exclusion list.
    static func processObject(forPID pid: pid_t) throws -> AudioObjectID {
        let objectID: AudioObjectID = try read(
            system,
            kAudioHardwarePropertyTranslatePIDToProcessObject,
            qualifier: pid,
            default: unknown)
        guard objectID != unknown else {
            throw CoreAudioFailure(what: "find the audio object for this process", status: kAudioHardwareBadObjectError)
        }
        return objectID
    }

    static func tapStreamDescription(_ tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        try read(tapID, kAudioTapPropertyFormat, default: AudioStreamBasicDescription())
    }

    static func fourCharacters(_ value: UInt32) -> String {
        let bytes = [
            UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
        ]
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// A Core Audio call that failed, with the status code kept so a report can say
/// which call it was rather than guessing.
struct CoreAudioFailure: Error, LocalizedError {
    let what: String
    let status: OSStatus

    var errorDescription: String? {
        "Core Audio could not \(what) (status \(status), \(CoreAudioObject.fourCharacters(UInt32(bitPattern: status))))."
    }
}

/// Watches which device macOS plays through, and the sample rate it plays at,
/// because both change under a running meeting and the aggregate device has to
/// be rebuilt around the change.
///
/// AirPods connecting changes the device. A call switching a Bluetooth headset
/// into its call mode keeps the device and changes its sample rate, and the
/// tap's format was read when the tap was built, so that needs a rebuild too.
final class DefaultOutputDeviceWatcher: @unchecked Sendable {

    enum Change: Sendable {
        case device
        case sampleRate
    }

    private let queue: DispatchQueue
    /// The rate listener moves on the watcher's queue while a stop can arrive
    /// from the main thread, so the rate state is only touched under this.
    private let rateLock = NSLock()
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var rateListener: AudioObjectPropertyListenerBlock?
    private var rateDevice = CoreAudioObject.unknown
    private var deviceAddress = CoreAudioObject.address(kAudioHardwarePropertyDefaultSystemOutputDevice)
    private var rateAddress = CoreAudioObject.address(kAudioDevicePropertyNominalSampleRate)
    private var onChange: (@Sendable (Change) -> Void)?

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    /// Calls `onChange` on the watcher's queue whenever the default output
    /// device or its sample rate changes. Returns false when macOS refused the
    /// device listener, so the caller can say so rather than assume it is being
    /// watched. A refused rate listener is not fatal: the device listener and
    /// the level checks still run.
    @discardableResult
    func start(onChange: @escaping @Sendable (Change) -> Void) -> Bool {
        guard deviceListener == nil else { return true }
        self.onChange = onChange
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.watchRate()
            onChange(.device)
        }
        let status = AudioObjectAddPropertyListenerBlock(
            CoreAudioObject.system, &deviceAddress, queue, block)
        guard status == noErr else { return false }
        deviceListener = block
        watchRate()
        return true
    }

    /// Moves the rate listener to whichever device is the default now.
    /// Runs on the watcher's queue, or before the device listener exists.
    private func watchRate() {
        rateLock.lock()
        defer { rateLock.unlock() }
        stopWatchingRateLocked()
        guard let device = try? CoreAudioObject.defaultOutputDevice(), device != CoreAudioObject.unknown,
            let onChange
        else { return }
        let block: AudioObjectPropertyListenerBlock = { _, _ in onChange(.sampleRate) }
        guard AudioObjectAddPropertyListenerBlock(device, &rateAddress, queue, block) == noErr else { return }
        rateListener = block
        rateDevice = device
    }

    private func stopWatchingRateLocked() {
        guard let rateListener else { return }
        AudioObjectRemovePropertyListenerBlock(rateDevice, &rateAddress, queue, rateListener)
        self.rateListener = nil
        rateDevice = CoreAudioObject.unknown
    }

    func stop() {
        rateLock.lock()
        stopWatchingRateLocked()
        onChange = nil
        rateLock.unlock()
        guard let deviceListener else { return }
        AudioObjectRemovePropertyListenerBlock(
            CoreAudioObject.system, &deviceAddress, queue, deviceListener)
        self.deviceListener = nil
    }

    deinit { stop() }
}
