#!/usr/bin/env python3
"""Pick the tests a working-tree change can reach, instead of the whole suite.

The change is `git diff <base>` plus untracked files. Selection per language:

  Go      package level, from `go list -test` (exact for the build graph):
          every test binary whose dependencies include a changed package.
  Python  test functions that reach a changed function or class through
          recorded CALLS edges in the repository's code graph (up to 6 hops),
          plus every test file whose text names a changed symbol or module.
          The graph is a lower bound; the text match covers what it misses.
  Shell   only when configured: test scripts whose text names a changed file,
          after adding the Python modules that import a changed module.

Whatever it cannot reason about turns the answer into FULL with the reason,
never into a smaller selection: dependency manifests, conftest.py, a file type
no rule covers, a graph that cannot be asked, a symbol the graph should know but
does not, or a code change that reaches no test at all.

Optional per-repository config: <repo>/.drsg/affected-tests.json

  {"full": "bash tests/test-all.sh",
   "always": ["make lint"],
   "full_triggers": ["tests/lib/*"],
   "ignore": ["frontend/*"],
   "go": {"tags": "unit"},
   "python": {"runner": ".venv/bin/python -m pytest"},
   "shell": {"tests": "tests/*.sh", "exclude": ["tests/test-all.sh"],
             "runner": "bash"}}

Exit: 0 selection printed (or --run passed), 1 a --run command failed,
2 usage or tool error, 3 the full suite is required (printed, not run).
"""
import argparse
import ast
import fnmatch
import importlib.util
import json
import os
import re
import shlex
import shutil
import subprocess
import sys

GRAPH_DEPTH = 6
FULL_TRIGGER_NAMES = (
    "go.mod", "go.sum", "go.work", "go.work.sum",
    "rust-toolchain", "rust-toolchain.toml",
    "conftest.py", "pytest.ini", "tox.ini", "setup.cfg", "setup.py",
    "pyproject.toml", "Pipfile", "Pipfile.lock", "poetry.lock", "uv.lock",
)
FULL_TRIGGER_GLOBS = ("requirements*.txt",)
DOC_GLOBS = ("*.md", "*.rst", "*.txt", "LICENSE*", "docs/*", "*/docs/*",
             ".gitignore", ".gitattributes", ".editorconfig", ".github/*")
MIN_NAME = 4


class ToolError(Exception):
    pass


def git(root, *args):
    proc = subprocess.run(["git", "-C", root] + list(args),
                          capture_output=True, text=True)
    if proc.returncode != 0:
        raise ToolError("git %s failed: %s" % (" ".join(args), proc.stderr.strip()))
    return proc.stdout


def load_config(root, path=None):
    path = path or os.path.join(root, ".drsg", "affected-tests.json")
    try:
        with open(path, encoding="utf-8") as fh:
            cfg = json.load(fh)
    except FileNotFoundError:
        return {}
    except (OSError, ValueError) as e:
        raise ToolError("%s is unreadable: %s" % (path, e))
    if not isinstance(cfg, dict):
        raise ToolError("%s must hold a JSON object" % path)
    return cfg


def changed_files(root, base):
    """[(status, path)] for base..working tree, untracked files as added."""
    out = git(root, "diff", "--name-status", "--no-renames", "-z", base)
    parts = out.split("\0")
    changes = []
    for i in range(0, len(parts) - 1, 2):
        changes.append((parts[i][:1], parts[i + 1]))
    for path in git(root, "ls-files", "--others", "--exclude-standard", "-z").split("\0"):
        if path:
            changes.append(("A", path))
    return changes


