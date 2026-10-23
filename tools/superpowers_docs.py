#!/usr/bin/env python3
"""Install and inspect the per-project Superpowers documentation location."""

import copy
import hashlib
import json
import os
import pathlib
import stat
import subprocess
import sys
import tempfile

_BEGIN = b"<!-- drsg-memory:superpowers-docs:begin -->"
_END = b"<!-- drsg-memory:superpowers-docs:end -->"


def _real(path):
    return os.path.realpath(os.path.abspath(os.fspath(path)))


def _inside(path, root):
    try:
        return os.path.commonpath([path, root]) == root
    except (ValueError, OSError):
        return False


def _config_path():
    memory_dir = os.environ.get("DRSG_MEM_DIR") or os.path.join(
        os.path.expanduser("~"), ".drsg-memory")
    return os.path.join(memory_dir, "commit-auth.json")


def configured_reviewer(config_path):
    """Return the configured reviewer realpath, or None when inactive."""
    try:
        with open(config_path, encoding="utf-8") as stream:
            config = json.load(stream)
        reviewer = config.get("reviewer") if isinstance(config, dict) else None
        if not isinstance(reviewer, str) or not os.path.isabs(reviewer):
            return None
        reviewer = _real(reviewer)
        if not os.path.isdir(reviewer):
            return None
        return reviewer
    except (OSError, ValueError, TypeError):
        return None


def project_slug(project_root, registered_paths):
    """Return a unique project basename, or None for a registered collision."""
    project = _real(project_root)
    slug = os.path.basename(project.rstrip(os.sep))
    if not slug:
        return None
    identities = set()
    for path in registered_paths or ():
        try:
            normalized = _real(path)
        except (OSError, TypeError, ValueError):
            continue
        if os.path.basename(normalized.rstrip(os.sep)) == slug:
            identities.add(normalized)
    return slug if identities.issubset({project}) else None


def render_block(reviewer, slug):
    """Render the independent managed CLAUDE.md rule block from its template."""
    reviewer = _real(reviewer)
    archive = os.path.join(reviewer, "reviews", slug, "docs", "superpowers")
    template_path = os.path.join(os.path.dirname(__file__), "templates",
                                 "superpowers-docs.md")
    with open(template_path, encoding="utf-8") as stream:
        block = stream.read()
    return (block.replace("{{SPECS_PATH}}", archive + "/specs/")
            .replace("{{PLANS_PATH}}", archive + "/plans/")
            .replace("{{ARCHIVE_PATH}}", archive + "/"))


def update_managed_block(claude_path, block_or_none):
    """Append, replace, or remove the managed block without changing other bytes."""
    path = os.fspath(claude_path)
    try:
        with open(path, "rb") as stream:
            current = stream.read()
    except FileNotFoundError:
        current = b""
    except OSError:
        return False

    begin_count = current.count(_BEGIN)
    end_count = current.count(_END)
    if begin_count != end_count or begin_count > 1:
        return False
    if begin_count:
        begin = current.index(_BEGIN)
        end = current.index(_END)
        if end < begin:
            return False
        end += len(_END)
        prefix, suffix = current[:begin], current[end:]
        if block_or_none is None:
            if suffix.startswith(b"\r\n"):
                suffix = suffix[2:]
            elif suffix.startswith(b"\n"):
                suffix = suffix[1:]
            updated = prefix + suffix
        else:
            replacement = block_or_none.encode("utf-8")
            if replacement.endswith(b"\r\n"):
                replacement = replacement[:-2]
            elif replacement.endswith(b"\n"):
                replacement = replacement[:-1]
            updated = prefix + replacement + suffix
    elif block_or_none is None:
        return True
    else:
        separator = b"" if not current or current.endswith(b"\n") else b"\n"
        updated = current + separator + block_or_none.encode("utf-8")

    if updated == current:
        return True
    try:
        _atomic_write(path, updated, _mode(path, 0o644))
        return True
    except OSError:
        return False


def _mode(path, default=0o600):
    try:
        return stat.S_IMODE(os.stat(path).st_mode)
    except OSError:
        return default


