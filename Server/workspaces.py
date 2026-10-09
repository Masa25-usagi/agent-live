"""Session-scoped previews for files produced by the user's agent task."""
import base64
import hashlib
import hmac
import json
import mimetypes
import re
import time
from pathlib import Path
from urllib.parse import quote
from aiohttp import web

IGNORED = {'node_modules', '__pycache__', 'venv', 'dist-cache'}


def cookie_name(session):
    return 'agent_preview_' + hashlib.sha256(session.encode()).hexdigest()[:16]


def ticket(secret, session):
    value = base64.urlsafe_b64encode(json.dumps({'session': session, 'expires': time.time() + 1800}).encode()).decode().rstrip('=')
    signature = hmac.new(secret.encode(), value.encode(), hashlib.sha256).hexdigest()
    return value + '.' + signature


def permits(request, secret):
    session = request.match_info.get('session', '')
    supplied = request.query.get('ticket') or request.cookies.get(cookie_name(session), '')
    try:
        value, signature = supplied.split('.')
        if not hmac.compare_digest(signature, hmac.new(secret.encode(), value.encode(), hashlib.sha256).hexdigest()):
            return False
        data = json.loads(base64.urlsafe_b64decode(value + '=' * (-len(value) % 4)))
        return data['session'] == session and data['expires'] > time.time()
    except (ValueError, KeyError, TypeError):
        return False


def visible(path):
    return all(not part.startswith('.') and part not in IGNORED for part in path.parts)


def routes(root, secret):
    root = Path(root) / 'workspaces'

    async def listing(request):
        session = request.match_info['session']
        if not re.fullmatch(r'[A-Za-z0-9:_-]{1,160}',session): raise web.HTTPBadRequest()
        base = root / session
        files = []
        if base.is_dir():
            access = ticket(secret, session)
            for path in sorted(base.rglob('*')):
                relative = path.relative_to(base)
                if len(relative.parts) > 5 or not visible(relative) or path.is_symlink() or not path.is_file():
                    continue
                try:
                    path.resolve().relative_to(base.resolve())
                except ValueError:
                    continue
                if path.stat().st_size > 64 * 1024**2:
                    continue
                files.append({'name': relative.as_posix(), 'path': '/artifacts/' + quote(session, safe='') + '/' + quote(relative.as_posix()),
                              'ticket': access, 'mime': mimetypes.guess_type(path.name)[0] or 'text/plain'})
                if len(files) >= 100:
                    break
        return web.json_response({'files': files})

    async def artifact(request):
        session = request.match_info['session']
        if not re.fullmatch(r'[A-Za-z0-9:_-]{1,160}',session): raise web.HTTPBadRequest()
        base = root / session
        relative = Path(request.match_info['path'])
        if not visible(relative):
            raise web.HTTPForbidden()
        try:
            path = (base / relative).resolve(strict=True)
            path.relative_to(base.resolve())
        except (ValueError, FileNotFoundError):
            raise web.HTTPNotFound()
        if not path.is_file() or path.stat().st_size > 64 * 1024**2:
            raise web.HTTPNotFound()
        response = web.FileResponse(path)
        response.headers['Referrer-Policy'] = 'no-referrer'
        response.headers['X-Content-Type-Options'] = 'nosniff'
        response.headers['Content-Type'] = mimetypes.guess_type(path.name)[0] or 'text/plain; charset=utf-8'
        supplied = request.query.get('ticket')
        if supplied:
            response.set_cookie(cookie_name(session), supplied, path='/artifacts/' + quote(session, safe='') + '/', httponly=True,
                                samesite='Strict', max_age=1800)
        return response

    return [web.get('/workspaces/{session}', listing), web.get('/artifacts/{session}/{path:.*}', artifact)]
