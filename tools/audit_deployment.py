#!/usr/bin/env python3
"""audit_deployment.py — comprehensive layered deployment audit for drsg-harness-kit.

Encodes the operational lesson: "全量部署审计需分层"
A simple hook comparison is necessary but insufficient. A full audit verifies:
  Layer 0: Project Discovery (only in --all mode: verifies daemon & project listing)
  Layer 1: Global Runtime Tools (~/.drsg-memory/tools/ vs HEAD/bundle tools/)
  Layer 2: Global Configuration & Skills (~/.claude/ rules, skills, hooks, permissions)
  Layer 3: Project Memory Hooks (<proj>/.claude/hooks/ vs templates/hooks/)
  Layer 4: Project Settings & Docs (settings.local.json, CLAUDE.md Event block, .drsg/env)
  Layer 5: Code Graph Health (daemon connectivity & status where deployed)

Usage:
  python3 audit_deployment.py [--project DIR] [--all] [--json] [--repo DIR]
                              [--tools-dir DIR] [--claude-dir DIR]
"""

import argparse
import hashlib
import json
import os
import subprocess
import sys
import urllib.request


def digest(data_bytes):
    if data_bytes is None:
        return None
    return hashlib.sha256(data_bytes).hexdigest()


def digest_file(path):
    try:
        with open(path, "rb") as fh:
            return digest(fh.read())
    except Exception:
        return None


def is_executable(path):
    return os.path.exists(path) and os.access(path, os.X_OK)


def get_default_paths(script_dir):
    repo_dir = os.path.normpath(os.path.join(script_dir, ".."))
    if not os.path.exists(os.path.join(repo_dir, "setup.sh")):
        repo_dir = script_dir  # deployed mode under tools/
    home = os.environ.get("HOME", "")
    mem_dir = os.environ.get("DRSG_MEM_DIR", os.path.join(home, ".drsg-memory"))
    claude_dir = os.environ.get("CLAUDE_CONFIG_DIR", os.path.join(home, ".claude"))
    return repo_dir, mem_dir, claude_dir


def is_git_repo(repo_dir):
    try:
        res = subprocess.run(
            ["git", "-C", repo_dir, "rev-parse", "--is-inside-work-tree"],
            capture_output=True, text=True
        )
        return res.returncode == 0 and res.stdout.strip() == "true"
    except Exception:
        return False


