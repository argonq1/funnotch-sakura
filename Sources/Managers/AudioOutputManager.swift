import AppKit
import CoreAudio
import SwiftUI

@MainActor
final class AudioOutputManager: ObservableObject {
    struct Device: Identifiable, Equatable {
        let id: AudioDeviceID
        let name: String
    }
    static let shared = AudioOutputManager()
    @Published private(set) var devices: [Device] = []
    @Published private(set) var selected: AudioDeviceID = 0
    @Published private(set) var error: String?
    private var listener: AudioObjectPropertyListenerBlock?

    func start() {
        guard listener == nil else { return }
        let callback: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        listener = callback
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, callback)
        }
        refresh()
    }

    func refresh() {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return }
        guard size > 0 else { devices = []; return }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let status = ids.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else { return }
        let outputs = ids.compactMap { id -> Device? in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var bytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &bytes) == noErr, bytes > 0 else { return nil }
            var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let status = withUnsafeMutablePointer(to: &name) { pointer in
                AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, pointer)
            }
            guard status == noErr, let value = name?.takeRetainedValue() else { return nil }
            return Device(id: id, name: value as String)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if outputs != devices { devices = outputs }
        address.mSelector = kAudioHardwarePropertyDefaultOutputDevice
        var output: AudioDeviceID = 0
        size = UInt32(MemoryLayout<AudioDeviceID>.size)
        if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &output) == noErr { selected = output }
    }

    func select(_ device: Device) {
        guard devices.contains(device) else { return }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = device.id
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id)
        error = status == noErr ? nil : "Не удалось переключить аудиовыход. Проверь подключение устройства."
        refresh()
    }
}

struct AudioOutputMenu: View {
    @ObservedObject private var audio = AudioOutputManager.shared
    var body: some View {
        Menu {
            ForEach(audio.devices) { device in
                Button { audio.select(device) } label: {
                    Label(device.name, systemImage: audio.selected == device.id ? "checkmark" : "speaker.wave.2")
                }
            }
            if audio.devices.isEmpty { Text("Нет доступных аудиовыходов") }
            if let error = audio.error { Text(error) }
        } label: {
            Image(systemName: "speaker.wave.2").font(.system(size: 11, weight: .medium))
                .frame(width: 24, height: 24).contentShape(Circle())
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Аудиовыход").accessibilityLabel("Выбрать устройство звука")
        .onAppear { if !Motion.snapshotMode { audio.start() } }
    }
}
