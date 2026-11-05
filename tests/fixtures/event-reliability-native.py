"""Opt-in native contract: local fake HTTP, production MCP + hook, no real model."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
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

mode = sys.argv[1]
assert mode in ('control', 'stop')
repo = Path(__file__).resolve().parents[2]
root = Path(tempfile.mkdtemp(prefix='event-reliability-native-' + mode + '-'))
for name in ('home', 'config', 'project'):
    (root / name).mkdir()
cli = Path(shutil.which('claude')).resolve()
assert hashlib.sha256(cli.read_bytes()).hexdigest() == 'b73676430af12f97316a798b8371f81d640f90a58bdcb8f3ce56a835bb47df56', 'NOT_RUN: native binary differs from verified fixture'
requests = []
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass
    def do_CONNECT(self):
        self.send_error(502)
    def do_GET(self):
        self.send_error(404)
    def do_POST(self):
        size = int(self.headers.get('Content-Length', '0'))
        if not 0 < size <= 8_000_000:
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
        number = len(requests) + 1
        requests.append({'n': number, 'validation_seen': 'EVENT_POST_ERROR ' in json.dumps(body.get('messages', []))})
        matching = [t['name'] for t in body.get('tools', []) if t['name'].endswith('__event_post')]
        assert len(matching) == 1
        use_tool = number <= 20
        message = {'id': 'msg_synthetic_' + str(number), 'type': 'message', 'role': 'assistant', 'model': body.get('model'), 'content': [], 'stop_reason': None, 'stop_sequence': None, 'usage': {'input_tokens': 100, 'output_tokens': 0}}
        block = {'type': 'tool_use', 'id': 'toolu_synthetic_' + str(number), 'name': matching[0], 'input': {}} if use_tool else {'type': 'text', 'text': ''}
        arguments = {'recipient': '/synthetic/reviewer', 'summary': 'synthetic receipt', 'reply_to': 'incoming', 'supersedes': 'incoming'}
        delta = {'type': 'input_json_delta', 'partial_json': json.dumps(arguments)} if use_tool else {'type': 'text_delta', 'text': 'Synthetic fixture complete.'}
        events = [{'type': 'message_start', 'message': message}, {'type': 'content_block_start', 'index': 0, 'content_block': block}, {'type': 'content_block_delta', 'index': 0, 'delta': delta}, {'type': 'content_block_stop', 'index': 0}, {'type': 'message_delta', 'delta': {'stop_reason': 'tool_use' if use_tool else 'end_turn', 'stop_sequence': None}, 'usage': {'output_tokens': 5}}, {'type': 'message_stop'}]
        data = ''.join('event: ' + e['type'] + '\ndata: ' + json.dumps(e) + '\n\n' for e in events).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass
server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
base = 'http://127.0.0.1:' + str(server.server_port)
command = shlex.join([sys.executable, '-I', str(repo / 'tools/templates/hooks/event_retry_guard.py')])
hooks = {phase: [{'matcher': 'mcp__drsg-events__event_post|mcp__drsg-events__event_reply', 'hooks': [{'type': 'command', 'command': command, 'timeout': 3}]}] for phase in ('PreToolUse', 'PostToolUseFailure')} if mode == 'stop' else {}
settings = {'autoMemoryEnabled': False, 'autoDreamEnabled': False, 'syncClaudeAiSkills': False, 'syncClaudeAiPlugins': False, 'disableClaudeAiConnectors': True, 'disableAgentView': True, 'disableRemoteControl': True, 'enableWorkflows': False, 'autoUploadSessions': False, 'promptSuggestionEnabled': False, 'hooks': hooks}
mcp = {'mcpServers': {'drsg-events': {'command': sys.executable, 'args': ['-I', str(repo / 'tests/fixtures/event-reliability-mcp.py'), str(repo), str(root / 'mcp-calls')]}}}
env = {'PATH': '/usr/local/bin:/usr/bin:/bin', 'HOME': str(root / 'home'), 'CLAUDE_CONFIG_DIR': str(root / 'config'), 'DRSG_MEM_DIR': str(root / 'state'), 'DRSG_TOKEN': 'synthetic', 'TMPDIR': str(root), 'ANTHROPIC_BASE_URL': base, 'ANTHROPIC_AUTH_TOKEN': 'synthetic', 'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC': '1', 'DISABLE_AUTOUPDATER': '1', 'DISABLE_TELEMETRY': '1', 'DISABLE_ERROR_REPORTING': '1', 'HTTP_PROXY': base, 'HTTPS_PROXY': base, 'NO_PROXY': '127.0.0.1,localhost', 'SHELL': '/bin/bash', 'TERM': 'dumb'}
args = [str(cli), '--print', '--restricted', '--setting-sources', '', '--settings', json.dumps(settings), '--strict-mcp-config', '--mcp-config', json.dumps(mcp), '--disable-slash-commands', '--tools', '', '--allowedTools', 'mcp__drsg-events__event_post', '--no-session-persistence', '--system-prompt', 'Synthetic fixture.', '--model', 'claude-opus-5-5', '--input-format', 'stream-json', '--output-format', 'stream-json', '--include-hook-events', '--verbose']
proc = subprocess.Popen(args, cwd=root / 'project', env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
try:
    stdout, stderr = proc.communicate(json.dumps({'type': 'user', 'message': {'role': 'user', 'content': 'Synthetic local test.'}}) + '\n', timeout=45)
except subprocess.TimeoutExpired:
    os.killpg(proc.pid, signal.SIGTERM)
    try:
        stdout, stderr = proc.communicate(timeout=4)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL)
        stdout, stderr = proc.communicate(timeout=4)
    raise RuntimeError('NOT_RUN: native probe timed out')
finally:
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    server.shutdown()
    server.server_close()
executions = len((root / 'mcp-calls').read_text().splitlines()) if (root / 'mcp-calls').exists() else 0
result = {'mode': mode, 'model_requests': len(requests), 'mcp_executions': executions, 'exit': proc.returncode, 'stop_marker': 'Event request stopped:' in stdout + stderr}
(root / 'evidence.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result))
assert proc.returncode == 0, 'native fixture did not complete normally'
if mode == 'stop':
    assert len(requests) == 2 and executions == 1 and result['stop_marker'], 'native repeat was not denied and stopped'
else:
    assert len(requests) == 21 and executions == 20 and not result['stop_marker'], 'control did not replay twenty failures'
