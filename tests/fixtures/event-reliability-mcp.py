"""Run production Event MCP code against a synthetic in-memory graph only."""
import importlib.util
from pathlib import Path
import sys

root, count_path = Path(sys.argv[1]), Path(sys.argv[2])
spec = importlib.util.spec_from_file_location('event_reliability_fixture', root / 'tests/event-reliability.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)
mcp, ev = fixture.mcp, fixture.ev
graph = fixture.Graph()
mcp._project_dir = lambda: fixture.SENDER
ev.load_env = lambda project: None
ev.rpc = graph.rpc
ev.kick = lambda project: None
original = mcp.call_tool

def call(name, args, token):
    if name in ('event_post', 'event_reply'):
        with count_path.open('a') as stream:
            stream.write('called\n')
    return original(name, args, token)

mcp.call_tool = call
mcp.main()
