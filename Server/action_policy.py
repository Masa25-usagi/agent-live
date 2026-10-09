"""App-only action boundaries; generated criteria cannot broaden these permissions."""
import json
import os
import re
from pathlib import Path
from host_policy import mode as host_mode

READ_TOOLS = {'web_search', 'web_extract', 'memory', 'session_search', 'read_file', 'search_files', 'skill_view', 'agent_live_records', 'clarify'}

def directive(root, tool_name, session_id, args):
    try:
        mode = json.loads((root / 'run-policy.json').read_text()).get(session_id)
    except Exception:
        mode = None
    if not mode:
        # No policy is also the default when a reused internal Hermes conversation ID is supplied.
        # App API runs must not gain unrestricted execution through a missing mapping.
        return None if tool_name in READ_TOOLS else {'action': 'block', 'message': 'このアプリの実行範囲を確認できないため、変更を見送ります。'}
    if mode == 'work': return None  # Only explicit app work admissions choose this mode.
    if mode == 'reply':
        return {'action': 'block', 'message': 'この処理は短い音声返答です。調査や制作は別のHermes処理が担当します。'}
    if mode == 'dedicated_draft' and host_mode(root) != 'dedicated': mode = 'draft'
    if tool_name in READ_TOOLS: return None
    if mode == 'dedicated_draft' and host_mode(root) == 'dedicated':
        # The user authorized installation/configuration on a dedicated host, not external actions.
        if tool_name in {'write_file', 'patch', 'terminal', 'process'}:
            command = str(args.get('command', '')) if isinstance(args, dict) else ''
            if tool_name == 'terminal' and re.search(r'(?i)\b(?:git\s+push|gh\s+(?:pr|release)\s+create|npm\s+publish|twine\s+upload|netlify\s+deploy|vercel\s+(?:deploy|--prod)|curl\b.*(?:--data|-d\b|-X\s*(?:POST|PUT|PATCH|DELETE)))', command):
                return {'action': 'block', 'message': '外部への送信・公開・購入には本人の確認が必要です。'}
            return None
    if mode == 'draft' and tool_name == 'write_file':
        raw = args.get('path') if isinstance(args, dict) else None
        if isinstance(raw, str) and raw and Path(raw).is_absolute():
            workspace = (root / 'workspaces' / session_id).resolve()
            target = Path(raw).resolve()
            if target != workspace and workspace in target.parents and not any(part.startswith('.') for part in target.relative_to(workspace).parts): return None
    return {'action': 'block', 'message': '自動処理は調査・記憶・専用フォルダー内の案や試作品までです。送信・公開・購入・既存環境の変更は本人の確認が必要です。'}
