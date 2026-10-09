#!/usr/bin/env bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TASK_MODE="${1:-run}"
if [[ $# -gt 0 ]]; then shift; fi
case "$TASK_MODE" in
  run|--verify|--debug|--logs|--telemetry|--build) ;;
  *) echo "Usage: $0 [run|--verify|--debug|--logs|--telemetry|--build] [app arguments]" >&2; exit 2 ;;
esac
TASK_BUILD="$TASK_ROOT/../../work/swift"
TASK_APP="/tmp/AgentLive-${UID}/AgentLive.app"
swift build --package-path "$TASK_ROOT" --build-path "$TASK_BUILD" --product AgentLive
TASK_BINARY="$(swift build --package-path "$TASK_ROOT" --build-path "$TASK_BUILD" --show-bin-path)/AgentLive"
TASK_STAGE="$(mktemp -d /tmp/agent-live-bundle.XXXXXX)"
trap 'rm -rf "$TASK_STAGE"' EXIT
mkdir -p "$TASK_STAGE/AgentLive.app/Contents/MacOS" "$(dirname "$TASK_APP")"
cp "$TASK_BINARY" "$TASK_STAGE/AgentLive.app/Contents/MacOS/AgentLive"
python3 - "$TASK_STAGE/AgentLive.app/Contents/Info.plist" "$TASK_ROOT" <<'PY'
import plistlib,sys
p={'CFBundlePackageType':'APPL','CFBundleExecutable':'AgentLive','CFBundleIdentifier':'local.agentlive.mac','CFBundleName':'Agent Live','CFBundleDisplayName':'Agent Live','CFBundleShortVersionString':'0.20.0','CFBundleVersion':'20','LSMinimumSystemVersion':'15.0','NSPrincipalClass':'NSApplication','NSMicrophoneUsageDescription':'記録を開始した会話の保存と、AIとの音声会話にマイクを使います。','NSCameraUsageDescription':'オンにしたカメラの映像をAIへ共有し、選択した場合は記録します。','NSSpeechRecognitionUsageDescription':'話した内容を端末内で素早く文字にし、相棒への会話に使います。','MeetingProjectPath':sys.argv[2]}
with open(sys.argv[1],'wb') as f: plistlib.dump(p,f)
PY
codesign --force --sign - --identifier local.agentlive.mac "$TASK_STAGE/AgentLive.app" >/dev/null
codesign --verify --strict "$TASK_STAGE/AgentLive.app"
ditto -c -k --norsrc --keepParent "$TASK_STAGE/AgentLive.app" "$TASK_ROOT/AgentLive-mac.zip"
if [[ "$TASK_MODE" == --build ]]; then
  echo "$TASK_ROOT/AgentLive-mac.zip"
  exit 0
fi
# A normal quit lets the app finish recording. Never kill other copies by process name.
swift - "$TASK_APP" <<'SWIFT'
import AppKit
import Foundation
let target = URL(fileURLWithPath: CommandLine.arguments.last!).standardizedFileURL
let running = NSRunningApplication.runningApplications(withBundleIdentifier: "local.agentlive.mac")
guard running.allSatisfy({ $0.bundleURL?.standardizedFileURL == target }) else {
    fputs("別の場所から起動中のAgent Liveを終了してから、もう一度実行してください。\n", stderr)
    exit(1)
}
running.forEach { _ = $0.terminate() }
let deadline = Date().addingTimeInterval(20)
while running.contains(where: { !$0.isTerminated }) && Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
}
guard running.allSatisfy({ $0.isTerminated }) else {
    fputs("Agent Liveの記録終了を待っています。アプリを終了してから、もう一度実行してください。\n", stderr)
    exit(1)
}
SWIFT
rm -rf "$TASK_APP"
ditto --norsrc --noextattr "$TASK_STAGE/AgentLive.app" "$TASK_APP"
codesign --verify --strict "$TASK_APP"
case "$TASK_MODE" in
  run) open -n "$TASK_APP" --args "$@" ;;
  --verify)
    rm -f "$(dirname "$TASK_APP")/launch.json"
    open -n "$TASK_APP" --args --connect-only --snapshot "$@"
    python3 - "$(dirname "$TASK_APP")/launch.json" <<'PY'
import json,sys,time
from pathlib import Path
path=Path(sys.argv[1]);deadline=time.monotonic()+20
while time.monotonic()<deadline:
    if path.exists():
        report=json.loads(path.read_text())
        if report.get('visible') and report.get('snapshot'):
            print('AgentLive window verified:',json.dumps(report,sort_keys=True));break
        raise SystemExit('AgentLive did not display its window')
    time.sleep(0.5)
else:raise SystemExit('AgentLive startup did not complete within 20 seconds')
PY
    ;;
  --debug) lldb -- "$TASK_APP/Contents/MacOS/AgentLive" "$@" ;;
  --logs) open -n "$TASK_APP" --args "$@"; /usr/bin/log stream --info --style compact --predicate 'process == "AgentLive"' ;;
  --telemetry) open -n "$TASK_APP" --args "$@"; /usr/bin/log stream --info --style compact --predicate 'subsystem == "local.agentlive.mac"' ;;
esac