def check_layer1(repo_dir, repo_tools_dir, deployed_tools_dir):
    """Layer 1: Global Runtime Tools.

    R2 & P3: Compare against git HEAD when in a git worktree.
    Only files tracked in HEAD are compared; untracked files are not missing.
    Uncommitted working tree changes are noted as hints, not counted as drift.
    """
    res = {"name": "L1: Global Runtime Tools", "ok": True, "details": []}
    if not os.path.isdir(deployed_tools_dir):
        res["ok"] = False
        res["details"].append(f"Deployed tools directory missing: {deployed_tools_dir}")
        return res

    ignored = {"logs", "__pycache__", "benchmark"}
    diffs = []
    missing = []
    notes = []

    if is_git_repo(repo_dir):
        # 1. Enumerate files in HEAD tools/
        try:
            cmd = ["git", "-C", repo_dir, "ls-tree", "-r", "--name-only", "HEAD", "tools/"]
            tree_out = subprocess.check_output(cmd, text=True)
            head_paths = [p.strip() for p in tree_out.splitlines() if p.strip()]
        except Exception as e:
            res["ok"] = False
            res["details"].append(f"Failed to list git HEAD tools: {e}")
            return res

        for path_in_repo in head_paths:
            rel = os.path.relpath(path_in_repo, "tools")
            parts = rel.split(os.sep)
            if any(p in ignored for p in parts):
                continue
            deployed_fpath = os.path.join(deployed_tools_dir, rel)
            if not os.path.exists(deployed_fpath):
                missing.append(rel)
                continue

            # Get HEAD content bytes
            try:
                head_bytes = subprocess.check_output(
                    ["git", "-C", repo_dir, "show", f"HEAD:{path_in_repo}"]
                )
                d_head = digest(head_bytes)
            except Exception:
                d_head = None

            d_dep = digest_file(deployed_fpath)
            if d_head != d_dep:
                diffs.append(f"{rel} (hash mismatch vs HEAD: {d_dep[:8] if d_dep else 'none'} != {d_head[:8] if d_head else 'none'})")
            elif os.path.dirname(rel) == "" and (rel.endswith((".sh", ".py")) or rel == "drsg-usage-report"):
                if not is_executable(deployed_fpath):
                    diffs.append(f"{rel} (not executable in deployment)")

        # 2. Check uncommitted changes in tools/ for advisory notice
        try:
            status_out = subprocess.check_output(
                ["git", "-C", repo_dir, "status", "--porcelain", "--", "tools/"],
                text=True
            )
            for line in status_out.splitlines():
                if line.strip():
                    parts = line.strip().split(maxsplit=1)
                    if len(parts) == 2:
                        dirty_rel = os.path.relpath(parts[1], "tools")
                        notes.append(f"uncommitted changes in repo working tree: {dirty_rel} (not counted as drift)")
        except Exception:
            pass
    else:
        # Fallback to filesystem comparison when not in git repo (bundle mode)
        repo_files = {}
        for root, dirs, files in os.walk(repo_tools_dir):
            dirs[:] = [d for d in dirs if d not in ignored]
            for f in files:
                rel = os.path.relpath(os.path.join(root, f), repo_tools_dir)
                repo_files[rel] = os.path.join(root, f)

        for rel, repo_fpath in sorted(repo_files.items()):
            deployed_fpath = os.path.join(deployed_tools_dir, rel)
            if not os.path.exists(deployed_fpath):
                missing.append(rel)
                continue
            d_repo = digest_file(repo_fpath)
            d_dep = digest_file(deployed_fpath)
            if d_repo != d_dep:
                diffs.append(f"{rel} (hash mismatch: {d_dep[:8]} != {d_repo[:8]})")
            elif os.path.dirname(rel) == "" and (rel.endswith((".sh", ".py")) or rel == "drsg-usage-report"):
                if not is_executable(deployed_fpath):
                    diffs.append(f"{rel} (not executable in deployment)")

    if missing:
        res["ok"] = False
        res["details"].extend([f"Missing in deployment: {m}" for m in missing])
    if diffs:
        res["ok"] = False
        res["details"].extend([f"Drift in tools: {d}" for d in diffs])
    if not missing and not diffs:
        res["details"].append("All runtime tools in sync with release baseline and executable")
    if notes:
        res["details"].extend(notes)
    return res


