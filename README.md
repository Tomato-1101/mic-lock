# mic-lock

Bluetooth ヘッドセット接続時に音声入力デバイスを奪われないよう、内蔵マイクへ戻し続ける常駐デーモン。

## 何を解決するか

WH-1000XM6 のような Bluetooth ヘッドセットを接続すると、macOS は**出力だけでなく入力も**そのデバイスに切り替える。
ヘッドセットのマイクが既定入力になると Bluetooth のプロファイルが A2DP から HFP に落ち、
サンプルレートが 44.1kHz → 16kHz になって**再生音質まで劣化する**。

mic-lock は既定入力デバイスが Bluetooth 系になった瞬間に内蔵マイクへ戻す。出力はヘッドホンのまま A2DP を維持する。

## 介入する条件

既定入力デバイスの**トランスポート種別が Bluetooth のときだけ**内蔵マイクへ戻す。
USB マイク・オーディオインターフェイス・iPhone の連係マイクを選んだ場合は何もしない。
（「常に内蔵マイク固定」にすると外部マイクが使えなくなるため、Bluetooth に限定している）

## 仕組み

CoreAudio のプロパティリスナで以下2つを監視するイベント駆動。ポーリングしないので CPU 消費はほぼゼロ。

- `kAudioHardwarePropertyDefaultInputDevice` — 既定入力が変わった瞬間
- `kAudioHardwarePropertyDevices` — デバイス一覧の変化（接続直後は「デバイス追加 → 遅れて入力が奪われる」順で起きるため 0.4 秒後に再判定）

マイク権限は不要（デバイスの列挙と選択のみで、音声は一切取得しない）。

## ビルド

```sh
cd ~/Project/mic-lock
swiftc -O -o mic-lock main.swift
```

## 常駐（LaunchAgent）

`~/Library/LaunchAgents/com.tomato.mic-lock.plist`

```sh
# 起動
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.tomato.mic-lock.plist
# 停止（一時的にオフにしたいとき）
launchctl bootout gui/$(id -u)/com.tomato.mic-lock
# 状態
launchctl print gui/$(id -u)/com.tomato.mic-lock | grep -E 'state|pid'
```

ビルドし直したら `launchctl kickstart -k gui/$(id -u)/com.tomato.mic-lock` で入れ替える。

## ログ

os.log の `.notice` レベルで永続化しているので後から追える。

```sh
/usr/bin/log show --last 1h --predicate 'subsystem == "com.tomato.mic-lock"' --style compact
```

※ zsh に `log` という別コマンドがあるため `/usr/bin/log` とフルパスで叩く。
