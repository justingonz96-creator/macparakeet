import CoreAudio
import Foundation
import OSLog

public final class AudioProcessActivityCollector: @unchecked Sendable {
    public typealias SnapshotHandler = @Sendable (ProcessAudioSnapshot) -> Void

    private struct ProcessListener {
        let objectID: AudioObjectID
        let selector: AudioObjectPropertySelector
        let block: AudioObjectPropertyListenerBlock
    }

    private let logger = Logger(subsystem: "com.macparakeet.core", category: "AudioProcessActivityCollector")
    private let lock = NSLock()
    private let listenerQueue = DispatchQueue(label: "com.macparakeet.audio-process-activity")
    private let selfProcessID: Int32
    private let selfBundleID: String?

    private var snapshotHandler: SnapshotHandler?
    private var processListListener: AudioObjectPropertyListenerBlock?
    private var processListeners: [ProcessListener] = []

    public init(
        selfProcessID: Int32 = getpid(),
        selfBundleID: String? = Bundle.main.bundleIdentifier
    ) {
        self.selfProcessID = selfProcessID
        self.selfBundleID = selfBundleID
    }

    deinit {
        stop()
    }

    public func start(handler: @escaping SnapshotHandler) {
        let processObjectIDs = Self.processObjectIDs()
        lock.withLock {
            snapshotHandler = handler
            installProcessListListenerLocked()
            refreshProcessListenersLocked(processObjectIDs: processObjectIDs)
        }
        emitCurrentSnapshot()
    }

    public func stop() {
        lock.withLock {
            removeProcessListenersLocked()
            removeProcessListListenerLocked()
            snapshotHandler = nil
        }
    }

    public func snapshot() -> ProcessAudioSnapshot {
        Self.currentSnapshot(
            selfProcessID: selfProcessID,
            selfBundleID: selfBundleID
        )
    }

    public static func currentSnapshot(
        selfProcessID: Int32 = getpid(),
        selfBundleID: String? = Bundle.main.bundleIdentifier
    ) -> ProcessAudioSnapshot {
        let processes = processObjectIDs().compactMap(processActivity)
        return ProcessAudioSnapshot(
            processes: filterSelf(
                processes: processes,
                selfProcessID: selfProcessID,
                selfBundleID: selfBundleID
            )
        )
    }

    public static func filterSelf(
        processes: [AudioProcessActivity],
        selfProcessID: Int32,
        selfBundleID: String?
    ) -> [AudioProcessActivity] {
        processes.filter { process in
            if process.pid == selfProcessID {
                return false
            }
            if let selfBundleID, process.bundleID == selfBundleID {
                return false
            }
            return true
        }
    }

    private func handleProcessListChanged() {
        let processObjectIDs = Self.processObjectIDs()
        lock.withLock {
            refreshProcessListenersLocked(processObjectIDs: processObjectIDs)
        }
        emitCurrentSnapshot()
    }

    private func emitCurrentSnapshot() {
        let snapshot = snapshot()
        let handler = lock.withLock { snapshotHandler }
        handler?(snapshot)
    }

    private func installProcessListListenerLocked() {
        guard processListListener == nil else { return }
        var address = Self.address(selector: kAudioHardwarePropertyProcessObjectList)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleProcessListChanged()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            listenerQueue,
            block
        )
        guard status == noErr else {
            logger.debug("audio_process_list_listener_failed status=\(status)")
            return
        }
        processListListener = block
    }

    private func removeProcessListListenerLocked() {
        guard let block = processListListener else { return }
        var address = Self.address(selector: kAudioHardwarePropertyProcessObjectList)
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            listenerQueue,
            block
        )
        processListListener = nil
    }

    private func refreshProcessListenersLocked(processObjectIDs: [AudioObjectID]) {
        removeProcessListenersLocked()

        for objectID in processObjectIDs {
            installProcessListenerLocked(objectID: objectID, selector: kAudioProcessPropertyIsRunningInput)
            installProcessListenerLocked(objectID: objectID, selector: kAudioProcessPropertyIsRunningOutput)
        }
    }

    private func installProcessListenerLocked(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) {
        var address = Self.address(selector: selector)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.emitCurrentSnapshot()
        }
        let status = AudioObjectAddPropertyListenerBlock(objectID, &address, listenerQueue, block)
        guard status == noErr else { return }
        processListeners.append(ProcessListener(objectID: objectID, selector: selector, block: block))
    }

    private func removeProcessListenersLocked() {
        for listener in processListeners {
            var address = Self.address(selector: listener.selector)
            AudioObjectRemovePropertyListenerBlock(
                listener.objectID,
                &address,
                listenerQueue,
                listener.block
            )
        }
        processListeners.removeAll()
    }

    private static func processObjectIDs() -> [AudioObjectID] {
        var address = address(selector: kAudioHardwarePropertyProcessObjectList)
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )
        guard status == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }

        var objectIDs = [AudioObjectID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &objectIDs
        )
        guard status == noErr else { return [] }
        return objectIDs.filter { $0 != kAudioObjectUnknown }
    }

    private static func processActivity(objectID: AudioObjectID) -> AudioProcessActivity? {
        guard let pid = processID(objectID: objectID) else { return nil }
        return AudioProcessActivity(
            pid: pid,
            bundleID: bundleID(objectID: objectID),
            isRunningInput: boolProperty(objectID: objectID, selector: kAudioProcessPropertyIsRunningInput),
            isRunningOutput: boolProperty(objectID: objectID, selector: kAudioProcessPropertyIsRunningOutput)
        )
    }

    private static func processID(objectID: AudioObjectID) -> Int32? {
        var address = address(selector: kAudioProcessPropertyPID)
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &pid)
        guard status == noErr else { return nil }
        return Int32(pid)
    }

    private static func bundleID(objectID: AudioObjectID) -> String? {
        var address = address(selector: kAudioProcessPropertyBundleID)
        var bundleID: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &bundleID)
        guard status == noErr, let bundleID else { return nil }
        return bundleID.takeRetainedValue() as String
    }

    private static func boolProperty(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) -> Bool {
        var address = address(selector: selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value)
        guard status == noErr else { return false }
        return value != 0
    }

    private static func address(selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