def check_layer2(repo_dir, claude_dir):
    """Layer 2: Global Configuration & Skills.

    Includes N2: settings.json permissions 0600.
    """
    res = {"name": "L2: Global Configuration & Skills", "ok": True, "details": []}
    issues = []

    # 1. AGENT-EFFICIENCY.md
    repo_eff = os.path.join(repo_dir, "claude", "AGENT-EFFICIENCY.md")
    dep_eff = os.path.join(claude_dir, "AGENT-EFFICIENCY.md")
    if os.path.exists(repo_eff):
        if not os.path.exists(dep_eff):
            issues.append(f"Missing {dep_eff}")
        elif digest_file(repo_eff) != digest_file(dep_eff):
            issues.append(f"Drift in {dep_eff} vs repository source")

    # 2. @AGENT-EFFICIENCY.md in CLAUDE.md
    global_claude_md = os.path.join(claude_dir, "CLAUDE.md")
    if os.path.exists(global_claude_md):
        with open(global_claude_md, encoding="utf-8") as f:
            c = f.read()
        if "@AGENT-EFFICIENCY.md" not in c:
            issues.append(f"Missing @AGENT-EFFICIENCY.md import in {global_claude_md}")
    else:
        issues.append(f"Missing global {global_claude_md}")

    # 3. Global skills
    skills_dir = os.path.join(claude_dir, "skills")
    bundled_skills = ["agent-efficiency-retro", "codegraph", "diagram-conventions"]
    repo_skills = os.path.join(repo_dir, "skills")
    if os.path.isdir(repo_skills):
        for sk in bundled_skills:
            r_sk = os.path.join(repo_skills, sk)
            d_sk = os.path.join(skills_dir, sk)
            if not os.path.isdir(d_sk):
                issues.append(f"Skill {sk} not installed in {skills_dir}")
                continue
            for fname in os.listdir(r_sk):
                if fname.startswith("."):
                    continue
                r_file = os.path.join(r_sk, fname)
                d_file = os.path.join(d_sk, fname)
                if os.path.isfile(r_file):
                    if not os.path.isfile(d_file) or digest_file(r_file) != digest_file(d_file):
                        issues.append(f"Skill file drift: {sk}/{fname}")

    # 4. Global settings hooks & permissions (N2)
    settings_file = os.path.join(claude_dir, "settings.json")
    if os.path.exists(settings_file):
        try:
            st = os.stat(settings_file)
            if (st.st_mode & 0o077) != 0:
                issues.append(f"settings.json permissions not 0600 (found 0{oct(st.st_mode & 0o777)[2:]})")

            with open(settings_file, encoding="utf-8") as f:
                sdata = json.load(f)
            hooks = sdata.get("hooks", {})
            commands = [
                h.get("command", "")
                for group_list in hooks.values()
                for group in group_list
                for h in group.get("hooks", [])
            ]
            has_poller = any("event-poller" in cmd for cmd in commands)
            has_streak = any("single-tool-streak" in cmd for cmd in commands)
            if not has_poller:
                issues.append("Global event-poller hook missing in settings.json")
            if not has_streak:
                issues.append("Global single-tool-streak hook missing in settings.json")
        except Exception as e:
            issues.append(f"Error reading {settings_file}: {e}")
    else:
        issues.append(f"Missing {settings_file}")

    if issues:
        res["ok"] = False
        res["details"] = issues
    else:
        res["details"].append("AGENT-EFFICIENCY.md, skills, settings.json permissions and hooks fully configured")
    return res


def get_known_projects(mem_dir, default_addr="127.0.0.1:7700", plane="memory"):
    """Fetch known projects from memory daemon.

    R3: Reads DRSG_API from env or daemon env file, uses no-proxy opener,
    and returns (projects, error_msg) instead of swallowing errors.
    """
    daemon_env = os.path.join(mem_dir, "env")
    token = ""
    api = os.environ.get("DRSG_API", "")
    if os.path.exists(daemon_env):
        with open(daemon_env, encoding="utf-8") as f:
            for line in f:
                if line.startswith("DRSG_TOKEN="):
                    token = line.split("=", 1)[1].strip().strip('"').strip("'")
                elif line.startswith("DRSG_API=") and not api:
                    api = line.split("=", 1)[1].strip().strip('"').strip("'")

    if not api:
        http_base = default_addr.replace("http://", "").replace("https://", "")
        api = f"http://{http_base}/rpc"

    body = json.dumps({
        "jsonrpc": "2.0", "id": 1, "method": "plane.cypher",
        "params": {"plane": plane, "query": "MATCH (p:Project) RETURN p"}
    }).encode()

    req = urllib.request.Request(
        api, data=body,
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {token}"}
    )

    # Use no-proxy opener to avoid http_proxy intercepting 127.0.0.1
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(req, timeout=5) as r:
            out = json.load(r)
        if "error" in out:
            return [], f"Daemon error from {api}: {out['error']}"
        seen = []
        for n in out.get("result", {}).get("nodes", []):
            p = (n.get("properties") or {}).get("path")
            p = p.get("$value") if isinstance(p, dict) else p
            if p and p not in seen:
                seen.append(p)
        if not seen:
            return [], f"Memory plane '{plane}' returned 0 Project nodes"
        return seen, None
    except Exception as e:
        return [], f"Failed to query {api}: {e}"