def hunk_lines(root, base, path):
    """(old_lines, new_lines) touched by the diff of one file."""
    out = git(root, "diff", "-U0", "--no-renames", base, "--", path)
    old, new = set(), set()
    for m in re.finditer(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@", out, re.M):
        a, b = int(m.group(1)), int(m.group(2) or "1")
        c, d = int(m.group(3)), int(m.group(4) or "1")
        old.update(range(a, a + b))
        new.update(range(c, c + d))
    return old, new


def base_source(root, base, path):
    proc = subprocess.run(["git", "-C", root, "show", "%s:%s" % (base, path)],
                          capture_output=True, text=True)
    return proc.stdout if proc.returncode == 0 else None


def matches(path, globs):
    return any(fnmatch.fnmatch(path, g) for g in globs)


def is_doc(path):
    return matches(path, DOC_GLOBS) or matches(os.path.basename(path), DOC_GLOBS)


# --------------------------------------------------------------------------
# Python
# --------------------------------------------------------------------------
def is_py_test(path):
    name = os.path.basename(path)
    return path.endswith(".py") and (name.startswith("test_") or name.endswith("_test.py"))


def symbols_at(source, lines):
    """Innermost def/class qualnames covering the lines, and whether any line
    lies outside every def/class (a module-level change)."""
    tree = ast.parse(source)
    spans = []

    def walk(node, prefix):
        for child in ast.iter_child_nodes(node):
            if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                start = min([child.lineno] + [d.lineno for d in child.decorator_list])
                name = prefix + [child.name]
                spans.append((start, child.end_lineno, ".".join(name)))
                # Functions nested in a function are not graph symbols: a change
                # inside one is a change to the function that encloses it.
                if isinstance(child, ast.ClassDef):
                    walk(child, name)

    walk(tree, [])
    text = source.splitlines()
    found, module_level = set(), False
    for line in lines:
        inside = [s for s in spans if s[0] <= line <= s[1]]
        if inside:
            found.add(max(inside, key=lambda s: s[0])[2])
        elif 0 < line <= len(text) and text[line - 1].strip() and \
                not text[line - 1].strip().startswith("#"):
            # Blank and comment lines between definitions change nothing.
            module_level = True
    return found, module_level


def all_symbols(source):
    return symbols_at(source, range(1, source.count("\n") + 2))[0]


def load_router():
    path = os.environ.get("DRSG_AFFECTED_ROUTER") or os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "codegraph-router.py")
    spec = importlib.util.spec_from_file_location("affected_tests_router", path)
    if spec is None or spec.loader is None:
        raise ToolError("cannot load the code-graph router from %s" % path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class Graph:
    def __init__(self, repo):
        self.router = load_router()
        self.entry = self.router.resolve_repo(repo)

    def rows(self, query, value):
        text, err = self.router.call_upstream(
            self.entry, "cypher",
            {"query": query, "params": {"k": value}, "plane": self.entry["plane"]})
        if err:
            raise ToolError("graph query failed: %s" % text.strip()[:200])
        try:
            return json.loads(text).get("rows") or []
        except (ValueError, AttributeError):
            raise ToolError("graph returned no JSON rows: %s" % text.strip()[:200])

    def file_keys(self, path):
        """Keys of the symbols the graph parsed out of one file ('?' keys are
        unresolved references, not definitions)."""
        return [r[0] for r in self.rows(
            "MATCH (f) WHERE f.file = $k AND NOT key(f) STARTS WITH \"?\" "
            "RETURN key(f)", path)]

    def has(self, key):
        return bool(self.rows("MATCH (g) WHERE key(g) = $k RETURN key(g)", key))

    def callers(self, key):
        return self.rows(
            "MATCH (t)-[:CALLS*1..%d]->(g) WHERE key(g) = $k "
            "RETURN DISTINCT key(t), t.file" % GRAPH_DEPTH, key)


def key_prefix(keys, symbols):
    """The module prefix the graph puts in front of a file's qualnames.

    Plugins differ (`pkg.mod.f` from the repository root, `mod.f` when the
    directory is not a package), so it is read off the graph, not guessed:
    the prefix most of the file's own top-level names agree on."""
    tops = {s for s in symbols if "." not in s}
    votes = {}
    for k in keys:
        for n in tops:
            if k == n:
                votes[""] = votes.get("", 0) + 1
            elif k.endswith("." + n):
                p = k[:-len(n)]
                votes[p] = votes.get(p, 0) + 1
    return max(votes, key=lambda p: (votes[p], -len(p))) if votes else None


def test_node_id(key, path, symbols):
    """pytest node id for a graph key naming a test in `path`, else None."""
    q = max((s for s in symbols if key == s or key.endswith("." + s)),
            key=len, default=None)
    if q is None or not q.split(".")[-1].startswith("test"):
        return None
    return "::".join([path] + q.split("."))


def read(root, path):
    with open(os.path.join(root, path), encoding="utf-8", errors="replace") as fh:
        return fh.read()


def python_select(root, base, py_changes, test_files, graph_factory, out):
    """Fill out['python'] (files or node ids) and out['why'].

    graph_factory() returns the Graph to ask and is called only when needed.
    Returns (full_reasons, unmodeled): unmodeled are changed files the graph
    has no definitions for; the caller decides whether another rule covers them."""
    reasons, unmodeled = [], []
    texts = {}
    for t in test_files:
        try:
            texts[t] = read(root, t)
        except OSError:
            texts[t] = ""
    names, per_file = set(), []
    for status, path in py_changes:
        if is_py_test(path):
            if status != "D":
                out["python"].add(path)
                out["why"].append("%s  <- changed test file" % path)
            continue
        old_src = base_source(root, base, path) if status != "A" else None
        new_src = read(root, path) if status != "D" else None
        try:
            if status == "A":
                syms, module_level = all_symbols(new_src), True
            elif status == "D":
                syms, module_level = all_symbols(old_src or ""), True
            else:
                old_lines, new_lines = hunk_lines(root, base, path)
                syms_new, lvl_new = symbols_at(new_src, new_lines)
                syms_old, lvl_old = symbols_at(old_src or "", old_lines)
                syms, module_level = syms_new | syms_old, lvl_new or lvl_old
            base_syms = all_symbols(old_src) if old_src else set()
            if module_level:
                # A constant, import or top-level statement can change what
                # every function in the module does: all of them count.
                syms |= all_symbols(new_src if new_src is not None else old_src or "")
        except SyntaxError as e:
            reasons.append("cannot parse %s (%s)" % (path, e.msg))
            continue
        names.update(s.split(".")[-1] for s in syms)
        if module_level:
            names.add(os.path.basename(path)[:-3])
        if syms:
            per_file.append((path, syms, base_syms, base_syms | all_symbols(new_src or "")))
    if reasons:
        return reasons, unmodeled

    for name in sorted(names):
        if len(name) < MIN_NAME or name.startswith("__"):
            continue
        rx = re.compile(r"\b%s\b" % re.escape(name))
        for t, text in texts.items():
            if t not in out["python"] and rx.search(text):
                out["python"].add(t)
                out["why"].append("%s  <- names `%s`" % (t, name))

    if not per_file:
        return reasons, unmodeled
    try:
        graph = graph_factory()
        test_syms = {}
        for path, syms, base_syms, known in per_file:
            if not base_syms:
                continue  # a new file: nothing at the base can call it yet
            prefix = key_prefix(graph.file_keys(path), known)
            if prefix is None:
                unmodeled.append(path)
                continue
            for s in sorted(syms):
                key = prefix + s
                if not graph.has(key):
                    if s in base_syms:
                        reasons.append("graph has no node for %s (it exists at the "
                                       "base; the graph is stale)" % key)
                    continue
                for tkey, tfile in graph.callers(key):
                    if not tfile or not is_py_test(tfile) or tfile in out["python"]:
                        continue
                    if tfile not in test_syms:
                        try:
                            test_syms[tfile] = all_symbols(read(root, tfile))
                        except (OSError, SyntaxError):
                            test_syms[tfile] = set()
                    node = test_node_id(tkey, tfile, test_syms[tfile])
                    if node and node not in out["python"]:
                        out["python"].add(node)
                        out["why"].append("%s  <- graph: calls %s" % (node, key))
    except Exception as e:  # router import, daemon, registry: never shrink silently
        reasons.append("code graph unavailable: %s" % e)
    return reasons, unmodeled


# --------------------------------------------------------------------------
# Go
# --------------------------------------------------------------------------
def excluded_by_tags(root, path, tags):
    """True when go list names the file among its directory's IgnoredGoFiles:
    the selected suite does not build it, so it cannot be selected or missed."""
    cmd = ["go", "list", "-e", "-f", "{{join .IgnoredGoFiles \"\\n\"}}"]
    if tags:
        cmd.append("-tags=" + tags)
    d = os.path.dirname(os.path.join(root, path))
    if not os.path.isdir(d):
        return False
    proc = subprocess.run(cmd + ["."], cwd=d, capture_output=True, text=True)
    return os.path.basename(path) in proc.stdout.split("\n")


def rust_select(root, changes, cfg, out):
    """Fill out['rust'] and return handled paths and fallback reasons."""
    reasons, handled = [], set()
    tracked = [p for p in git(root, "ls-files", "-z").split("\0") if p]
    manifests = {os.path.dirname(p) for p in tracked + [p for _, p in changes]
                 if os.path.basename(p) == "Cargo.toml"}
    manifests = sorted(manifests, key=lambda p: (p.count(os.sep), p))
    changed_paths = [p for _, p in changes]
    relevant = any(
        p.endswith(".rs")
        or os.path.basename(p).startswith("Cargo.")
        or os.path.basename(p).startswith("rust-toolchain")
        or p.endswith(("/.cargo/config", "/.cargo/config.toml"))
        or p in (".cargo/config", ".cargo/config.toml")
        or any(p == d or p.startswith(d + "/") for d in manifests)
        for p in changed_paths)
    if not relevant:
        return handled, reasons
    handled.update(p for p in changed_paths
                   if any(p == d or p.startswith(d + "/") for d in manifests))
    if not manifests:
        if any(p.endswith(".rs") or os.path.basename(p).startswith("Cargo.")
               for p in changed_paths):
            reasons.append("cargo metadata unavailable: repository has no Cargo.toml")
        return handled, reasons
    if not shutil.which("cargo"):
        reasons.append("cargo is unavailable for Rust/Cargo changes")
        return handled, reasons

    workspaces = {}
    for manifest_dir in manifests:
        manifest = os.path.join(root, manifest_dir, "Cargo.toml")
        proc = subprocess.run(
            ["cargo", "metadata", "--no-deps", "--offline", "--format-version", "1",
             "--manifest-path", manifest], cwd=root, capture_output=True, text=True)
        if proc.returncode:
            stderr = proc.stderr[:200].replace("\n", " ")
            reasons.append("cargo metadata failed for %s: %s" %
                           (manifest_dir or ".", stderr))
            continue
        try:
            data = json.loads(proc.stdout)
        except ValueError as e:
            reasons.append("cargo metadata returned invalid JSON for %s: %s" %
                           (manifest_dir or ".", str(e)[:200]))
            continue
        ws_root = os.path.realpath(data["workspace_root"])
        ws = workspaces.setdefault(ws_root, {"packages": {}, "members": set()})
        for package in data.get("packages", []):
            pkg_manifest = os.path.realpath(package["manifest_path"])
            pkg_dir = os.path.dirname(pkg_manifest)
            ws["packages"][pkg_manifest] = package
            ws["members"].add(pkg_manifest)

    packages = {}
    by_dir = {}
    workspace_members = {}
    workspace_rel = {}
    for ws_root, ws in workspaces.items():
        workspace_members[ws_root] = set(ws["members"])
        workspace_rel[ws_root] = os.path.relpath(ws_root, root)
        for manifest, package in ws["packages"].items():
            packages[manifest] = (ws_root, package)
            by_dir[os.path.dirname(manifest)] = manifest

    # A package's path dependencies point from the dependent package to the
    # dependency package; selection walks these edges in reverse.
    dependents = {}
    for manifest, (ws_root, package) in packages.items():
        for dep in package.get("dependencies", []):
            dep_path = dep.get("path")
            if not dep_path:
                continue
            dep_dir = os.path.realpath(dep_path)
            target = by_dir.get(dep_dir)
            if target:
                dependents.setdefault(target, set()).add(manifest)

    def owner(path):
        absolute = os.path.realpath(os.path.join(root, path))
        candidates = [m for m in packages
                      if absolute == os.path.dirname(m)
                      or absolute.startswith(os.path.dirname(m) + os.sep)]
        if not candidates:
            return None
        deepest = max(candidates, key=lambda m: len(os.path.dirname(m)))
        ws_root = packages[deepest][0]
        outer = [m for m in packages
                 if os.path.dirname(m) != os.path.dirname(deepest)
                 and absolute.startswith(os.path.dirname(m) + os.sep)
                 and packages[m][0] != ws_root]
        return max(outer, key=lambda m: len(os.path.dirname(m))) if outer else deepest

    seeds = set()
    for path in changed_paths:
        basename = os.path.basename(path)
        if basename == "Cargo.lock":
            lock_dir = os.path.realpath(os.path.join(root, os.path.dirname(path)))
            ws_root = max((w for w in workspaces
                           if lock_dir == w or lock_dir.startswith(w + os.sep)),
                          key=len, default=None)
            if ws_root:
                seeds.update(workspace_members[ws_root])
            continue
        if basename == "Cargo.toml":
            manifest = os.path.realpath(os.path.join(root, path))
            ws_root = next((w for w in workspaces
                            if os.path.dirname(manifest) == w), None)
            if ws_root:
                seeds.update(workspace_members[ws_root])
                continue
        crate = owner(path)
        if crate:
            seeds.add(crate)
        elif path.endswith(".rs"):
            reasons.append("%s belongs to no Rust crate" % path)

    seeds = {owner(os.path.join(os.path.relpath(os.path.dirname(m), root), "Cargo.toml")) or m
             for m in seeds}
    reached = set(seeds)
    causes = {m: {packages[m][1]["name"]} for m in seeds}
    todo = list(seeds)
    while todo:
        dependency = todo.pop()
        for dependent in dependents.get(dependency, ()):
            if dependent not in reached:
                reached.add(dependent)
                todo.append(dependent)
            causes.setdefault(dependent, set()).update(causes[dependency])

    rust_cfg = cfg.get("rust") or {}
    excludes = rust_cfg.get("exclude", [])
    for manifest in sorted(reached):
        ws_root, package = packages[manifest]
        crate_dir = os.path.relpath(os.path.dirname(manifest), root)
        if matches(crate_dir, excludes):
            out["ignored"].append("%s (config rust.exclude)" % crate_dir)
            continue
        ws_dir = workspace_rel[ws_root]
        out["rust"].setdefault(ws_dir, set()).add(package["name"])
        out["why"].append("%s (%s)  <- depends on %s" %
                           (package["name"], ws_dir or ".",
                            ", ".join(sorted(causes.get(manifest, set())))))
    return handled, reasons


def go_select(root, go_changes, tags, out):
    """Fill out['go'] {module_dir: set(pkg_rel)}; return (handled_paths, reasons)."""
    reasons, handled = [], set()
    mods = sorted({os.path.dirname(p) for p in
                   git(root, "ls-files", "go.mod", "*/go.mod").split("\n") if p},
                  key=len, reverse=True)
    by_mod = {}
    for path in go_changes:
        mod = next((m for m in mods if m == "" or path.startswith(m + "/")), None)
        if mod is None:
            if path.endswith(".go"):
                reasons.append("%s is in no Go module" % path)
            continue
        by_mod.setdefault(mod, []).append(path)
    for mod, paths in sorted(by_mod.items()):
        mdir = os.path.join(root, mod)
        cmd = ["go", "list", "-e", "-test", "-f",
               "{{.ImportPath}}\t{{.Dir}}\t{{join .Deps \" \"}}"]
        if tags:
            cmd.append("-tags=" + tags)
        proc = subprocess.run(cmd + ["./..."], cwd=mdir, capture_output=True, text=True)
        if proc.returncode != 0:
            reasons.append("go list failed in %s: %s" % (mod or ".", proc.stderr.strip()[:200]))
            continue
        dirs, mains = {}, []
        for line in proc.stdout.splitlines():
            ipath, d, deps = (line.split("\t") + ["", ""])[:3]
            if ipath.endswith(".test") and " " not in ipath:
                mains.append((ipath[:-len(".test")], {x.split(" [")[0] for x in deps.split()}))
            elif " [" not in ipath and not ipath.endswith("_test"):
                dirs[os.path.realpath(d)] = ipath
        changed = set()
        for path in paths:
            d = os.path.realpath(os.path.dirname(os.path.join(root, path)))
            while d not in dirs and d.startswith(os.path.realpath(mdir) + os.sep):
                d = os.path.dirname(d)
            if d in dirs:
                changed.add(dirs[d])
                handled.add(path)
            elif path.endswith(".go") and excluded_by_tags(root, path, tags):
                handled.add(path)
                out["skip"].add(path)
                out["ignored"].append("%s (build constraints exclude it%s)"
                                      % (path, " with -tags=" + tags if tags else ""))
            elif path.endswith(".go"):
                reasons.append("%s belongs to no package go list reports" % path)
        pkg_dir = {v: k for k, v in dirs.items()}
        for pkg, deps in mains:
            hit = changed & (deps | {pkg})
            if hit:
                rel = os.path.relpath(pkg_dir.get(pkg, ""), os.path.realpath(mdir))
                out["go"].setdefault(mod, set()).add("./" + rel if rel != "." else ".")
                out["why"].append("%s (%s)  <- depends on %s"
                                  % (pkg, mod or ".", ", ".join(sorted(hit))))
    return handled, reasons


# --------------------------------------------------------------------------
# Shell
# --------------------------------------------------------------------------
def py_importers(root, py_files):
    """stem -> files whose imports name that stem."""
    importers = {}
    for f in py_files:
        try:
            with open(os.path.join(root, f), encoding="utf-8", errors="replace") as fh:
                tree = ast.parse(fh.read())
        except (OSError, SyntaxError, ValueError):
            continue
        for node in ast.walk(tree):
            names = []
            if isinstance(node, ast.Import):
                names = [a.name for a in node.names]
            elif isinstance(node, ast.ImportFrom):
                names = [node.module or ""] + [a.name for a in node.names]
            for n in names:
                for part in n.split("."):
                    if part:
                        importers.setdefault(part, set()).add(f)
    return importers


def shell_select(root, cfg, changes, py_files, out):
    """Fill out['shell']; return the set of changed paths some script names."""
    pattern = cfg.get("tests", "tests/*.sh")
    exclude = set(cfg.get("exclude", []))
    scripts = sorted(p for p in git(root, "ls-files", pattern).split("\n") + [
        p for s, p in changes if s == "A"]
        if p and fnmatch.fnmatch(p, pattern) and p not in exclude)
    texts = {}
    for s in scripts:
        try:
            with open(os.path.join(root, s), encoding="utf-8", errors="replace") as fh:
                texts[s] = fh.read()
        except OSError:
            pass
    reach = {p: p for s, p in changes}
    importers = py_importers(root, py_files)
    queue = [p for p in reach if p.endswith(".py")]
    while queue:
        p = queue.pop()
        for f in importers.get(os.path.basename(p)[:-3], ()):
            if f not in reach:
                reach[f] = reach[p]
                queue.append(f)
    covered = set()
    for f, origin in sorted(reach.items()):
        for s, text in texts.items():
            if s == f or f in text or os.path.basename(f) in text:
                covered.add(origin)
                if s not in out["shell"]:
                    out["shell"].add(s)
                    via = "" if f == origin else " (imports %s)" % origin
                    out["why"].append("%s  <- names %s%s" % (s, f, via))
    return covered


# --------------------------------------------------------------------------
def select(root, base, cfg, graph_factory):
    changes = changed_files(root, base)
    out = {"go": {}, "rust": {}, "python": set(), "shell": set(), "why": [],
           "ignored": [], "full": [], "skip": set()}
    if not changes:
        return changes, out
    ignore = cfg.get("ignore", [])
    triggers = list(cfg.get("full_triggers", []))
    live = []
    for status, path in changes:
        if matches(path, ignore):
            out["ignored"].append(path + " (config ignore)")
        elif (os.path.basename(path) in FULL_TRIGGER_NAMES
              or path.endswith(("/.cargo/config", "/.cargo/config.toml"))
              or path in (".cargo/config", ".cargo/config.toml")
              or matches(os.path.basename(path), FULL_TRIGGER_GLOBS)
              or matches(path, triggers)):
            out["full"].append("%s changed (dependency or test setup)" % path)
        else:
            live.append((status, path))
    if out["full"]:
        return changes, out

    go_handled, reasons = go_select(
        root, [p for s, p in live], (cfg.get("go") or {}).get("tags", ""), out)
    out["full"] += reasons
    rust_handled, reasons = rust_select(root, live, cfg, out)
    out["full"] += reasons
    tracked = [p for p in git(root, "ls-files").split("\n") if p]
    untracked = [p for s, p in changes if s == "A"]
    py_files = sorted({p for p in tracked + untracked if p.endswith(".py")
                       and os.path.exists(os.path.join(root, p))})
    py_changes = [(s, p) for s, p in live if p.endswith(".py")]
    # Without Python test files (a repository tested by shell scripts) there is
    # no pytest target to select; the shell rules below handle .py changes.
    unmodeled = []
    if py_changes and any(is_py_test(p) for p in py_files):
        reasons, unmodeled = python_select(root, base, py_changes,
                                           [p for p in py_files if is_py_test(p)],
                                           graph_factory, out)
        out["full"] += reasons
    shell_cfg = cfg.get("shell")
    shell_covered = shell_select(root, shell_cfg, live, py_files, out) if shell_cfg else set()
    for path in unmodeled:
        if path not in shell_covered:
            out["full"].append("the code graph has no definitions for %s" % path)

    py_texts = None
    for status, path in live:
        if (path in go_handled or path in rust_handled
                or path.endswith((".py", ".go", ".rs"))
                or os.path.basename(path) in ("Cargo.toml", "Cargo.lock")
                or path in shell_covered):
            continue
        if py_texts is None:
            py_texts = {}
            for t in (p for p in py_files if is_py_test(p)):
                with open(os.path.join(root, t), encoding="utf-8", errors="replace") as fh:
                    py_texts[t] = fh.read()
        users = [t for t, text in py_texts.items() if os.path.basename(path) in text]
        for t in users:
            if t not in out["python"]:
                out["python"].add(t)
                out["why"].append("%s  <- names %s" % (t, path))
        if not users and not is_doc(path):
            out["full"].append("no rule covers %s" % path)

    code = [p for s, p in live if not is_doc(p) and p not in out["skip"]]
    picked = out["go"] or out["rust"] or out["python"] or out["shell"]
    if code and not picked and not out["full"]:
        out["full"].append("the change reaches no test: %s" % ", ".join(code[:5]))
    return changes, out


def commands(root, cfg, out):
    cmds = list(cfg.get("always", []))
    if out["full"]:
        if cfg.get("full"):
            return cmds + [cfg["full"]]
        return None
    tags = (cfg.get("go") or {}).get("tags", "")
    for mod, pkgs in sorted(out["go"].items()):
        cmd = "go test%s -count=1 %s" % (" -tags=" + tags if tags else "",
                                         " ".join(sorted(pkgs)))
        cmds.append("(cd %s && %s)" % (shlex.quote(mod), cmd) if mod else cmd)
    rust_args = (cfg.get("rust") or {}).get("args", "")
    for workspace, packages in sorted(out["rust"].items()):
        cmd = "cargo test%s %s" % (" " + rust_args if rust_args else "",
                                    " ".join("-p " + shlex.quote(p)
                                             for p in sorted(packages)))
        cmds.append("(cd %s && %s)" % (shlex.quote(workspace), cmd)
                    if workspace not in (".", "") else cmd)
    if out["python"]:
        files = {p for p in out["python"] if "::" not in p}
        nodes = {p for p in out["python"] if "::" in p and p.split("::")[0] not in files}
        runner = (cfg.get("python") or {}).get("runner", "python3 -m pytest")
        cmds.append("%s %s" % (runner, " ".join(shlex.quote(p) for p in sorted(files | nodes))))
    runner = (cfg.get("shell") or {}).get("runner", "bash")
    for s in sorted(out["shell"]):
        cmds.append("%s %s" % (runner, shlex.quote(s)))
    return cmds


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Select the tests a working-tree change can reach.")
    ap.add_argument("--repo", default=".", help="repository directory (default: .)")
    ap.add_argument("--base", default="HEAD",
                    help="commit or tree to diff the working tree against (default: HEAD)")
    ap.add_argument("--config", help="config file (default: <repo>/.drsg/affected-tests.json)")
    ap.add_argument("--graph-repo",
                    help="code-graph repository to ask, by name or path (default: "
                         "the repository itself; a worktree names its main checkout)")
    ap.add_argument("--json", action="store_true", help="print the result as JSON")
    ap.add_argument("--run", action="store_true",
                    help="run the selected commands (or the configured full suite)")
    args = ap.parse_args(argv)
    try:
        root = git(os.path.abspath(args.repo), "rev-parse", "--show-toplevel").strip()
        git(root, "rev-parse", "--verify", "--quiet", args.base + "^{tree}")
        cfg = load_config(root, args.config)
        graph_repo = args.graph_repo or root
        changes, out = select(root, args.base, cfg, lambda: Graph(graph_repo))
        cmds = commands(root, cfg, out)
    except ToolError as e:
        print("affected-tests: %s" % e, file=sys.stderr)
        return 2
    mode = "none" if not changes else ("full" if out["full"] else "selected")
    if mode == "none" or (mode == "selected" and not cmds):
        mode, cmds = "none", []
    if args.json:
        print(json.dumps({
            "mode": mode, "base": args.base, "changed": [p for s, p in changes],
            "full_reasons": out["full"], "ignored": out["ignored"],
            "rust": {k: sorted(v) for k, v in sorted(out["rust"].items())},
            "commands": cmds, "why": out["why"],
        }, indent=1, ensure_ascii=False))
    else:
        print("mode: %s" % mode)
        print("base: %s, changed files: %d" % (args.base, len(changes)))
        for r in out["full"]:
            print("full: %s" % r)
        for p in out["ignored"]:
            print("ignored: %s" % p)
        if cmds is None:
            print("no `full` command configured: run the whole suite yourself")
        for c in cmds or []:
            print("run: %s" % c)
        for w in out["why"]:
            print("why: %s" % w)
    if mode == "full" and not args.run:
        return 3
    if not args.run or not cmds:
        return 0 if cmds is not None else 3
    for c in cmds:
        print("+ %s" % c, flush=True)
        if subprocess.run(c, shell=True, cwd=root).returncode != 0:
            print("affected-tests: FAILED: %s" % c)
            return 1
    print("affected-tests: all %d command(s) passed" % len(cmds))
    return 0


if __name__ == "__main__":
    sys.exit(main())
