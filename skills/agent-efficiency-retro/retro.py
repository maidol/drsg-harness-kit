#!/usr/bin/env python3
"""Claude Code 会话效率复盘：从 ~/.claude/projects 的 transcript 里统计「为什么慢」。

用法:
  retro.py --project <目录名的 glob> [--since ISO|epoch] [--until ISO|epoch]

  --project 匹配 ~/.claude/projects/ 下的目录名，例如 '-data-projects-sub2api*'
            （项目路径里的 / 和 . 都换成 -；worktree 会带 --claude-worktrees-<名>）。
  主会话 = 目录下的 *.jsonl；子代理 = */subagents/*.jsonl。

只读 transcript，不写任何东西。口径见同目录 SKILL.md。
"""
import argparse
import collections
import glob
import json
import os
import re
import statistics
from datetime import datetime, timezone

BINS = [(0, 50e3), (50e3, 100e3), (100e3, 200e3), (200e3, 300e3),
        (300e3, 400e3), (400e3, 500e3), (500e3, float('inf'))]


def ts(s):
    return datetime.fromisoformat(s.replace('Z', '+00:00')).timestamp()


def parse_time(s):
    if s is None:
        return None
    return float(s) if re.fullmatch(r'\d+(\.\d+)?', s) else ts(s)


def load(path, since, until):
    rows = []
    for line in open(path, errors='ignore'):
        try:
            o = json.loads(line)
        except ValueError:
            continue
        t = o.get('timestamp')
        if not t:
            continue
        t = ts(t)
        if (since and t < since) or (until and t > until):
            continue
        o['_t'] = t
        rows.append(o)
    return rows