def check_layer3(templates_dir, project_dir):
    """Layer 3: Project Memory Hooks.

    N4: Drop unreliable mtime check, report hash mismatch directly.
    """
    res = {"name": f"L3: Hooks ({os.path.basename(project_dir)})", "ok": True, "details": []}
    hooks_dir = os.path.join(project_dir, ".claude", "hooks")
    if not os.path.isdir(hooks_dir):
        res["ok"] = False
        res["details"].append("No .claude/hooks installed")
        return res

    templates = {
        n: digest_file(os.path.join(templates_dir, n))
        for n in sorted(os.listdir(templates_dir))
        if n.endswith(".py")
    }
    issues = []
    for name, want in templates.items():
        hook_path = os.path.join(hooks_dir, name)
        if not os.path.exists(hook_path):
            issues.append(f"{name}: missing")
            continue
        got = digest_file(hook_path)
        if got != want:
            issues.append(f"{name}: hash mismatch (deployment != template)")
        elif not is_executable(hook_path):
            issues.append(f"{name}: not executable")

    if issues:
        res["ok"] = False
        res["details"] = issues
    else:
        res["details"].append(f"All {len(templates)} hook templates matching and executable")
    return res


REQUIRED_MCP = ("drsg", "drsg-events")


def claude_json_path(claude_dir, explicit):
    """Where Claude Code keeps per-project MCP registrations: inside the
    config dir when that is moved (CLAUDE_CONFIG_DIR, or --claude-dir here),
    otherwise ~/.claude.json next to ~/.claude/."""
    if explicit or os.environ.get("CLAUDE_CONFIG_DIR"):
        return os.path.join(claude_dir, ".claude.json")
    return os.path.join(os.environ.get("HOME", ""), ".claude.json")


def mcp_issues(project_dir, claude_json, tools_dir):
    """One line per REQUIRED_MCP server this project's sessions will not load.

    A registration can vanish with no install step removing it: on 2026-10-07
    the kit project lost drsg-events while every other layer kept passing.
    So read what Claude Code itself loads - local scope (projects[dir]) and
    user scope (top-level mcpServers) of .claude.json."""
    try:
        with open(claude_json, encoding="utf-8") as f:
            cfg = json.load(f)
    except Exception as e:
        return [f"Cannot read {claude_json} for MCP registrations: {e}"]
    names = set(cfg.get("mcpServers") or {})
    proj = (cfg.get("projects") or {}).get(project_dir) or {}
    names |= set(proj.get("mcpServers") or {})
    issues = []
    for name in REQUIRED_MCP:
        if name in names:
            continue
        if name == "drsg-events":
            fix = (f"(cd {project_dir} && claude mcp add --scope local drsg-events -- "
                   f"python3 {os.path.join(tools_dir, 'mcp_events.py')} {project_dir})")
        else:
            fix = f"setup.sh --project {project_dir} --token <the running daemon's token>"
        issues.append(f"MCP server not registered for this project: {name} - fix: {fix}")
    return issues


