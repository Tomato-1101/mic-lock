# mic-lock

メニューバーから選んだマイクを既定入力に固定し続ける常駐アプリ。

## 何を解決するか

WH-1000XM6 のような Bluetooth ヘッドセットを接続すると、macOS は**出力だけでなく入力も**そのデバイスに切り替える。
ヘッドセットのマイクが既定入力になると Bluetooth プロファイルが A2DP から HFP（ハンズフリー）に落ち、
**再生音質まで 44.1kHz → 16kHz に劣化する**。mic-lock は固定先を決めておき、奪われても即座に戻す。

出力はヘッドホンのまま A2DP（AAC-LC 256kbps）を維持する。

## メニュー

メニューバーの **四角囲みマイクアイコン** をクリックすると開く。

```
入力: MacBook Proのマイク
出力: WH-1000XM6  44.1kHz  A2DP 高音質
──────────
固定するマイク
✓ MacBook Proのマイク
  WH-1000XM6
  固定しない
──────────
mic-lock を終了
```

- 一覧から選んだデバイスが新しい固定先になり、その場で切り替わる
- 上2行はいま実際に使われている入出力。**出力行でハンズフリーに落ちていないか確認できる**
- 固定先が未接続のときはその旨を表示し、つながり次第また固定する
- 固定先は AudioDeviceID ではなく **デバイス UID** で保存するので、再接続しても同じデバイスを追える

## アイコンの意味

| アイコン | 状態 |
|---|---|
| `mic.square.fill`（塗りつぶし） | 固定中 |
| `mic.square`（枠のみ） | 固定しない |
| `exclamationmark.triangle.fill`（警告） | 出力がハンズフリーに落ちて音質低下中 |

四角囲みにしているのは、メニューバーに並ぶ他のマイクアイコン（voicekey・macOS のマイク使用中インジケータ）と
一目で見分けるため。

## 仕組み

CoreAudio のプロパティリスナによるイベント駆動。ポーリングしないので CPU 消費はほぼゼロ。

- `kAudioHardwarePropertyDefaultInputDevice` — 入力が奪われた瞬間
- `kAudioHardwarePropertyDefaultOutputDevice` — 出力の変化（音質表示の更新）
- `kAudioHardwarePropertyDevices` — デバイス一覧の変化（接続直後は「デバイス追加 → 遅れて入力が奪われる」順で
  起きるため 0.4 秒後に再判定）
- `kAudioDevicePropertyNominalSampleRate`（既定出力デバイス自身に登録） — **A2DP ⇄ HFP の遷移は
  「既定出力デバイスの変更」では通知されない**（同じデバイスのままサンプルレートだけ変わる）。
  これを入れないと HFP に落ちた後アイコンが警告のまま固まる。出力デバイスが変わったらリスナを付け替える

マイク権限は不要（デバイスの列挙と選択のみで、音声は一切取得しない）。

## ビルド

```sh
./build.sh    # dist/mic-lock.app を作り Apple Development 証明書で署名する
```

## 常駐（LaunchAgent）

`~/Library/LaunchAgents/com.tomato.mic-lock.plist`

```sh
# 起動
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.tomato.mic-lock.plist
# 停止（メニューの「終了」でも止まる。KeepAlive は SuccessfulExit=false なので正常終了なら再起動しない）
launchctl bootout gui/$(id -u)/com.tomato.mic-lock
# ビルドし直したあとの入れ替え
launchctl kickstart -k gui/$(id -u)/com.tomato.mic-lock
```

## ハマった点：NSStatusItem は autosaveName が必須

`autosaveName` を設定しないと、macOS 26 はステータス項目の配置位置を決められず
**アイコンを画面外（実測 x = -4506）に置き、一切表示されない**。`isVisible = true` でも、
`button.image` が設定されていても表示されない。メニューバーの空きとは無関係。

```swift
statusItem.autosaveName = "mic-lock"   // これが無いと表示されない
```

初回だけ `NSStatusItem Preferred Position mic-lock` に既定値を入れている（以降はユーザーが
⌘ドラッグで動かした位置が保存される）。

## 検証ツール

```sh
# いま組み立てられるメニューを標準出力に出す（アプリを起動せず内容を確認できる）
dist/mic-lock.app/Contents/MacOS/mic-lock --dump-menu

# 入力デバイスの一覧・UID・切り替え
swiftc -O -o /tmp/audiodev tools/audiodev.swift
/tmp/audiodev        # 一覧
/tmp/audiodev 71     # ID 71 を既定入力にする（固定が効くかの確認用）
```

## ログ

os.log の `.notice` レベルで永続化しているので後から追える。

```sh
/usr/bin/log show --last 1h --predicate 'subsystem == "com.tomato.mic-lock"' --style compact
```

※ zsh に `log` という別コマンドがあるため `/usr/bin/log` とフルパスで叩く。

## Bluetooth の実コーデックを確かめたいとき

メニューの出力行（サンプルレート）で足りるが、コーデック名まで見たい場合:

```sh
system_profiler SPBluetoothDataType >/dev/null
/usr/bin/log show --last 1m --predicate 'process == "bluetoothd"' --style compact | grep -oE "AuLQ \[\{[^}]*\}\]" | tail -1
# => BtRt 256 Kbps, Codc AAC-LC ... なら A2DP の最高音質（macOS は LDAC/aptX 非対応）
```
