#!/usr/bin/env python3
"""Build, install and pair the native voice app on a trusted USB iPhone.

The pairing JSON stays in private files and the app's sandbox, never in command
arguments, build products or logs. Xcode/Apple account setup must already exist.
"""
import argparse
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def private_directory(path):
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.chmod(0o700)
    return path


def private_json(path, value):
    temporary = path.with_suffix('.tmp')
    with open(temporary, 'w', encoding='utf-8', opener=lambda name, flags: os.open(name, flags, 0o600)) as target:
        json.dump(value, target, ensure_ascii=False)
    temporary.chmod(0o600)
    temporary.replace(path)


def execute(command, env, timeout=180, log=None):
    if log:
        with open(log, 'wb', opener=lambda name, flags: os.open(name, flags, 0o600)) as target:
            result = subprocess.run(command, env=env, stdout=target, stderr=subprocess.STDOUT, timeout=timeout)
    else:
        result = subprocess.run(command, env=env, capture_output=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError('コマンドが完了しませんでした。Xcodeの初回設定・署名・iPhoneのDeveloper Modeを確認してください。' + (f' 詳細: {log}' if log else ''))
    return result


def xcode_environment(explicit=None):
    env = os.environ.copy()
    if explicit:
        env['DEVELOPER_DIR'] = str(Path(explicit).expanduser() / 'Contents/Developer')
    elif not env.get('DEVELOPER_DIR'):
        if Path('/Applications/Xcode.app/Contents/Developer').exists():
            env['DEVELOPER_DIR'] = '/Applications/Xcode.app/Contents/Developer'
        else:
            selected = subprocess.run(['xcode-select', '-p'], capture_output=True, text=True)
            if selected.returncode == 0 and selected.stdout.strip().endswith('.app/Contents/Developer'):
                env['DEVELOPER_DIR'] = selected.stdout.strip()
    if not env.get('DEVELOPER_DIR') or not (Path(env['DEVELOPER_DIR']) / 'usr/bin/xcodebuild').exists():
        raise RuntimeError('Xcode本体が必要です。Intel MacではApple公式DownloadsのXcode 26系 Universal版を用意してください。')
    return env


def select_device(device_file=None):
    if device_file:
        info = json.loads(Path(device_file).read_text())
        value = info.get('udid') or info.get('device')
        if not isinstance(value, str) or not re.fullmatch(r'[A-Fa-f0-9-]{20,80}', value):
            raise RuntimeError('実機情報ファイルを確認してください。')
        return value
    binary = shutil.which('idevice_id')
    if not binary:
        raise RuntimeError('USB認識用のlibimobiledeviceが必要です（brew install libimobiledevice）。')
    result = subprocess.run([binary, '-l'], capture_output=True, text=True, timeout=30, check=True)
    devices = [line.strip() for line in result.stdout.splitlines() if re.fullmatch(r'[A-Fa-f0-9-]{20,80}', line.strip())]
    if len(devices) != 1:
        raise RuntimeError('USBで信頼済みのiPhoneを1台接続してください。複数台の場合は--device-fileで選べます。')
    return devices[0]


def main():
    parser = argparse.ArgumentParser(description='iPhoneの音声中心版をビルド・インストールして接続します。')
    parser.add_argument('--pairing', required=True, type=Path, help='private endpoint/token JSON')
    parser.add_argument('--team', help='Apple Personal Team or Development Team ID')
    parser.add_argument('--device-file', type=Path, help='private JSON containing the USB UDID')
    parser.add_argument('--xcode', help='path to the compatible Xcode.app')
    parser.add_argument('--scratch', type=Path, required=True, help='private directory outside distributable sources')
    parser.add_argument('--check-only', action='store_true', help='check prerequisites without installing or pairing')
    parser.add_argument('--generic-destination', action='store_true', help='build generically if the installed Xcode cannot select the newer iOS device; the phone must already be registered for signing')
    parser.add_argument('--voice-only', action='store_true', help='install the fallback without the ReplayKit broadcast extension')
    args = parser.parse_args()
    scratch = args.scratch.expanduser().resolve()
    if scratch == ROOT or ROOT in scratch.parents:
        parser.error('scratchは配布用AgentLiveフォルダーの外に置いてください。')
    private_directory(scratch)
    try:
        env = xcode_environment(args.xcode)
        device = select_device(args.device_file)
        pairing = json.loads(args.pairing.expanduser().read_text())
        if not isinstance(pairing, dict) or not all(isinstance(pairing.get(k), str) and pairing[k] for k in ('endpoint', 'token')):
            raise RuntimeError('接続情報の形式を確認してください。')
        if len(json.dumps(pairing).encode()) > 16_384:
            raise RuntimeError('接続情報が大きすぎます。')
        scheme = 'AgentLiveVoice' if args.voice_only else 'AgentLive'
        project = ROOT / ('iOS/' + scheme + '.xcodeproj')
        text = (project / 'project.pbxproj').read_text()
        team = args.team or re.search(r'DEVELOPMENT_TEAM\s*=\s*"?([A-Za-z0-9]+)"?\s*;', text)
        if not isinstance(team, str):
            team = team.group(1) if team else ''
        if not team or not re.fullmatch(r'[A-Za-z0-9]+', team):
            raise RuntimeError('XcodeのSigning & CapabilitiesのTeamに自分のPersonal Teamを選んでください。')
        execute(['xcrun', '--find', 'devicectl'], env)
        if args.check_only:
            print('Xcode・USB端末・署名Team・接続ファイルの準備を確認しました。実機ビルドは未実施です。')
            return 0
        print('iPhone用の' + ('音声中心版' if args.voice_only else '画面共有対応版') + 'をビルドしています。', flush=True)
        destination = 'generic/platform=iOS' if args.generic_destination else f'platform=iOS,id={device}'
        execute(['xcodebuild', '-project', str(project), '-scheme', scheme, '-configuration', 'Debug',
                 '-destination', destination, '-derivedDataPath', str(scratch / 'Build'),
                 '-allowProvisioningUpdates', '-allowProvisioningDeviceRegistration', 'CODE_SIGN_STYLE=Automatic', f'DEVELOPMENT_TEAM={team}', 'build'],
                env, timeout=2400, log=scratch / 'build.log')
        app = scratch / 'Build/Build/Products/Debug-iphoneos/AgentLive.app'
        if not app.is_dir():
            raise RuntimeError('ビルドしたアプリが見つかりません。')
        bundle = plistlib.loads((app / 'Info.plist').read_bytes())['CFBundleIdentifier']
        print('USB接続のiPhoneへインストールしています。', flush=True)
        execute(['xcrun', 'devicectl', 'device', 'install', 'app', '--device', device, str(app)], env, log=scratch / 'install.log')
        incoming = scratch / 'agentlive-pairing.json'
        imported = {'endpoint': pairing['endpoint'], 'token': pairing['token']}
        for field in ('voice', 'agent_provider', 'agent_model', 'speech_provider', 'live_conversation', 'economy_fast_mode', 'gemini_fast_mode', 'direct_gemini', 'direct_jev'):
            if isinstance(pairing.get(field), str):
                imported[field] = pairing[field]
        private_json(incoming, imported)
        try:
            execute(['xcrun', 'devicectl', 'device', 'copy', 'to', '--device', device, '--source', str(incoming),
                     '--destination', 'Documents/agentlive-pairing.json', '--domain-type', 'appDataContainer',
                     '--domain-identifier', bundle], env, log=scratch / 'pairing-transfer.log')
        finally:
            incoming.unlink(missing_ok=True)
        print('iPhone側でサーバー接続を確認しています。録音は開始しません。', flush=True)
        launched_at = time.time()
        execute(['xcrun', 'devicectl', 'device', 'process', 'launch', '--device', device, '--terminate-existing', bundle,
                 '--', '--connect-only'], env, log=scratch / 'launch.log')
        report_file = scratch / 'connection.json'
        for _ in range(30):
            try:
                report_file.unlink(missing_ok=True)
                execute(['xcrun', 'devicectl', 'device', 'copy', 'from', '--device', device,
                         '--source', 'Documents/agentlive-connection.json', '--destination', str(report_file),
                         '--domain-type', 'appDataContainer', '--domain-identifier', bundle], env, timeout=20, log=scratch / 'connection-read.log')
                result = json.loads(report_file.read_text())
                report_file.chmod(0o600)
                if result.get('checked_at_epoch', 0) < launched_at:
                    time.sleep(2)
                    continue
                if result.get('configuration_imported') and result.get('configured') and result.get('server_reachable') and result.get('recording') is False:
                    print('iPhoneのインストールとサーバー接続が完了しました。記録開始ボタンから使えます。')
                    return 0
                if result.get('configuration_imported'):
                    raise RuntimeError('iPhoneへ接続情報を保存しました。サーバーへ届かない場合はiPhoneのTailscale接続を確認してください。')
            except (OSError, json.JSONDecodeError):
                pass
            except RuntimeError:
                if report_file.exists():
                    raise
            time.sleep(2)
        raise RuntimeError('アプリをインストールしましたが、接続結果を確認できません。iPhoneを開き、Developer ModeとTailscaleを確認してください。')
    except (RuntimeError, OSError, ValueError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
