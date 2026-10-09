"""One-time Google desktop OAuth. Tokens go to the private configured server service over SSH stdin."""
import argparse, base64, hashlib, hmac, json, os, secrets, shlex, subprocess, time, urllib.parse, urllib.request, urllib.error, webbrowser
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path

parser=argparse.ArgumentParser(description='Connect Agent Live to a dedicated Google Drive folder.')
parser.add_argument('client_json',type=Path,help='Google Cloud OAuth client JSON (Desktop app)')
parser.add_argument('--ssh',help='SSH target configured by the operator')
parser.add_argument('--local',action='store_true',help='Save OAuth to the app-only Mac server instead of configured server')
parser.add_argument('--auth-url-file',type=Path,help='Save the temporary authorization URL privately for browser coordination')
parser.add_argument('--no-open',action='store_true',help='Let the caller open the saved URL in its browser')
args=parser.parse_args()
if not args.local and not args.ssh:parser.error("--ssh is required unless --local is selected")
if args.no_open and not args.auth_url_file:parser.error('--no-open requires --auth-url-file')
client=json.loads(args.client_json.read_text()).get('installed')
if not client:raise SystemExit('OAuthクライアントの種類を「デスクトップアプリ」にしてください。')
state=secrets.token_urlsafe(32);verifier=secrets.token_urlsafe(64)
challenge=base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip('=')
callback={}
class Handler(BaseHTTPRequestHandler):
    def log_message(self,*args):pass
    def do_GET(self):
        query=urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        if not hmac.compare_digest(query.get('state',[''])[0],state):self.send_error(400);return
        callback.update({k:v[0] for k,v in query.items()})
        self.send_response(200);self.send_header('Content-Type','text/html; charset=utf-8');self.end_headers()
        self.wfile.write('<meta charset="utf-8"><title>Agent Live</title><p>認可の結果を受け取りました。この画面を閉じてMacの設定処理に戻ってください。</p>'.encode())
server=HTTPServer(('127.0.0.1',0),Handler);server.timeout=1
redirect='http://127.0.0.1:'+str(server.server_port)+'/oauth'
url='https://accounts.google.com/o/oauth2/v2/auth?'+urllib.parse.urlencode({'client_id':client['client_id'],'redirect_uri':redirect,'response_type':'code','scope':'https://www.googleapis.com/auth/drive.file','access_type':'offline','prompt':'consent','state':state,'code_challenge':challenge,'code_challenge_method':'S256'})
print('Googleで保存先アカウントを選び、Agent Liveが作成するファイルへのアクセスを許可してください。')
if args.auth_url_file:
    fd=os.open(args.auth_url_file,os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600)
    with os.fdopen(fd,'w') as stream:stream.write(url)
    args.auth_url_file.chmod(0o600)
if not args.no_open:webbrowser.open(url)
deadline=time.monotonic()+600
while not callback and time.monotonic()<deadline:server.handle_request()
server.server_close()
if args.auth_url_file:args.auth_url_file.unlink(missing_ok=True)
if not callback.get('code'):raise SystemExit('認可が完了していません。元の記録は保存待ちのままです。')
def call(url,data=None,token=None,method=None):
    headers={}
    if token:headers['Authorization']='Bearer '+token
    if data is not None:headers['Content-Type']='application/json' if isinstance(data,dict) else 'application/x-www-form-urlencoded'
    body=json.dumps(data).encode() if isinstance(data,dict) else data
    try:
        with urllib.request.urlopen(urllib.request.Request(url,data=body,headers=headers,method=method),timeout=30) as response:return json.load(response)
    except urllib.error.HTTPError as error:raise SystemExit('Googleとの接続を完了できませんでした（'+str(error.code)+'）。認可とDrive APIの有効化を確認してください。')
result=call('https://oauth2.googleapis.com/token',urllib.parse.urlencode({'client_id':client['client_id'],'client_secret':client['client_secret'],'code':callback['code'],'redirect_uri':redirect,'grant_type':'authorization_code','code_verifier':verifier}).encode())
if not result.get('refresh_token'):raise SystemExit('継続用の認可を取得できませんでした。もう一度認可してください。')
query=urllib.parse.urlencode({'q':"mimeType='application/vnd.google-apps.folder' and trashed=false and appProperties has { key='agentLiveRoot' and value='true' }",'fields':'files(id,name,webViewLink)'})
folders=call('https://www.googleapis.com/drive/v3/files?'+query,token=result['access_token']).get('files',[])
folder=folders[0] if folders else call('https://www.googleapis.com/drive/v3/files?fields=id,name,webViewLink',{'name':'Agent Live','mimeType':'application/vnd.google-apps.folder','appProperties':{'agentLiveRoot':'true'}},token=result['access_token'])
saved={k:client[k] for k in ('client_id','client_secret')};saved['refresh_token']=result['refresh_token']
remote=r'''import sys,json,pathlib
p=json.load(sys.stdin);home=pathlib.Path.home();root=home/'.local/share/agent-live';root.mkdir(parents=True,exist_ok=True)
token=root/'google-token.json';token.write_text(json.dumps(p['token']));token.chmod(0o600)
env=home/'.config/agent-live/server.env';lines=[x for x in env.read_text().splitlines() if not x.startswith('DRIVE_FOLDER_ID=')];lines.append('DRIVE_FOLDER_ID='+p['folder']);env.write_text('\n'.join(lines)+'\n');env.chmod(0o600)
print('Drive credentials saved privately')'''
ssh=['ssh','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes',args.ssh]
if args.local:
    root=Path.home()/'.local/share/agent-live';root.mkdir(parents=True,exist_ok=True,mode=0o700)
    token=root/'google-token.json';token.write_text(json.dumps(saved));token.chmod(0o600)
    settings_path=Path.home()/'.config/agent-live/mac-settings.json'
    settings=json.loads(settings_path.read_text());settings['DRIVE_FOLDER_ID']=folder['id']
    temporary=settings_path.with_suffix('.tmp');temporary.write_text(json.dumps(settings));temporary.chmod(0o600);temporary.replace(settings_path)
    subprocess.run(['launchctl','kickstart','-k','gui/'+str(os.getuid())+'/local.agentlive.bridge'],check=True)
else:
    subprocess.run(ssh+['/usr/bin/python3 -c '+shlex.quote(remote)],input=json.dumps({'token':saved,'folder':folder['id']}).encode(),check=True)
    subprocess.run(ssh+['systemctl --user restart agent-live.service'],check=True)
print('Drive保存を接続しました。アプリの設定で「接続を確認」を押してください。')
print(folder.get('webViewLink',''))
