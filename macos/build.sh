#!/bin/sh
set -eu

source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
output_dir="${1:-$source_dir/../build}"
mkdir -p "$output_dir"
xcrun swiftc -parse-as-library -O -swift-version 6 -target "$(uname -m)-apple-macosx15.0" \
  -module-cache-path "$output_dir/module-cache" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$source_dir/RecorderInfo.plist" \
  "$source_dir/RecordMeeting.swift" -o "$output_dir/record-meeting"
xcrun swiftc -parse-as-library -O -swift-version 6 -target "$(uname -m)-apple-macosx15.0" \
  -module-cache-path "$output_dir/module-cache" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$source_dir/WatcherInfo.plist" \
  "$source_dir/WatchMeetings.swift" -o "$output_dir/watch-meetings"
