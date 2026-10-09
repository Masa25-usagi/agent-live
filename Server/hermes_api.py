"""Agent Live's API-only Hermes runner. Does not start chat bots, cron, or change config.yaml."""
import asyncio
import os
import signal
import json
import urllib.parse
import urllib.request
from pathlib import Path


def register_app_tools():
    from hermes_cli.plugins import PluginContext, PluginManifest, get_plugin_manager
    context = PluginContext(PluginManifest(name='agent-live-app', source='project', path=str(Path(__file__).parent)), get_plugin_manager())
    def policy(tool_name='', session_id='', args=None, **kwargs):
        try:
            from action_policy import directive
            return directive(Path(os.environ['AGENT_LIVE_DATA']), tool_name, session_id, args or {})
        except Exception:
            return {'action': 'block', 'message': 'このアプリの実行範囲を確認できないため、処理を見送ります。'}
    context.register_hook('pre_tool_call', policy)
    def history(query='', session_id='', **kwargs):
        path = 'sessions/' + urllib.parse.quote(session_id, safe='') if session_id else 'records?' + urllib.parse.urlencode({'q': query})
        request = urllib.request.Request('http://127.0.0.1:8787/' + path, headers={'Authorization': 'Bearer ' + os.environ['AGENT_LIVE_TOKEN']})
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                return response.read().decode()
        except Exception:
            return json.dumps({'error': 'Records temporarily unavailable'})
    context.register_tool(name='agent_live_records', toolset='memory',
        schema={'name':'agent_live_records','description':'本人のAgent Liveの会話記録を検索・参照する。',
                'parameters':{'type':'object','properties':{'query':{'type':'string'},'session_id':{'type':'string'}}}},handler=history)
    return context


async def main():
    from gateway.config import GatewayConfig, PlatformConfig, Platform
    from gateway.run import GatewayRunner
    config = GatewayConfig(multiplex_profiles=False)
    config.sessions_dir = Path(os.environ['AGENT_LIVE_DATA']) / 'hermes-sessions'
    platform = PlatformConfig(enabled=True, gateway_restart_notification=False,
                              extra={'host': '127.0.0.1', 'port': int(os.environ.get('AGENT_LIVE_HERMES_PORT', '8642')), 'key': os.environ['HERMES_API_KEY']})
    config.platforms = {Platform.API_SERVER: platform}
    runner = GatewayRunner(config)
    runner._fallback_model = None  # App requests keep the explicitly selected subscription provider.
    register_app_tools()
    runner._gateway_loop = asyncio.get_running_loop()
    runner._running = True
    adapter = runner._create_adapter(Platform.API_SERVER, platform)
    if adapter is None:
        raise RuntimeError('Hermes API unavailable')
    runner._wire_adapter_handlers(adapter)
    runner.adapters[Platform.API_SERVER] = adapter
    if not await adapter.connect():
        raise RuntimeError('Hermes API did not start')
    stopped = asyncio.Event()
    for sig in (signal.SIGTERM, signal.SIGINT):
        asyncio.get_running_loop().add_signal_handler(sig, stopped.set)
    try:
        await stopped.wait()
    finally:
        await adapter.disconnect()


if __name__ == '__main__':
    asyncio.run(main())
