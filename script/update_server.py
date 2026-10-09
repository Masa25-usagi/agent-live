"""Update existing Agent Live services without changing Hermes credentials or model settings."""
import argparse
import io
import subprocess
import tarfile
from pathlib import Path

parser=argparse.ArgumentParser()
parser.add_argument('--ssh',help='SSH target configured by the operator')
parser.add_argument('--restart-hermes',action='store_true',help='Also load changed Discord plugin code; interrupts current Hermes tasks and calls')
args=parser.parse_args()
if not args.ssh:parser.error("--ssh is required")
root=Path(__file__).resolve().parents[1]
ssh=['ssh','-o','BatchMode=yes','-o','ConnectTimeout=8','-o','StrictHostKeyChecking=yes',args.ssh]
for source,target in [('Server','.local/share/agent-live-server'),('Discord','.hermes/plugins/agent-live')]:
    data=io.BytesIO()
    with tarfile.open(fileobj=data,mode='w') as archive:
        for path in (root/source).rglob('*'):
            if path.is_file() and not path.is_symlink() and '__pycache__' not in path.parts:
                archive.add(path,arcname=path.relative_to(root/source).as_posix())
    subprocess.run(ssh+['mkdir -p "$HOME/'+target+'" && tar -xf - -C "$HOME/'+target+'"'],input=data.getvalue(),check=True)
subprocess.run(ssh+['systemctl --user restart agent-live.service'],check=True)
if args.restart_hermes:subprocess.run(ssh+['systemctl --user restart hermes-gateway.service'],check=True)
print('Updated Agent Live. No model, persona or provider credentials were changed.')