def check_layer4(project_dir, claude_json=None, tools_dir=None):
    """Layer 4: Project Settings & Docs.

    N1: Report missing CLAUDE.md when hooks are installed.
    F3: Report drsg / drsg-events MCP servers missing for the project.
    """
    res = {"name": f"L4: Settings & Docs ({os.path.basename(project_dir)})", "ok": True, "details": []}
    issues = []

    # 1. settings.local.json hooks
    settings_local = os.path.join(project_dir, ".claude", "settings.local.json")
    if not os.path.exists(settings_local):
        issues.append("Missing .claude/settings.local.json")
    else:
        try:
            with open(settings_local, encoding="utf-8") as f:
                d = json.load(f)
            hooks = d.get("hooks", {})
            commands = [
                h.get("command", "")
                for glist in hooks.values()
                for g in glist
                for h in g.get("hooks", [])
            ]
            for script_name in ["session_start.py", "user_prompt.py", "session_end.py"]:
                if not any(script_name in cmd for cmd in commands):
                    issues.append(f"Hook not registered in settings.local.json: {script_name}")
        except Exception as e:
            issues.append(f"Error reading settings.local.json: {e}")

    # 2. .drsg/env
    env_file = os.path.join(project_dir, ".drsg", "env")
    if not os.path.exists(env_file):
        issues.append("Missing .drsg/env")
    else:
        with open(env_file, encoding="utf-8") as f:
            env_content = f.read()
        if "DRSG_TOKEN=" not in env_content or "DRSG_API=" not in env_content:
            issues.append(".drsg/env missing DRSG_TOKEN or DRSG_API")

    # 3. CLAUDE.md Event block & N1 check
    claude_md = os.path.join(project_dir, "CLAUDE.md")
    hooks_installed = os.path.isdir(os.path.join(project_dir, ".claude", "hooks"))
    if os.path.exists(claude_md):
        with open(claude_md, encoding="utf-8") as f:
            cmd_content = f.read()
        has_event_block = ("<!-- drsg-memory:events:begin -->" in cmd_content) or (
            "event.py" in cmd_content and "drsg-events" in cmd_content
        )
        if not has_event_block:
            issues.append("CLAUDE.md lacks cross-agent Event documentation block")
    elif hooks_installed:
        issues.append("Missing CLAUDE.md while hooks are installed")

    # 4. pre-commit completeness-guard status
    git_dir = os.path.join(project_dir, ".git")
    if os.path.isdir(git_dir):
        pre_commit = os.path.join(git_dir, "hooks", "pre-commit")
        if os.path.exists(pre_commit):
            try:
                with open(pre_commit, encoding="utf-8") as f:
                    c = f.read()
                if "completeness-guard" in c:
                    res["details"].append("completeness-guard pre-commit hook active")
                else:
                    res["details"].append("custom pre-commit hook present (guard skipped)")
            except Exception:
                pass
        else:
            res["details"].append("no pre-commit hook present")

    # 5. MCP servers the project's sessions load
    if claude_json:
        issues.extend(mcp_issues(project_dir, claude_json, tools_dir or ""))

    if issues:
        res["ok"] = False
        res["details"] = issues
    else:
        res["details"].append("Hooks registered, .drsg/env present, Event block documented"
                              + (", MCP drsg + drsg-events registered" if claude_json else ""))
    return res


def check_layer5(project_dir, tools_dir):
    """Layer 5: Code Graph Status.

    R1 & P2:
    Order of checks:
      1. If output contains WARNING: .mcp.json points at or health: FAILING -> DRIFT.
      2. If returncode == 0 -> OK (daemon running and reachable).
      3. If output contains 'not running' or 'nothing holds its database':
         check if database exists (graph.drsg).
         If DB exists -> OK (stopped, started on demand).
         If DB missing -> DRIFT (database missing).
      4. Any other non-zero -> DRIFT.
    """
    res = {"name": f"L5: Code Graph ({os.path.basename(project_dir)})", "ok": True, "details": []}
    mcp_json = os.path.join(project_dir, ".mcp.json")
    graph_drsg = os.path.join(project_dir, "graph.drsg")
    if not os.path.exists(mcp_json) and not os.path.exists(graph_drsg):
        res["details"].append("Code graph not enabled for this project (skipped)")
        return res

    codegraph_sh = os.path.join(tools_dir, "codegraph.sh")
    if os.path.exists(codegraph_sh):
        try:
            cmd = [codegraph_sh, "status", "--dir", project_dir]
            proc = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
            combined = (proc.stdout + "\n" + proc.stderr).strip()

            # P2 step 1: check warnings and health failure first
            if "WARNING: .mcp.json points at" in combined or "health: FAILING" in combined:
                res["ok"] = False
                res["details"].append(f"Code graph configuration mismatch or failing: {combined}")
                return res

            # P2 step 2: exit code 0 is running OK
            if proc.returncode == 0:
                res["details"].append("Code graph daemon running and reachable")
                return res

            # P2 step 3: not running, check if database exists
            if "not running" in combined or "nothing holds its database" in combined:
                db_path = os.environ.get("DRSG_CODE_DB", graph_drsg)
                if os.path.exists(db_path):
                    res["details"].append("stopped (started on demand)")
                    return res
                else:
                    res["ok"] = False
                    res["details"].append(f"Code graph stopped and database missing at {db_path}")
                    return res

            # P2 step 4: other non-zero exit
            res["ok"] = False
            res["details"].append(f"codegraph.sh status failed (exit {proc.returncode}): {combined}")
        except Exception as e:
            res["ok"] = False
            res["details"].append(f"Failed to check code graph: {e}")
    else:
        res["details"].append("codegraph.sh not found; skipping daemon probe")
    return res