def analyse(rows):
    """一个 transcript 文件 → 调用、轮次、耗时点、报错。"""
    calls = []            # (name, input)
    per_msg = collections.Counter()
    pending = {}
    lat = []              # (prompt_tokens, cache_hit_ratio, seconds, output_tokens)
    waits = []            # 等人的秒数
    nsf = []              # no such file 报错的命令
    seen_msg = set()
    prev_user_t = None
    last_t = None
    for o in rows:
        t, m = o['_t'], o.get('message') or {}
        if o.get('type') == 'assistant':
            mid = m.get('id')
            for c in m.get('content') or []:
                if isinstance(c, dict) and c.get('type') == 'tool_use' and c['id'] not in pending:
                    pending[c['id']] = (c['name'], c.get('input', {}))
                    calls.append((c['name'], c.get('input', {})))
                    per_msg[mid] += 1
            if mid not in seen_msg:
                seen_msg.add(mid)
                if prev_user_t is not None:
                    u = m.get('usage') or {}
                    inp = u.get('input_tokens', 0) or 0
                    cr = u.get('cache_read_input_tokens', 0) or 0
                    out = u.get('output_tokens', 0) or 0
                    dt = t - prev_user_t
                    if 0 < dt < 600 and inp + cr > 0:
                        lat.append((inp + cr, cr / (inp + cr), dt, out))
                    prev_user_t = None
        elif o.get('type') == 'user':
            content = m.get('content')
            if isinstance(content, str) and last_t is not None and t - last_t > 120:
                waits.append(t - last_t)
            if isinstance(content, list):
                for c in content:
                    if isinstance(c, dict) and c.get('type') == 'tool_result':
                        out = c.get('content')
                        out = out if isinstance(out, str) else json.dumps(out, ensure_ascii=False)
                        if 'no such file or directory' in out.lower():
                            name, inp = pending.get(c.get('tool_use_id'), ('?', {}))
                            nsf.append((inp.get('command') or inp.get('file_path') or name)[:80])
            prev_user_t = t
        last_t = t
    return calls, per_msg, lat, waits, nsf


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--project', required=True)
    ap.add_argument('--since')
    ap.add_argument('--until')
    a = ap.parse_args()
    since, until = parse_time(a.since), parse_time(a.until)
    base = os.path.expanduser('~/.claude/projects/')
    mains = glob.glob(base + a.project + '/*.jsonl')
    subs = glob.glob(base + a.project + '/*/subagents/*.jsonl')
    if not mains and not subs:
        raise SystemExit(f'没有匹配的 transcript：{base}{a.project}')

    agg = {'main': [], 'sub': []}
    per_msg = collections.Counter()
    lat, waits, nsf = [], [], []
    span = []
    for kind, files in (('main', mains), ('sub', subs)):
        for f in files:
            rows = load(f, since, until)
            if not rows:
                continue
            span += [rows[0]['_t'], rows[-1]['_t']]
            c, pm, la, w, n = analyse(rows)
            agg[kind] += c
            per_msg.update({(f, k): v for k, v in pm.items()})
            lat += la
            if kind == 'main':
                waits += w
            nsf += n

    allc = agg['main'] + agg['sub']
    fmt = lambda t: datetime.fromtimestamp(t, timezone.utc).strftime('%m-%d %H:%M')
    print(f'# 范围 {fmt(min(span))} → {fmt(max(span))} UTC，主会话文件 {len(mains)}，子代理文件 {len(subs)}')

    print('\n## 1. 工具调用（按 tool_use id 去重）')
    print(f'主会话 {len(agg["main"])} 次，子代理 {len(agg["sub"])} 次，合计 {len(allc)}')
    tools = collections.Counter(n for n, _ in allc)
    print('分布:', ', '.join(f'{k} {v}' for k, v in tools.most_common(12)))

    print('\n## 2. 一轮多调用比例')
    dist = collections.Counter(per_msg.values())
    multi = sum(v for k, v in dist.items() if k > 1)
    total = sum(dist.values())
    print(f'带工具的回复 {total} 次，其中一次发起多个调用的 {multi} 次（{multi / max(total, 1):.0%}）')

    print('\n## 3. 单轮耗时 vs 上下文（缓存命中 >90%、输出 <200 token 的轮）')
    print(f'{"上下文":>12} {"轮数":>6} {"中位":>7} {"p90":>7}')
    for lo, hi in BINS:
        s = sorted(p[2] for p in lat if lo <= p[0] < hi and p[1] > 0.9 and p[3] < 200)
        if len(s) >= 5:
            label = f'{int(lo / 1e3)}k-' + ('∞' if hi == float('inf') else f'{int(hi / 1e3)}k')
            print(f'{label:>12} {len(s):6d} {statistics.median(s):6.1f}s {s[int(len(s) * .9)]:6.1f}s')
    if lat:
        sizes = [p[0] for p in lat]
        print(f'全部轮次 n={len(lat)}，prompt 中位 {statistics.median(sizes) / 1e3:.0f}k，最大 {max(sizes) / 1e3:.0f}k；'
              f'模型轮次累计 {sum(p[2] for p in lat) / 60:.0f} 分')

    print('\n## 4. 重复劳动')
    reads = collections.Counter()
    gitc = collections.Counter()
    for n, i in allc:
        if n == 'Read':
            reads[os.path.basename(i.get('file_path', ''))] += 1
        if n == 'Bash':
            cmd = i.get('command', '')
            m = re.search(r'git (?:-C \S+ )?(status|diff|log|show)', cmd)
            if m:
                gitc[m.group(1)] += 1
    print('被 Read 最多的文件:', ', '.join(f'{f}×{k}' for f, k in reads.most_common(6)))
    print('git 只读检查:', dict(gitc))
    orch = sum(tools[k] for k in ('ListAgents', 'SendMessage', 'Agent', 'SubagentHandback'))
    # drsg-events 也以 mcp__drsg 开头，但它是待办通道不是代码图，单列。
    graph = sum(v for k, v in tools.items()
                if ('graph' in k or k.startswith('mcp__drsg')) and 'event' not in k)
    events = sum(v for k, v in tools.items() if k.startswith('mcp__drsg-events__'))
    print(f'子代理调度调用 {orch} 次；代码图调用 {graph} 次；Event 调用 {events} 次')

    print('\n## 5. 等人（主会话 >2 分钟空档且下一条是用户文字）')
    print(f'{len(waits)} 次，合计 {sum(waits) / 60:.0f} 分')

    print('\n## 6. no such file or directory')
    print(f'{len(nsf)} 次；前几条:')
    for c in nsf[:6]:
        print('  ', c.replace('\n', ' '))


if __name__ == '__main__':
    main()