def _atomic_write(path, content, mode):
    parent = os.path.dirname(os.path.abspath(path))
    os.makedirs(parent, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix="." + os.path.basename(path) + ".",
                                     dir=parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


def _state_path(project):
    config_home = os.environ.get("XDG_CONFIG_HOME") or os.path.join(
        os.path.expanduser("~"), ".config")
    digest = hashlib.sha256(project.encode("utf-8")).hexdigest()
    return os.path.join(config_home, "drsg", "superpowers-docs-state", digest + ".json")


def _read_state(project):
    path = _state_path(project)
    try:
        with open(path, encoding="utf-8") as stream:
            state = json.load(stream)
        if not isinstance(state, dict) or state.get("project") != project:
            return None, "state-mismatch"
        return state, None
    except FileNotFoundError:
        return None, "state-missing"
    except (OSError, ValueError, TypeError):
        return None, "state-invalid"


def _write_state(project, reviewer, allow, enabled, opt_out=False):
    state = {"project": project, "reviewer": reviewer, "allow": allow,
             "enabled": bool(enabled), "opt_out": bool(opt_out)}
    path = _state_path(project)
    directory = os.path.dirname(path)
    os.makedirs(directory, mode=0o700, exist_ok=True)
    os.chmod(directory, 0o700)
    _atomic_write(path,
                  (json.dumps(state, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode("utf-8"),
                  0o600)


def _settings_path(project):
    return os.path.join(project, ".claude", "settings.local.json")


def _load_settings(project):
    path = _settings_path(project)
    try:
        with open(path, encoding="utf-8") as stream:
            raw = stream.read()
        data = json.loads(raw)
    except FileNotFoundError:
        return path, {}, None
    except (OSError, ValueError, UnicodeError):
        return path, None, "settings-json"
    if not isinstance(data, dict):
        return path, None, "settings-shape"
    permissions = data.get("permissions", {})
    if not isinstance(permissions, dict):
        return path, None, "settings-shape"
    additional = permissions.get("additionalDirectories", [])
    if not isinstance(additional, list) or any(not isinstance(item, str) for item in additional):
        return path, None, "settings-shape"
    if not isinstance(data.get("hooks", {}), dict):
        return path, None, "settings-shape"
    return path, data, None


def _merge_hooks(settings, hooks_path):
    if not hooks_path:
        return False, {}, None
    try:
        with open(hooks_path, encoding="utf-8") as stream:
            ours = json.load(stream)
    except (OSError, ValueError, UnicodeError):
        return False, {}, "hooks-template"
    if not isinstance(ours, dict):
        return False, {}, "hooks-template"

    before = copy.deepcopy(settings)
    hooks = settings.get("hooks") or {}
    if not isinstance(hooks, dict):
        return False, {}, "settings-shape"

    def leaf(command):
        argv = (command or "").strip().split()
        return argv[0].split("/")[-1] if argv else ""

    ours_leaves = set()
    for groups in ours.values():
        if not isinstance(groups, list):
            return False, {}, "hooks-template"
        for group in groups:
            if not isinstance(group, dict) or not group.get("hooks"):
                return False, {}, "hooks-template"
            ours_leaves.add(leaf(group["hooks"][0].get("command")))

    added, refreshed, deduped = [], [], []
    for event, groups in ours.items():
        if not isinstance(event, str) or not isinstance(groups, list):
            return False, {}, "hooks-template"
        existing = hooks.get(event) or []
        if not isinstance(existing, list):
            return False, {}, "settings-shape"
        for group in groups:
            template_hook = group["hooks"][0]
            wanted = leaf(template_hook.get("command"))
            mine = []
            for group_index, existing_group in enumerate(existing):
                if not isinstance(existing_group, dict):
                    return False, {}, "settings-shape"
                existing_hooks = existing_group.get("hooks") or []
                if not isinstance(existing_hooks, list):
                    return False, {}, "settings-shape"
                for hook_index, hook in enumerate(existing_hooks):
                    if not isinstance(hook, dict):
                        return False, {}, "settings-shape"
                    if leaf(hook.get("command")) == wanted:
                        mine.append((group_index, hook_index))
            if not mine:
                existing.append(group)
                added.append("%s/%s" % (event, wanted))
                continue
            group_index, hook_index = mine[0]
            existing[group_index]["hooks"][hook_index] = dict(template_hook)
            if len(existing[group_index]["hooks"]) == 1:
                if "matcher" in group:
                    existing[group_index]["matcher"] = group["matcher"]
                else:
                    existing[group_index].pop("matcher", None)
            refreshed.append("%s/%s" % (event, wanted))
            for other_group, other_hook in reversed(mine[1:]):
                del existing[other_group]["hooks"][other_hook]
                if not existing[other_group]["hooks"]:
                    del existing[other_group]
                deduped.append("%s/%s" % (event, wanted))
        hooks[event] = existing

    settings["hooks"] = hooks
    foreign = sorted({leaf(hook.get("command"))
                      for event in ours
                      for group in hooks.get(event) or []
                      for hook in group.get("hooks") or []
                      if leaf(hook.get("command")) not in ours_leaves})
    return settings != before, {"added": added, "refreshed": refreshed,
                                "deduped": deduped, "foreign": foreign}, None


def _managed_block_valid(claude_path):
    try:
        with open(claude_path, "rb") as stream:
            current = stream.read()
    except FileNotFoundError:
        return True
    except OSError:
        return False
    begins, ends = current.count(_BEGIN), current.count(_END)
    if begins == ends == 0:
        return True
    if begins != 1 or ends != 1:
        return False
    return current.index(_END) > current.index(_BEGIN)


def _save_settings(path, data):
    if os.path.exists(path):
        mode = _mode(path, 0o600)
    else:
        mode = 0o600
    encoded = (json.dumps(data, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    try:
        with open(path, "rb") as stream:
            if stream.read() == encoded:
                return True
    except FileNotFoundError:
        pass
    _atomic_write(path, encoded, mode)
    return True


def _known_projects(known_paths):
    if known_paths is not None:
        if isinstance(known_paths, (str, bytes, os.PathLike)):
            try:
                with open(known_paths, "rb") as stream:
                    return [item.decode("utf-8") for item in stream.read().split(b"\0") if item]
            except OSError:
                return None
        return list(known_paths)
    script = os.path.join(os.path.dirname(__file__), "project_registry.py")
    try:
        result = subprocess.run([sys.executable, script, "--nul"],
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                check=False, timeout=7)
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode:
        return None
    try:
        return [item.decode("utf-8") for item in result.stdout.split(b"\0") if item]
    except UnicodeError:
        return None


def _result(ok=True, settings_ok=True, warning=False, reason=""):
    return {"ok": ok, "settings_ok": settings_ok, "warning": warning, "reason": reason}


def install_project(project_root, known_paths=None, hooks_template=None):
    """Merge project hooks and install the archive rule when it is enabled."""
    project = _real(project_root)
    settings_path, settings, settings_issue = _load_settings(project)
    if settings_issue:
        return _result(settings_ok=False, warning=True, reason=settings_issue)
    hooks_changed, hook_summary, hook_issue = _merge_hooks(settings, hooks_template)
    if hook_issue:
        return _result(settings_ok=False, warning=True, reason=hook_issue)

    reviewer = configured_reviewer(_config_path())
    if reviewer is None:
        if hooks_changed:
            try:
                _save_settings(settings_path, settings)
            except OSError:
                return _result(settings_ok=False, warning=True, reason="settings-write")
        result = _result(reason="reviewer-inactive")
        result["hooks"] = hook_summary
        return result

    paths = _known_projects(known_paths)
    warning = paths is None
    if paths is None:
        paths = [project]
    slug = project_slug(project, paths)
    if slug is None:
        if hooks_changed:
            try:
                _save_settings(settings_path, settings)
            except OSError:
                return _result(settings_ok=False, warning=True, reason="settings-write")
        result = _result(ok=False, warning=warning, reason="project-name-conflict")
        result["hooks"] = hook_summary
        return result

    old_state, state_issue = _read_state(project)
    if old_state and old_state.get("opt_out"):
        if hooks_changed:
            try:
                _save_settings(settings_path, settings)
            except OSError:
                return _result(settings_ok=False, warning=True, reason="settings-write")
        result = _result(warning=warning, reason="opted-out")
        result["hooks"] = hook_summary
        return result
    if state_issue in ("state-mismatch", "state-invalid"):
        warning = True

    is_reviewer = project == reviewer
    archive = os.path.join(reviewer, "reviews", slug, "docs", "superpowers")
    allow = None if is_reviewer else archive
    claude_path = os.path.join(project, "CLAUDE.md")
    if not _managed_block_valid(claude_path):
        if hooks_changed:
            try:
                _save_settings(settings_path, settings)
            except OSError:
                return _result(settings_ok=False, warning=True, reason="settings-write")
        result = _result(warning=True, reason="managed-block")
        result["hooks"] = hook_summary
        return result

    old_allow = old_state.get("allow") if old_state else None
    owned_allow = old_allow if old_allow == allow else None
    settings_changed = hooks_changed
    if allow is not None or old_allow:
        permissions = settings.setdefault("permissions", {})
        additional = permissions.setdefault("additionalDirectories", [])
        if old_allow and old_allow != allow:
            try:
                additional.remove(old_allow)
                settings_changed = True
            except ValueError:
                pass
        if allow and allow not in additional:
            additional.append(allow)
            owned_allow = allow
            settings_changed = True

    if settings_changed:
        try:
            _save_settings(settings_path, settings)
        except OSError:
            return _result(settings_ok=False, warning=True, reason="settings-write")
    if not update_managed_block(claude_path, render_block(reviewer, slug)):
        return _result(warning=True, reason="managed-block")
    try:
        os.makedirs(os.path.join(archive, "specs"), exist_ok=True)
        os.makedirs(os.path.join(archive, "plans"), exist_ok=True)
        _write_state(project, reviewer, owned_allow, True, False)
    except OSError:
        return _result(warning=True, reason="state-write")
    result = _result(warning=warning, reason="registry-unavailable" if warning else "")
    result["hooks"] = hook_summary
    return result


def set_opt_out(project_root, enabled):
    """Record opt-out/restore state and remove only settings proven kit-owned."""
    project = _real(project_root)
    state, issue = _read_state(project)
    if enabled:
        if issue in ("state-mismatch", "state-invalid"):
            return _result(warning=True, reason=issue)
        settings_path, settings, settings_issue = _load_settings(project)
        if settings_issue:
            block_ok = update_managed_block(os.path.join(project, "CLAUDE.md"), None)
            try:
                _write_state(project, state.get("reviewer") if state else None,
                             state.get("allow") if state else None, False, True)
            except OSError:
                return _result(settings_ok=False, warning=True, reason="state-write")
            return _result(settings_ok=False, warning=True,
                           reason=settings_issue if block_ok else "managed-block")
        if state and state.get("allow"):
            additional = settings.setdefault("permissions", {}).setdefault(
                "additionalDirectories", [])
            try:
                additional.remove(state["allow"])
            except ValueError:
                pass
            try:
                _save_settings(settings_path, settings)
            except OSError:
                return _result(settings_ok=False, warning=True, reason="settings-write")
        if not update_managed_block(os.path.join(project, "CLAUDE.md"), None):
            return _result(warning=True, reason="managed-block")
        try:
            _write_state(project, state.get("reviewer") if state else None,
                         None, False, True)
        except OSError:
            return _result(warning=True, reason="state-write")
        return _result()

    if issue in ("state-mismatch", "state-invalid"):
        return _result(warning=True, reason=issue)
    try:
        _write_state(project, state.get("reviewer") if state else None,
                     state.get("allow") if state else None, False, False)
    except OSError:
        return _result(warning=True, reason="state-write")
    return _result()


def inspect_project(project_root, known_paths=None):
    """Return non-sensitive installation and drift status for one project."""
    project = _real(project_root)
    reviewer = configured_reviewer(_config_path())
    state, issue = _read_state(project)
    if reviewer is None:
        return {"active": False, "reason": "reviewer-inactive", "warning": False}
    paths = _known_projects(known_paths)
    slug = project_slug(project, paths if paths is not None else [project])
    if slug is None:
        return {"active": False, "reason": "project-name-conflict", "warning": paths is None}
    if state and state.get("opt_out"):
        return {"active": False, "reason": "opted-out", "warning": False}
    return {"active": True, "reason": issue or "", "warning": issue is not None,
            "project": project, "reviewer": reviewer, "slug": slug,
            "allow": state.get("allow") if state else None,
            "enabled": bool(state and state.get("enabled"))}
