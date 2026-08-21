import AppKit
import CoreAudio
import Foundation
import os

// メニューバーから選んだマイクを既定入力に固定し続ける常駐アプリ。
//
// Bluetooth ヘッドセットを接続すると macOS は入力デバイスまで奪う。ヘッドセットのマイクが
// 既定入力になるとプロファイルが A2DP から HFP（ハンズフリー）に落ち、再生音質まで劣化する。
// 固定先を決めておけば、奪われても即座に戻る。

private let logger = Logger(subsystem: "com.tomato.mic-lock", category: "lock")
private let system = AudioObjectID(kAudioObjectSystemObject)
private let lockedUIDKey = "lockedInputDeviceUID"

// A2DP（音楽用）は 44.1kHz 以上。HFP（ハンズフリー）は 16kHz 以下に落ちる。
private let a2dpMinimumSampleRate: Double = 44100

// MARK: - CoreAudio

private func address(_ selector: AudioObjectPropertySelector,
                     _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
    -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector,
                               mScope: scope,
                               mElement: kAudioObjectPropertyElementMain)
}

// 取得に失敗したときの 0 を「実在するデバイス」として扱うと表示・判定が狂うので nil にする。
private func deviceID(for selector: AudioObjectPropertySelector) -> AudioDeviceID? {
    var id = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var addr = address(selector)
    guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &id) == noErr,
          id != kAudioObjectUnknown else { return nil }
    return id
}

private func defaultInputDevice() -> AudioDeviceID? {
    deviceID(for: kAudioHardwarePropertyDefaultInputDevice)
}

private func defaultOutputDevice() -> AudioDeviceID? {
    deviceID(for: kAudioHardwarePropertyDefaultOutputDevice)
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

private func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var addr = address(selector)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr,
          let result = value?.takeRetainedValue() else { return nil }
    return result as String
}

private func deviceName(_ id: AudioDeviceID?) -> String {
    guard let id, let name = stringProperty(id, kAudioObjectPropertyName) else { return "不明なデバイス" }
    return name
}

// AudioDeviceID は再接続で変わるため、固定先の永続化には UID を使う。
private func deviceUID(_ id: AudioDeviceID) -> String? {
    stringProperty(id, kAudioDevicePropertyDeviceUID)
}

