import CoreAudio
import Foundation
import os

// Bluetooth ヘッドセット（WH-1000XM6 等）を接続すると macOS が入力デバイスまで奪い、
// A2DP から HFP に落ちて出力音質まで劣化する。入力が Bluetooth 側に移ったら内蔵マイクへ戻す。
// USB マイクや連係マイクは対象外（Bluetooth のときだけ介入する）。

private let logger = Logger(subsystem: "com.tomato.mic-lock", category: "lock")
private let system = AudioObjectID(kAudioObjectSystemObject)

private func address(_ selector: AudioObjectPropertySelector,
                     _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
    -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector,
                               mScope: scope,
                               mElement: kAudioObjectPropertyElementMain)
}

private func defaultInputDevice() -> AudioDeviceID {
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var addr = address(kAudioHardwarePropertyDefaultInputDevice)
    AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &id)
    return id
}

@discardableResult
private func setDefaultInputDevice(_ id: AudioDeviceID) -> OSStatus {
    var value = id
    var addr = address(kAudioHardwarePropertyDefaultInputDevice)
    return AudioObjectSetPropertyData(system, &addr, 0, nil,
                                      UInt32(MemoryLayout<AudioDeviceID>.size), &value)
}

private func transportType(_ id: AudioDeviceID) -> UInt32 {
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    var addr = address(kAudioDevicePropertyTransportType)
    AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value)
    return value
}

private func deviceName(_ id: AudioDeviceID) -> String {
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var addr = address(kAudioObjectPropertyName)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr,
          let name = value?.takeRetainedValue() else { return "unknown" }
    return name as String
}

private func hasInputChannels(_ id: AudioDeviceID) -> Bool {
    var addr = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                  alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { buffer.deallocate() }
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, buffer) == noErr else { return false }
    let list = UnsafeMutableAudioBufferListPointer(buffer.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
}

private func builtInInputDevice() -> AudioDeviceID? {
    var addr = address(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return nil }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return nil }
    return ids.first { hasInputChannels($0) && transportType($0) == kAudioDeviceTransportTypeBuiltIn }
}

private func enforceBuiltInInput() {
    let current = defaultInputDevice()
    guard transportType(current) == kAudioDeviceTransportTypeBluetooth else { return }
    guard let builtIn = builtInInputDevice() else {
        logger.notice("内蔵マイクが見つからないため切り替えを見送った")
        return
    }
    let taken = deviceName(current)
    let status = setDefaultInputDevice(builtIn)
    if status == noErr {
        logger.notice("入力を \(taken, privacy: .public) から \(deviceName(builtIn), privacy: .public) へ戻した")
    } else {
        logger.notice("入力の切り替えに失敗した status=\(status)")
    }
}

// デフォルト入力の変更だけでなくデバイス一覧の変更も見る。
// Bluetooth 接続直後は「デバイス追加 → 少し遅れて入力が奪われる」順で起きることがあるため。
private var pending: DispatchWorkItem?
private func scheduleEnforce() {
    pending?.cancel()
    let work = DispatchWorkItem(block: enforceBuiltInInput)
    pending = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
}

var defaultInputAddress = address(kAudioHardwarePropertyDefaultInputDevice)
AudioObjectAddPropertyListenerBlock(system, &defaultInputAddress, DispatchQueue.main) { _, _ in
    enforceBuiltInInput()
}

var deviceListAddress = address(kAudioHardwarePropertyDevices)
AudioObjectAddPropertyListenerBlock(system, &deviceListAddress, DispatchQueue.main) { _, _ in
    scheduleEnforce()
}

logger.notice("mic-lock 起動 現在の入力=\(deviceName(defaultInputDevice()), privacy: .public)")
enforceBuiltInInput()
CFRunLoopRun()
