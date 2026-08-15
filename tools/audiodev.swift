// 検証用: 入力デバイスの一覧表示と切り替え
// 使い方: audiodev            → 一覧と現在の既定入力
//        audiodev <deviceID> → その ID を既定入力に設定
import CoreAudio
import Foundation

let system = AudioObjectID(kAudioObjectSystemObject)

func address(_ s: AudioObjectPropertySelector,
             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
    -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: s, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func name(_ id: AudioDeviceID) -> String {
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var a = address(kAudioObjectPropertyName)
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr,
          let n = value?.takeRetainedValue() else { return "unknown" }
    return n as String
}

func transport(_ id: AudioDeviceID) -> String {
    var v: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    var a = address(kAudioDevicePropertyTransportType)
    AudioObjectGetPropertyData(id, &a, 0, nil, &size, &v)
    switch v {
    case kAudioDeviceTransportTypeBuiltIn: return "Built-in"
    case kAudioDeviceTransportTypeBluetooth: return "Bluetooth"
    case kAudioDeviceTransportTypeUSB: return "USB"
    case kAudioDeviceTransportTypeVirtual: return "Virtual"
    default: return "other(\(v))"
    }
}

func hasInput(_ id: AudioDeviceID) -> Bool {
    var a = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return false }
    let buf = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                               alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { buf.deallocate() }
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, buf) == noErr else { return false }
    let list = UnsafeMutableAudioBufferListPointer(buf.assumingMemoryBound(to: AudioBufferList.self))
    return list.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
}

func currentInput() -> AudioDeviceID {
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var a = address(kAudioHardwarePropertyDefaultInputDevice)
    AudioObjectGetPropertyData(system, &a, 0, nil, &size, &id)
    return id
}

if CommandLine.arguments.count > 1, let target = AudioDeviceID(CommandLine.arguments[1]) {
    var v = target
    var a = address(kAudioHardwarePropertyDefaultInputDevice)
    let st = AudioObjectSetPropertyData(system, &a, 0, nil,
                                        UInt32(MemoryLayout<AudioDeviceID>.size), &v)
    print("set input -> \(target) (\(name(target))) status=\(st)")
    exit(st == noErr ? 0 : 1)
}

var a = address(kAudioHardwarePropertyDevices)
var size: UInt32 = 0
AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size)
var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids)

func uid(_ id: AudioDeviceID) -> String {
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var a = address(kAudioDevicePropertyDeviceUID)
    guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &value) == noErr,
          let u = value?.takeRetainedValue() else { return "-" }
    return u as String
}

let cur = currentInput()
print("既定入力: \(cur) \(name(cur)) [\(transport(cur))]")
print("--- 入力を持つデバイス ---")
for id in ids where hasInput(id) {
    print("\(id)\t\(transport(id))\t\(name(id))\(id == cur ? "  <= 現在" : "")")
    print("\tUID: \(uid(id))")
}