// 失敗時の 0 をそのまま返すと「A2DP 未満＝音質低下」と誤判定されるため nil にする。
private func sampleRate(_ id: AudioDeviceID) -> Double? {
    var value: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
    var addr = address(kAudioDevicePropertyNominalSampleRate)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr, value > 0 else { return nil }
    return value
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

private func allDevices() -> [AudioDeviceID] {
    var addr = address(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}

private func inputDevices() -> [AudioDeviceID] {
    allDevices().filter(hasInputChannels)
}

private func device(forUID uid: String) -> AudioDeviceID? {
    inputDevices().first { deviceUID($0) == uid }
}

private func builtInInputDevice() -> AudioDeviceID? {
    inputDevices().first { transportType($0) == kAudioDeviceTransportTypeBuiltIn }
}

// MARK: - アプリ

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var pendingEnforce: DispatchWorkItem?

    /// 固定先デバイスの UID。nil は「固定しない」。
    private var lockedUID: String? {
        get {
            guard let stored = UserDefaults.standard.string(forKey: lockedUIDKey), !stored.isEmpty else { return nil }
            return stored
        }
        set { UserDefaults.standard.set(newValue ?? "", forKey: lockedUIDKey) }
    }

    private var hasStoredPreference: Bool {
        UserDefaults.standard.object(forKey: lockedUIDKey) != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 初回起動時は内蔵マイクを固定先にする（Bluetooth に奪われるのを防ぐのが主目的のため）。
        if !hasStoredPreference, let builtIn = builtInInputDevice() {
            lockedUID = deviceUID(builtIn)
        }

        // autosaveName が無いと macOS は配置位置を決められず、アイコンを画面外
        // （x = -4506 等）に置いてしまい一切表示されない。初回だけ既定位置も与える。
        let positionKey = "NSStatusItem Preferred Position mic-lock"
        if UserDefaults.standard.object(forKey: positionKey) == nil {
            UserDefaults.standard.set(500, forKey: positionKey)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "mic-lock"
        statusItem.isVisible = true
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        registerListeners()
        enforce()
        refreshStatusItem()

        logger.notice("mic-lock 起動 固定先=\(self.lockedDeviceDescription(), privacy: .public)")
    }

    // MARK: 固定の実行

    private func enforce() {
        guard let uid = lockedUID else { return }
        guard let target = device(forUID: uid) else { return } // 固定先が未接続なら何もしない
        guard let current = defaultInputDevice() else { return } // 現在の既定入力が読めないと比較できない
        guard current != target else { return }

        let takenBy = deviceName(current)
        let status = setDefaultInputDevice(target)
        if status == noErr {
            logger.notice("入力を \(takenBy, privacy: .public) から \(deviceName(target), privacy: .public) へ戻した")
        } else {
            logger.notice("入力の切り替えに失敗した status=\(status)")
        }
    }

    /// Bluetooth 接続直後は「デバイス追加 → 遅れて入力が奪われる」順で起きるため少し待って再判定する。
    private func scheduleEnforce() {
        pendingEnforce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.enforce()
            self?.refreshStatusItem()
        }
        pendingEnforce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func registerListeners() {
        // 登録に失敗するとアイコンは出るのに固定も表示更新も一切動かない。黙って壊れないよう必ず記録する。
        for selector in [kAudioHardwarePropertyDefaultInputDevice,
                         kAudioHardwarePropertyDefaultOutputDevice] {
            var addr = address(selector)
            let status = AudioObjectAddPropertyListenerBlock(system, &addr, DispatchQueue.main) { [weak self] _, _ in
                self?.enforce()
                self?.watchOutputSampleRate()
                self?.refreshStatusItem()
            }
            if status != noErr {
                logger.fault("既定デバイス変更の監視登録に失敗した selector=\(selector) status=\(status) 固定が働かない")
            }
        }
        var devicesAddr = address(kAudioHardwarePropertyDevices)
        let devicesStatus = AudioObjectAddPropertyListenerBlock(system, &devicesAddr, DispatchQueue.main) { [weak self] _, _ in
            self?.scheduleEnforce()
        }
        if devicesStatus != noErr {
            logger.fault("デバイス一覧変更の監視登録に失敗した status=\(devicesStatus) 接続時の再固定が働かない")
        }
        watchOutputSampleRate()
    }

    private var watchedOutputDevice: AudioDeviceID?
    private var sampleRateListener: AudioObjectPropertyListenerBlock?

    /// A2DP ⇄ HFP の遷移は既定出力デバイスの「変更」では通知されない（同じデバイスのまま
    /// サンプルレートだけ変わる）。そのデバイス自身のサンプルレートを監視する必要がある。
    private func watchOutputSampleRate() {
        guard let output = defaultOutputDevice() else { return }
        guard output != watchedOutputDevice else { return }

        var addr = address(kAudioDevicePropertyNominalSampleRate)
        if let previous = watchedOutputDevice, let listener = sampleRateListener {
            AudioObjectRemovePropertyListenerBlock(previous, &addr, DispatchQueue.main, listener)
        }
        // 登録に失敗したら「監視中」の状態を残さない（次回の解除が不整合になるため）
        watchedOutputDevice = nil
        sampleRateListener = nil

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refreshStatusItem()
        }
        let status = AudioObjectAddPropertyListenerBlock(output, &addr, DispatchQueue.main, listener)
        guard status == noErr else {
            logger.fault("出力サンプルレートの監視登録に失敗した status=\(status) 音質低下の表示が更新されない")
            return
        }
        watchedOutputDevice = output
        sampleRateListener = listener
    }

    // MARK: 音質の判定

    /// 既定出力が Bluetooth かつサンプルレートが A2DP 相当を下回る＝ハンズフリーに落ちている。
    /// デバイスやサンプルレートが取れないときは nil（判定不能）。取得失敗を「音質低下」と誤表示しないため。
    private var isHandsFreeDegraded: Bool? {
        guard let output = defaultOutputDevice() else { return nil }
        guard transportType(output) == kAudioDeviceTransportTypeBluetooth else { return false }
        guard let rate = sampleRate(output) else { return nil }
        return rate < a2dpMinimumSampleRate
    }

    private func outputSummary() -> String {
        guard let output = defaultOutputDevice() else { return "不明なデバイス" }
        let rate = sampleRate(output).map { String(format: "%.1fkHz", $0 / 1000) } ?? "kHz 不明"
        guard transportType(output) == kAudioDeviceTransportTypeBluetooth else {
            return "\(deviceName(output))  \(rate)"
        }
        let quality: String
        if let degraded = isHandsFreeDegraded {
            quality = degraded ? "ハンズフリー・音質低下" : "A2DP 高音質"
        } else {
            quality = "音質判定不能"
        }
        return "\(deviceName(output))  \(rate)  \(quality)"
    }

    private func lockedDeviceDescription() -> String {
        guard let uid = lockedUID else { return "固定しない" }
        if let id = device(forUID: uid) { return deviceName(id) }
        return "未接続のデバイス"
    }

    private func refreshStatusItem() {
        // --dump-menu ではステータス項目を作らずにメニューだけ組み立てる
        guard let statusItem else { return }

        // 四角囲みにしているのは、メニューバーに並ぶ他のマイクアイコン（voicekey・
        // macOS のマイク使用中インジケータ）と一目で見分けるため。
        let symbol: String
        if isHandsFreeDegraded == true {
            symbol = "exclamationmark.triangle.fill"
        } else if lockedUID == nil {
            symbol = "mic.square"
        } else {
            symbol = "mic.square.fill"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "mic-lock")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = "入力: \(deviceName(defaultInputDevice()))\n出力: \(outputSummary())"
    }

    // MARK: メニュー

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshStatusItem() // 開いた時点の実状態にアイコンも合わせる
        menu.removeAllItems()

        menu.addItem(informational("入力: \(deviceName(defaultInputDevice()))"))
        menu.addItem(informational("出力: \(outputSummary())"))
        menu.addItem(.separator())
        menu.addItem(informational("固定するマイク"))

        for id in inputDevices() {
            // UID が取れないデバイスは固定先として保存できない。選べる見た目にすると
            // クリックしても無反応になるので、理由を書いた無効項目として出す。
            guard let uid = deviceUID(id) else {
                menu.addItem(informational("\(deviceName(id))（UID が取れず固定できない）"))
                continue
            }
            let item = NSMenuItem(title: deviceName(id),
                                  action: #selector(selectDevice(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = uid
            item.state = (uid == lockedUID) ? .on : .off
            menu.addItem(item)
        }

        // 固定先が今つながっていないことを黙って隠さない
        if let uid = lockedUID, device(forUID: uid) == nil {
            menu.addItem(informational("固定先が未接続（つながり次第また固定する）"))
        }

        let noLock = NSMenuItem(title: "固定しない", action: #selector(disableLock), keyEquivalent: "")
        noLock.target = self
        noLock.state = (lockedUID == nil) ? .on : .off
        menu.addItem(noLock)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "mic-lock を終了", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func informational(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func selectDevice(_ sender: NSMenuItem) {
        guard let uid = sender.representedObject as? String else { return }
        lockedUID = uid
        logger.notice("固定先を \(sender.title, privacy: .public) に変更した")
        enforce()
        refreshStatusItem()
    }

    @objc private func disableLock() {
        lockedUID = nil
        logger.notice("固定を解除した")
        refreshStatusItem()
    }

    @objc private func quit() {
        logger.notice("mic-lock を終了した")
        NSApp.terminate(nil)
    }

    /// 検証用。実際に組み立てたメニューを標準出力に吐く（--dump-menu）。
    func dumpMenu() {
        let menu = NSMenu()
        menuNeedsUpdate(menu)
        for item in menu.items {
            if item.isSeparatorItem {
                print("  ----------")
                continue
            }
            let mark = item.state == .on ? "✓" : (item.action == nil ? " ·" : "  ")
            print("\(mark) \(item.title)")
        }
        let degraded = isHandsFreeDegraded.map { $0 ? "yes" : "no" } ?? "判定不能"
        print("\nアイコン状態: ハンズフリー転落=\(degraded) 固定先=\(lockedDeviceDescription())")
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()

if CommandLine.arguments.contains("--dump-menu") {
    delegate.dumpMenu()
    exit(0)
}

app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
