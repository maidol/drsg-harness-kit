"""Native CLI transport gate, deterministic local HTTP fixture, never an LLM."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time

parser = argparse.ArgumentParser()
parser.add_argument('mode', choices=('baseline', 'tool', 'stop'))
parser.add_argument('--hook', default=str(Path(__file__).with_name('todo52-relay-probe-hook.py')))
options = parser.parse_args()
mode = options.mode
cli = Path(shutil.which('claude')).resolve()
hash_before = hashlib.sha256(cli.read_bytes()).hexdigest()
assert hash_before == 'b73676430af12f97316a798b8371f81d640f90a58bdcb8f3ce56a835bb47df56'
root = Path(tempfile.mkdtemp(prefix='todo52-relay-' + mode + '-'))
for name in ('home', 'config', 'project'):
    (root / name).mkdir()
(root / 'project' / 'synthetic.txt').write_text('Synthetic tool result.\n')
requests = []
stream = []
finished = threading.Event()

class Todo52RelayHTTPHandler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_CONNECT(self):
        self.send_error(502)

    def do_GET(self):
        self.send_error(404)

    def do_POST(self):
        size = int(self.headers.get('Content-Length', '0'))
        if not 0 <= size <= 4_000_000:
            self.send_error(413)
            return
        body = json.loads(self.rfile.read(size))
        if self.path.split('?')[0] == '/v1/messages/count_tokens':
            data = b'{"input_tokens":100}'
            self.send_response(200)
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if self.path.split('?')[0] != '/v1/messages':
            self.send_error(404)
            return
        # Synthetic requests stay in memory; only structural assertions are saved.
        texts = json.dumps(body.get('messages', []), ensure_ascii=False)
        observation = {'request': len(requests) + 1,
                       'wake_body': 'SYNTHETIC_TODO52_WAKE' in texts,
                       'wake_wrapper': 'Stop hook blocking error from command' in texts,
                       'relay_body': 'SYNTHETIC_RELAY_BODY' in texts,
                       'key': 'event-synthetic-52' in texts,
                       'ref': 'synthetic-plan' in texts,
                       'owner': 'synthetic-lane' in texts}
        requests.append(observation)
        if len(requests) == 1:
            (root / 'release').touch()
            deadline = time.monotonic() + 3
            while not (root / 'flushed').exists() and time.monotonic() < deadline:
                time.sleep(.002)
        tool = (mode == 'tool' and observation['wake_wrapper']
                and not any(r.get('tool_response') for r in requests[:-1]))
        observation['tool_response'] = tool
        if observation['relay_body'] or mode == 'baseline' and len(requests) >= 2:
            finished.set()
        model = body.get('model', 'claude-opus-5-5')
        message = {'id': 'msg_synthetic_' + str(len(requests)), 'type': 'message',
                   'role': 'assistant', 'model': model, 'content': [],
                   'stop_reason': None, 'stop_sequence': None,
                   'usage': {'input_tokens': 100, 'output_tokens': 0}}
        if tool:
            block = {'type': 'tool_use', 'id': 'toolu_synthetic', 'name': 'Read',
                     'input': {'file_path': str(root / 'project' / 'synthetic.txt')}}
        else:
            block = {'type': 'text', 'text': 'Synthetic fixture complete.'}
        events = [{'type': 'message_start', 'message': message},
                  {'type': 'content_block_start', 'index': 0, 'content_block':
                   {**block, 'input': {}} if tool else {'type': 'text', 'text': ''}},
                  {'type': 'content_block_delta', 'index': 0, 'delta':
                   {'type': 'input_json_delta', 'partial_json': json.dumps(block['input'])}
                   if tool else {'type': 'text_delta', 'text': block['text']}},
                  {'type': 'content_block_stop', 'index': 0},
                  {'type': 'message_delta', 'delta': {
                      'stop_reason': 'tool_use' if tool else 'end_turn',
                      'stop_sequence': None}, 'usage': {'output_tokens': 5}},
                  {'type': 'message_stop'}]
        data = ''.join('event: ' + item['type'] + '\ndata: ' + json.dumps(item) + '\n\n'
                       for item in events).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

server = ThreadingHTTPServer(('127.0.0.1', 0), Todo52RelayHTTPHandler)
threading.Thread(target=server.serve_forever, daemon=True).start()
base = 'http://127.0.0.1:' + str(server.server_port)
hook_script = str(Path(options.hook).resolve())
def command(phase):
    return shlex.join([sys.executable, '-I', hook_script, str(root), mode, phase])

hooks = {'SessionStart': [{'hooks': [{'type': 'command', 'command': command('wake'),
                                    'asyncRewake': True, 'timeout': 15}]}]}
if mode != 'baseline':
    hooks['Stop'] = [{'hooks': [{'type': 'command', 'command': command('Stop'), 'timeout': 3}]}]
    hooks['PostToolUse'] = [{'matcher': '*', 'hooks': [
        {'type': 'command', 'command': command('PostToolUse'), 'timeout': 3}]}]
settings = {'autoMemoryEnabled': False, 'autoDreamEnabled': False,
            'syncClaudeAiSkills': False, 'syncClaudeAiPlugins': False,
            'disableClaudeAiConnectors': True, 'disableAgentView': True,
            'disableRemoteControl': True, 'enableWorkflows': False,
            'autoUploadSessions': False, 'promptSuggestionEnabled': False, 'hooks': hooks}
env = {'PATH': '/usr/local/bin:/usr/bin:/bin', 'HOME': str(root / 'home'),
       'CLAUDE_CONFIG_DIR': str(root / 'config'), 'TMPDIR': str(root),
       'ANTHROPIC_BASE_URL': base, 'ANTHROPIC_AUTH_TOKEN': 'synthetic',
       'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC': '1', 'DISABLE_AUTOUPDATER': '1',
       'DISABLE_TELEMETRY': '1', 'DISABLE_ERROR_REPORTING': '1',
       'HTTP_PROXY': base, 'HTTPS_PROXY': base, 'NO_PROXY': '127.0.0.1,localhost',
       'SHELL': '/bin/bash', 'TERM': 'dumb'}
args = [str(cli), '--print', '--restricted', '--setting-sources', '',
        '--settings', json.dumps(settings), '--strict-mcp-config', '--mcp-config',
        '{"mcpServers":{}}', '--disable-slash-commands', '--tools', 'Read',
        '--allowedTools', 'Read', '--no-session-persistence', '--system-prompt',
        'Synthetic transport fixture.', '--model', 'claude-opus-5-5',
        '--input-format', 'stream-json', '--output-format', 'stream-json',
        '--include-hook-events', '--verbose']
proc = subprocess.Popen(args, cwd=root / 'project', env=env, stdin=subprocess.PIPE,
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                        start_new_session=True)
def drain(pipe, channel):
    for line in pipe:
        try:
            value = json.loads(line)
            stream.append({'channel': channel, 'type': value.get('type'),
                           'subtype': value.get('subtype'), 'event': value.get('hook_event'),
                           'exit': value.get('exit_code'),
                           'error': bool(value.get('is_error'))})
        except ValueError:
            stream.append({'channel': channel, 'unparsed_chars': len(line)})
readers = [threading.Thread(target=drain, args=(p, c), daemon=True)
           for p, c in ((proc.stdout, 'stdout'), (proc.stderr, 'stderr'))]
for reader in readers:
    reader.start()
try:
    proc.stdin.write(json.dumps({'type': 'user', 'message': {
        'role': 'user', 'content': 'Synthetic initial prompt.'}}) + '\n')
    proc.stdin.flush()
    finished.wait(18)
    proc.stdin.close()
    try:
        proc.wait(timeout=3)
    except subprocess.TimeoutExpired:
        pass
finally:
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        proc.wait(timeout=4)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL)
        proc.wait(timeout=4)
    for reader in readers:
        reader.join(timeout=2)
    server.shutdown()
    server.server_close()
trace = [json.loads(line) for line in (root / 'hooks.jsonl').read_text().splitlines()] \
    if (root / 'hooks.jsonl').exists() else []
result = {'mode': mode, 'root': str(root), 'requests': requests, 'hooks': trace,
          'finished': finished.is_set(), 'stream': stream, 'cli_sha256': hash_before}
(root / 'evidence.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps({k: result[k] for k in ('mode', 'root', 'requests', 'hooks', 'finished')}, ensure_ascii=False))
assert len(requests) >= 2, 'native asynchronous wake was not exercised'
assert any(r['wake_wrapper'] and not r['wake_body'] and not r['relay_body']
           for r in requests[1:]), 'empty wake not reproduced'
assert any(r['relay_body'] and r['key'] and r['ref'] and r['owner'] for r in requests), 'relay body absent from native model request'
if mode == 'stop':
    assert any(h['phase'] == 'Stop' and h['active'] is True for h in trace), 'active Stop not exercised'
