"""Permission preset belonging to this server, never to a phone or the global Hermes config."""
import json
import platform


def mode(root):
    try:
        value = json.loads((root / 'host-policy.json').read_text()).get('mode')
        return value if value in ('main', 'dedicated') else 'main'
    except (OSError, ValueError, TypeError, AttributeError):
        return 'main'


def public(root):
    return {'mode': mode(root), 'host_name': platform.node()}


def save(root, value):
    if value not in ('main', 'dedicated'): raise ValueError('Invalid host mode')
    path = root / 'host-policy.json'
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps({'mode': value}))
    temporary.chmod(0o600); temporary.replace(path)
