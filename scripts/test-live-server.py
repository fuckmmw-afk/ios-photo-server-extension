"""Explicit live integration test; consumes one Gemini generation. Never run automatically in CI."""
import argparse
import base64
import json
import pathlib
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument('source', type=pathlib.Path)
parser.add_argument('--base-url', default='http://127.0.0.1:4981')
parser.add_argument('--output', type=pathlib.Path, default=pathlib.Path('build/live-result'))
args = parser.parse_args()
raw = args.source.read_bytes()
mime = 'image/png' if raw.startswith(b'\x89PNG\r\n\x1a\n') else 'image/jpeg' if raw.startswith(b'\xff\xd8') else None
if mime is None:
    raise SystemExit('Use a PNG/JPEG fixture for this test.')
payload = {'model': 'gemini-3.6-flash', 'prompt': 'Edit the attached image: preserve its composition and change the blue circle to green. Return the edited image.', 'n': 1, 'response_format': 'b64_json', 'image': 'data:'+mime+';base64,'+base64.b64encode(raw).decode()}
request = urllib.request.Request(args.base_url+'/openai/v1/images/generations', data=json.dumps(payload).encode(), headers={'Content-Type': 'application/json'}, method='POST')
with urllib.request.urlopen(request, timeout=360) as response:
    body = json.load(response)
result = base64.b64decode(body['data'][0]['b64_json'], validate=True)
extension = '.png' if result.startswith(b'\x89PNG\r\n\x1a\n') else '.jpg' if result.startswith(b'\xff\xd8') else None
if extension is None:
    raise SystemExit('The returned bytes are not PNG/JPEG.')
destination = args.output.with_suffix(extension)
destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_bytes(result)
print(json.dumps({'result': str(destination), 'bytes': len(result), 'source_bytes': len(raw)}))