def main():
    parser = argparse.ArgumentParser(description="Audit deployment layers for drsg-harness-kit.")
    parser.add_argument("--project", help="Audit specific project directory.")
    parser.add_argument("--all", action="store_true", help="Audit all known projects in memory plane.")
    parser.add_argument("--json", action="store_true", help="Output JSON format.")
    parser.add_argument("--repo", help="Repository root path (defaults to parent of tools/).")
    parser.add_argument("--tools-dir", help="Override deployed tools directory (~/.drsg-memory/tools).")
    parser.add_argument("--claude-dir", help="Override global claude directory (~/.claude).")
    args = parser.parse_args()

    script_dir = os.path.dirname(os.path.realpath(__file__))
    repo_dir, mem_dir, claude_dir = get_default_paths(script_dir)
    if args.repo:
        repo_dir = os.path.abspath(args.repo)
    if args.tools_dir:
        deployed_tools = os.path.abspath(args.tools_dir)
    else:
        deployed_tools = os.path.join(mem_dir, "tools")
    if args.claude_dir:
        claude_dir = os.path.abspath(args.claude_dir)
    claude_json = claude_json_path(claude_dir, bool(args.claude_dir))

    repo_tools = os.path.join(repo_dir, "tools")
    templates_dir = os.path.join(repo_tools, "templates", "hooks")
    if not os.path.isdir(templates_dir):
        templates_dir = os.path.join(deployed_tools, "templates", "hooks")

    report = {"layers": [], "overall_ok": True}

    # Layer 0 (only on --all)
    projects = []
    if args.project:
        projects = [os.path.abspath(args.project)]
    elif args.all:
        projs, disc_err = get_known_projects(mem_dir)
        l0 = {"name": "L0: Project Discovery", "ok": True, "details": []}
        if disc_err or not projs:
            l0["ok"] = False
            l0["details"].append(disc_err or "No projects discovered in memory plane")
            report["layers"].append(l0)
            report["overall_ok"] = False
            if args.json:
                print(json.dumps(report, indent=2, ensure_ascii=False))
            else:
                print("=== drsg-harness-kit Layered Deployment Audit ===")
                print("\n[✗ DRIFT] L0: Project Discovery")
                for det in l0["details"]:
                    print(f"      • {det}")
                print("\n" + ("=" * 48))
                print("Audit Result: FAILED (discovery failure)")
            sys.exit(1)
        else:
            l0["details"].append(f"Discovered {len(projs)} project(s) in memory plane")
            report["layers"].append(l0)
            projects = projs
    else:
        cwd = os.getcwd()
        projects = [cwd]

    # Layer 1
    l1 = check_layer1(repo_dir, repo_tools, deployed_tools)
    report["layers"].append(l1)

    # Layer 2
    l2 = check_layer2(repo_dir, claude_dir)
    report["layers"].append(l2)

    for p in projects:
        if not os.path.isdir(p):
            continue

        # N3: support .drsg/audit-skip
        skip_file = os.path.join(p, ".drsg", "audit-skip")
        if os.path.exists(skip_file):
            report["layers"].append({
                "name": f"Project: {os.path.basename(p)}",
                "ok": True,
                "details": [f"Skipped audit (found {skip_file})"]
            })
            continue

        report["layers"].append(check_layer3(templates_dir, p))
        report["layers"].append(check_layer4(p, claude_json, deployed_tools))
        report["layers"].append(check_layer5(p, deployed_tools if os.path.exists(deployed_tools) else repo_tools))

    report["overall_ok"] = all(item["ok"] for item in report["layers"])

    if args.json:
        print(json.dumps(report, indent=2, ensure_ascii=False))
    else:
        print("=== drsg-harness-kit Layered Deployment Audit ===")
        for layer in report["layers"]:
            status = "✓ OK" if layer["ok"] else "✗ DRIFT"
            print(f"\n[{status}] {layer['name']}")
            for det in layer["details"]:
                print(f"      • {det}")
        print("\n" + ("=" * 48))
        if report["overall_ok"]:
            print("Audit Result: PASSED (all layers in sync)")
        else:
            print("Audit Result: FAILED (drift or missing components detected)")

    sys.exit(0 if report["overall_ok"] else 1)


if __name__ == "__main__":
    main()
