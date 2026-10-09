"""Bootstrap an app-only launchd service using the installed Hermes runtime and private settings."""
import json
import os
import runpy
import sys
from pathlib import Path

home = Path.home()
settings = json.loads((home / '.config/agent-live/mac-settings.json').read_text())
os.environ.update(settings)
sys.path.insert(0, str(home / '.hermes/hermes-agent'))
import hermes_bootstrap  # noqa: E402
sys.path.insert(0, str(home / '.local/share/agent-live-runtime'))
sys.path.insert(0, str(Path(__file__).parent))
try:
    from dotenv import load_dotenv
    load_dotenv(home / '.hermes/.env', override=False)
except ImportError:
    pass
module = 'hermes_api.py' if sys.argv[1:] == ['hermes'] else 'app.py'
runpy.run_path(str(Path(__file__).with_name(module)), run_name='__main__')
