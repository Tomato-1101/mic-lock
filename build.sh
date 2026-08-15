#!/bin/zsh
# mic-lock.app をビルドして署名する。
# 署名は Apple Development 証明書を使う（ad-hoc だとビルドの度に cdhash が変わり
# TCC 権限がリセットされるため。macos-resident-app スキル参照）。
set -e
cd "$(dirname "$0")"

APP="dist/mic-lock.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O -o "$APP/Contents/MacOS/mic-lock" main.swift
cp Info.plist "$APP/Contents/Info.plist"

IDENTITY=$(security find-identity -v -p codesigning | grep "Apple Development" | head -1 | sed -E 's/.*"(.*)"/\1/')
if [[ -n "$IDENTITY" ]]; then
	codesign --sign "$IDENTITY" --force --timestamp=none "$APP"
	echo "署名: $IDENTITY"
else
	codesign --sign - --force "$APP"
	echo "署名: ad-hoc（Apple Development 証明書が見つからない）"
fi

codesign --verify --verbose=1 "$APP" 2>&1 | tail -1
echo "ビルド完了: $APP"
