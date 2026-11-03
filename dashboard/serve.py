#!/usr/bin/env python3
"""The lab's agents at a glance: a small web page served on agentbox.

    python3 /srv/lab/dashboard/serve.py [--port 8765]

It listens on localhost and, if Tailscale is up, on the machine's Tailscale address (reachable only from
devices on your tailnet): open http://<machine>.<tailnet>.ts.net:8765. Without Tailscale, use
`ssh -L 8765:localhost:8765 agentbox` and open http://localhost:8765. Everything is read fresh from
Slurm, the registry and the agents' logs.
"""
import argparse
import glob
import json
import math
import os
import pwd
import re
import socket
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LAB = os.environ.get("LAB_DIR", "/srv/lab")
PROJECTS = os.environ.get("PROJECTS_DIR", "/srv/projects")


def _conf(key, default=""):
    """A KEY=value setting from the lab's root-owned settings file."""
    try:
        for line in open(os.environ.get("LAB_CONF", "/etc/agentbox/lab.conf")):
            k, _, v = line.split("#", 1)[0].strip().partition("=")
            if k == key and v:
                return v.strip()
    except OSError:
        pass
    return default


def _setting(key, default=""):
    """A working value as lib.sh's load_conf sees it, roughly: lab.conf, then the lab's limits.conf (the
    dashboard only displays these; the scripts enforce the ceilings)."""
    value = _conf(key, default)
    try:
        for line in open(f"{LAB}/limits.conf"):
            k, _, v = line.split("#", 1)[0].strip().partition("=")
            if k == key and v:
                value = v.strip()
    except OSError:
        pass
    return value


def _uid(user):
    try:
        return pwd.getpwnam(user).pw_uid
    except KeyError:
        return None


def _pool_dirs():
    """The agents' capped slice (lab-agents.slice) of each lab account that has one."""
    for user in ("hpc", "agent"):
        uid = _uid(user)
        if uid is not None:
            yield user, f"/sys/fs/cgroup/user.slice/user-{uid}.slice/user@{uid}.service/lab.slice/lab-agents.slice"


ORG = _conf("ORG")
PI = _conf("PI_GITHUB")
_titles = {}  # (project, issue) -> (time, title)


def run(cmd, timeout=20):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except Exception:
        return ""


def issue_title(project, issue):
    key = (project, issue)
    hit = _titles.get(key)
    if hit and time.time() - hit[0] < 600:
        return hit[1]
    title = run(["gh", "issue", "view", issue, "-R", f"{ORG}/{project}", "--json", "title", "-q", ".title"]).strip()
    _titles[key] = (time.time(), title)
    return title


def last_message(log):
    """The newest agent message in a codex JSON log, and when the log last changed."""
    try:
        size = os.path.getsize(log)
        mtime = os.path.getmtime(log)
    except OSError:
        return None, None
    msg = None
    with open(log, "rb") as f:
        f.seek(max(0, size - 400_000))
        for line in f.read().decode("utf-8", "replace").splitlines():
            if '"agent_message"' not in line:
                continue
            try:
                item = json.loads(line).get("item") or {}
            except ValueError:
                continue
            if item.get("type") == "agent_message":
                msg = item.get("text")
    if msg is None:  # a claude -p run writes one JSON result at the end
        try:
            data = json.loads(open(log).read())
            msg = data.get("result") if isinstance(data, dict) else None
        except Exception:
            pass
    return msg, mtime


def model_of(log, pids):
    for pid in pids:
        try:
            cmd = open(f"/proc/{pid}/cmdline", "rb").read().replace(b"\0", b" ").decode()
        except OSError:
            continue
        if re.search(r"\bcodex\b", cmd):
            return "Codex"
        if re.search(r"\bclaude\b", cmd):
            return "Claude"
    try:
        with open(log) as f:
            head = f.read(200)
        if '"thread.started"' in head or '"turn.started"' in head:
            return "Codex"
        if os.path.getsize(log) == 0:
            return "Claude"  # claude -p writes its log only when it finishes
    except OSError:
        pass
    return "?"


_scan = {}  # transcript path -> (offset, model, effort)
_rollouts = {}  # codex thread id -> rollout path
HOME = os.path.expanduser("~")


def _codex_models():
    try:
        return {m["slug"]: m for m in json.load(open(f"{HOME}/.codex/models_cache.json")).get("models", [])}
    except (OSError, ValueError):
        return {}


def _scan_file(path, codex):
    """Latest model and effort recorded in a transcript, reading only what was added since last time."""
    off, model, effort = _scan.get(path, (0, None, None))
    try:
        with open(path, "rb") as f:
            f.seek(off)
            data = f.read()
    except OSError:
        return model, effort
    end = data.rfind(b"\n") + 1
    for line in data[:end].splitlines():
        if codex:
            if b'"turn_context"' not in line:
                continue
            try:
                pl = json.loads(line).get("payload", {})
            except ValueError:
                continue
            model = pl.get("model") or model
            settings = (pl.get("collaboration_mode") or {}).get("settings") or {}
            effort = pl.get("effort") or settings.get("reasoning_effort") or "default"
        else:
            m = re.findall(rb'"model":"(claude-[^"]+)"', line)
            if m:
                model = m[-1].decode()
            e = re.findall(rb'"output_config":\{"effort":"(\w+)"', line)
            if e:
                effort = e[-1].decode()
    _scan[path] = (off + end, model, effort)
    return model, effort


def _claude_name(model):
    m = re.match(r"claude-([a-z]+)-(\d+)-(\d+)", model or "")
    return f"{m.group(1).capitalize()} {m.group(2)}.{m.group(3)}" if m else model


def _codex_name(model, effort):
    info = _codex_models().get(model, {})
    if effort in (None, "default"):
        effort = info.get("default_reasoning_level")
    name = info.get("display_name") or model
    return f"{name} · {effort}" if effort else name


def _proc_label(cwd):
    """Model and effort from the command line of a running codex in that folder (readable for any account)."""
    for path in glob.glob("/proc/[0-9]*/cmdline"):
        try:
            args = open(path, "rb").read().decode(errors="replace").split("\0")
        except OSError:
            continue
        if not args or os.path.basename(args[0]) != "codex":
            continue
        if not any(a in ("-C", "--cd") and i + 1 < len(args) and args[i + 1] == cwd for i, a in enumerate(args)):
            continue
        model = effort = None
        for i, a in enumerate(args[:-1]):
            if a == "-m":
                model = args[i + 1]
            elif a == "-c" and args[i + 1].startswith("model_reasoning_effort="):
                effort = args[i + 1].split("=", 1)[1].strip('"')
        if model:
            return _codex_name(model, effort)
    return None


def _conf_label(family, role):
    """What models.conf sets for that role: the model the agent's next run will use."""
    try:
        for line in open(f"{LAB}/models.conf"):
            f = line.split()
            if len(f) >= 5 and not line.lstrip().startswith("#") and f[0] == role:
                return _codex_name(f[1], f[2]) if family == "Codex" else f"{_claude_name(f[3])} · {f[4]}"
    except OSError:
        pass
    return None


def model_label(family, log, cwd=None, role=None):
    """E.g. "GPT-6.1-Sol · low" or "Opus 5.5 · medium", from the agent's own transcript; None if unreadable."""
    if family == "Codex":
        try:
            with open(log) as f:
                thread = json.loads(f.readline()).get("thread_id")
        except (OSError, ValueError):
            return None
        if not thread:
            return (cwd and _proc_label(cwd)) or (role and _conf_label(family, role))
        path = _rollouts.get(thread)
        if not path:
            hits = glob.glob(f"{HOME}/.codex/sessions/*/*/*/rollout-*{thread}.jsonl")
            if not hits:  # another account's session, not readable from here
                return (cwd and _proc_label(cwd)) or (role and _conf_label(family, role))
            path = _rollouts[thread] = hits[0]
        model, effort = _scan_file(path, codex=True)
        if not model:
            return None
        info = _codex_models().get(model, {})
        if effort == "default":
            effort = info.get("default_reasoning_level")
        name = info.get("display_name") or model
        return f"{name} · {effort}" if effort else name
    if family == "Claude":
        model = effort = None
        if cwd:
            slug = re.sub(r"[^A-Za-z0-9]", "-", cwd)
            sessions = sorted(glob.glob(f"{HOME}/.claude/projects/{slug}/*.jsonl"), key=os.path.getmtime)
            if sessions:
                model, effort = _scan_file(sessions[-1], codex=False)
        if not model:
            try:
                usage = json.loads(open(log).read()).get("modelUsage") or {}
                model = max(usage, key=lambda k: usage[k].get("outputTokens", 0)) if usage else None
            except (OSError, ValueError, AttributeError):
                pass
        if not model:
            return None
        return f"{_claude_name(model)} · {effort}" if effort else _claude_name(model)
    return None


_ticks = {}  # job -> (time, cpu ticks of its processes)
HZ = os.sysconf("SC_CLK_TCK")


def proc_usage(pids):
    """CPU ticks and resident memory (bytes) of a set of processes."""
    ticks = rss = 0
    for pid in pids:
        try:
            fields = open(f"/proc/{pid}/stat").read().rsplit(")", 1)[1].split()
            ticks += int(fields[11]) + int(fields[12])  # utime, stime
            rss += int(fields[21]) * os.sysconf("SC_PAGE_SIZE")
        except (OSError, IndexError, ValueError):
            pass
    return ticks, rss


def cpu_used(key, ticks):
    """Cores used since the last look (about the refresh interval)."""
    now = time.time()
    prev = _ticks.get(key)
    _ticks[key] = (now, ticks)
    if not prev or now - prev[0] < 1:
        return None
    return max(0.0, (ticks - prev[1]) / HZ / (now - prev[0]))


def machine():
    out = run(["sinfo", "-h", "-o", "%C|%m"]).strip().split("|")
    alloc = total = None
    if len(out) == 2:
        a, i, o, t = out[0].split("/")
        alloc, total = int(a), int(t)
    mem = {}
    for line in open("/proc/meminfo"):
        k, v = line.split(":")
        mem[k] = int(v.split()[0]) * 1024
    busy = None
    try:
        v = [int(x) for x in open("/proc/stat").readline().split()[1:]]
        idle, all_ = v[3] + v[4], sum(v[:8])
        prev = _ticks.get("__machine")
        _ticks["__machine"] = (idle, all_)
        if prev and all_ > prev[1]:
            busy = (1 - (idle - prev[0]) / (all_ - prev[1])) * os.cpu_count()
    except (OSError, ValueError):
        pass
    pools = []
    for user, d in _pool_dirs():
        try:
            q, period = open(f"{d}/cpu.max").read().split()
            usec = int(next(l.split()[1] for l in open(f"{d}/cpu.stat") if l.startswith("usage_usec")))
            memc = int(open(f"{d}/memory.current").read())
            memmax = open(f"{d}/memory.max").read().strip()
        except (OSError, ValueError, StopIteration):
            continue
        now = time.time()
        prev = _ticks.get("__pool" + user)
        _ticks["__pool" + user] = (now, usec)
        used = (usec - prev[1]) / 1e6 / (now - prev[0]) if prev and now > prev[0] else None
        n = sum(1 for a in agent_registrations() if a.get("user") == user)
        pools.append(dict(user=user, cap=None if q == "max" else int(q) / int(period), used=used, mem=memc,
                          mem_cap=None if memmax == "max" else int(memmax), agents=n))
    return dict(cpus=os.cpu_count(), alloc=alloc, slurm_cpus=total, busy=busy, pools=pools,
                load=os.getloadavg(), mem_total=mem.get("MemTotal"),
                mem_used=mem.get("MemTotal", 0) - mem.get("MemAvailable", 0))


def claude_live(cwd, user=None):
    """A running Claude worker's latest message (and what it is doing now) from its live transcript.
    claude -p writes its own log only at the end; the transcript is written as it goes, in the home of the
    account the worker runs as (the agent account's needs an ACL letting hpc read ~/.claude/projects)."""
    slug = re.sub(r"[^A-Za-z0-9]", "-", cwd)
    home = os.path.expanduser(f"~{user}") if user else HOME
    sessions = sorted(glob.glob(f"{home}/.claude/projects/{slug}/*.jsonl"), key=os.path.getmtime)
    if not sessions:
        return dict(message=None, updated=None)
    path = sessions[-1]
    try:
        with open(path, "rb") as f:
            f.seek(max(0, os.path.getsize(path) - 2_000_000))
            lines = f.read().splitlines()
    except OSError:
        return dict(message=None, updated=None)
    text = doing = None
    for line in reversed(lines):
        try:
            d = json.loads(line)
        except ValueError:
            continue
        if d.get("type") != "assistant":
            continue
        for c in reversed((d.get("message") or {}).get("content") or []):
            if not isinstance(c, dict):
                continue
            if c.get("type") == "text" and c.get("text", "").strip() and text is None:
                text = c["text"].strip()
            elif c.get("type") == "tool_use" and doing is None and text is None:
                inp = c.get("input") or {}
                doing = (inp.get("description") or inp.get("file_path") or inp.get("pattern")
                         or (inp.get("command") or "").split("\n")[0][:120] or c.get("name"))
        if text:
            break
    msg = text
    if doing:
        msg = f"{text}\n\nNow: {doing}" if text else f"Now: {doing}"
    return dict(message=msg, updated=os.path.getmtime(path))


def jobs():
    out = run(["squeue", "-h", "-o", "%i|%j|%T|%M|%l|%C|%m|%u"])
    rows = []
    compute = {}   # agent id -> its lab-run Slurm jobs (named lab:<project>:run:<issue>:<agent>)
    for line in out.splitlines():
        jid, name, state, elapsed, limit, cpus, mem, user = line.split("|")
        parts = name.split(":")
        if len(parts) == 5 and parts[0] == "lab" and parts[2] == "run":
            compute.setdefault(parts[4], []).append(dict(job=jid, state=state.lower(), elapsed=elapsed, limit=limit, cpus=cpus))
            continue
        if len(parts) != 4 or parts[0] != "lab":
            continue
        _, project, role, issue = parts
        log = f"{PROJECTS}/{project}/logs/{jid}-{role}-{issue}.jsonl"
        pids = run(["scontrol", "listpids", jid]).split()
        pids = [p for p in pids if p.isdigit()]
        msg, mtime = last_message(log)
        ticks, rss = proc_usage(pids)
        rows.append(dict(cpu_used=cpu_used(jid, ticks), rss=rss, kind=role, project=project, issue=issue, job=jid, state=state.lower(),
                         elapsed=elapsed, limit=limit, cpus=cpus, mem=mem, user=user,
                         model=(fam := model_of(log, pids)),
                         model_label=model_label(fam, log, f"{PROJECTS}/{project}/jobs/{jid}", role),
                         title=issue_title(project, issue),
                         **(dict(message=msg, updated=mtime) if msg or fam != "Claude"
                            else claude_live(f"{PROJECTS}/{project}/jobs/{jid}", user)),
                         url=f"https://github.com/{ORG}/{project}/issues/{issue}"))
    rows += agent_rows(compute)
    return rows


def agent_registrations():
    out = []
    for f in glob.glob(f"{LAB}/state/agents/a*.json"):
        try:
            out.append(json.load(open(f)))
        except (OSError, ValueError):
            pass
    return out


def agent_clone_procs(clone):
    """Processes whose command line names an agent's clone (codex --cd <clone> ...)."""
    out = []
    for d in os.listdir("/proc"):
        if d.isdigit():
            try:
                args = open(f"/proc/{d}/cmdline", "rb").read().split(b"\0")
            except OSError:
                continue
            if args and args[0].endswith(b"codex") and clone.encode() in args:
                out.append(d)
    return out


def descendants(pid):
    """pid and all its descendant processes, from /proc."""
    children = {}
    for d in os.listdir("/proc"):
        if d.isdigit():
            try:
                ppid = open(f"/proc/{d}/stat").read().rsplit(")", 1)[1].split()[1]
                children.setdefault(ppid, []).append(d)
            except (OSError, IndexError):
                pass
    out, todo = [], [str(pid)]
    while todo:
        p = todo.pop()
        out.append(p)
        todo += children.get(p, [])
    return out


def agent_rows(compute=None):
    """Agents running outside Slurm (AGENT_RUNNER=systemd), from their registrations in state/agents."""
    compute = compute or {}
    rows = []
    for f in glob.glob(f"{LAB}/state/agents/a*.json"):
        try:
            a = json.load(open(f))
        except (OSError, ValueError):
            continue
        pid = str(a.get("pid", ""))
        try:   # alive only if that pid is the agent's own service (not a reused pid)
            cg = open(f"/proc/{pid}/cgroup").read().strip().split("::", 1)[-1]
        except OSError:
            continue
        if not re.fullmatch(r"a\d+", str(a.get("id", ""))) or not cg.endswith(f"/lab-agent-{a['id']}.service"):
            continue
        parts = a.get("name", "").split(":")
        if len(parts) != 4:
            continue
        _, project, role, issue = parts
        jid = a["id"]
        e = int(time.time() - a.get("start", time.time()))
        elapsed = (f"{e // 86400}-{e % 86400 // 3600:02d}:{e % 3600 // 60:02d}:{e % 60:02d}" if e >= 86400
                   else f"{e // 3600}:{e % 3600 // 60:02d}:{e % 60:02d}" if e >= 3600 else f"{e // 60}:{e % 60:02d}")
        log = f"{PROJECTS}/{project}/logs/{jid}-{role}-{issue}.jsonl"
        try:   # every process in the service (lab-worker, the tmux server, a Claude agent)
            pids = open(f"/sys/fs/cgroup{cg}/cgroup.procs").read().split()
        except OSError:
            pids = descendants(pid)
        # tmux puts each pane (an interactive Codex agent) in its own scope beside the service: find it by its clone
        for q in agent_clone_procs(f"{PROJECTS}/{project}/jobs/{jid}"):
            pids += [x for x in descendants(q) if x not in pids]
        msg, mtime = last_message(log)
        ticks, rss = proc_usage(pids)
        rows.append(dict(cpu_used=cpu_used(jid, ticks), rss=rss, kind=role, project=project, issue=issue, job=jid, state="running",
                         pool=True, compute=compute.get(jid, []),
                         elapsed=elapsed, limit=f"{a.get('hours', '?')}:00:00", cpus=a.get("cpus", "?"),
                         mem=a.get("mem", ""), user=a.get("user", ""),
                         model=(fam := model_of(log, pids)),
                         model_label=model_label(fam, log, f"{PROJECTS}/{project}/jobs/{jid}", role),
                         title=issue_title(project, issue),
                         **(dict(message=msg, updated=mtime) if msg or fam != "Claude"
                            else claude_live(f"{PROJECTS}/{project}/jobs/{jid}", a.get("user"))),
                         url=f"https://github.com/{ORG}/{project}/issues/{issue}"))
    return rows


def pass_info(running_flag, logs_glob, last_md):
    running = os.path.exists(running_flag)
    since = os.path.getmtime(running_flag) if running else None
    logs = sorted(glob.glob(logs_glob), key=os.path.getmtime)
    msg, mtime = (None, None)
    if running and logs:
        msg, mtime = last_message(logs[-1])
    last = None
    try:
        last = open(last_md).read().strip()
        last_time = os.path.getmtime(last_md)
    except OSError:
        last_time = None
    return running, since, msg, mtime, last, last_time


def _last_label(family, logs_glob, cwd, role):
    logs = sorted(glob.glob(logs_glob), key=os.path.getmtime)
    return model_label(family, logs[-1], cwd, role) if logs else _conf_label(family, role)


def people(project):
    """Collaborators from the "People" table of the project's AGENTS.md (the lab and the PI left out): name and
    profile link per handle. GitHub unless written gitlab:<handle>."""
    try:
        text = open(f"{PROJECTS}/{project}/AGENTS.md").read()
    except OSError:
        return []
    m = re.search(r"^## *People\s*\n(.*?)(?=^## |\Z)", text, re.S | re.M)
    out = []
    for line in (m.group(1) if m else "").splitlines():
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) < 2 or not line.lstrip().startswith("|"):
            continue
        handles = re.findall(r"`([^`]+)`", cells[0])
        if not handles or handles[0] in ("lab", PI):
            continue
        name = re.sub(r"\s*\([^)]*\)", "", cells[1])            # "(human)", "(human, GitHub @x)"
        name = re.sub(r",?\s*and (his|her|their) agents?", "", name).strip(" ,") or handles[0]
        links = []
        for h in handles:
            if h.startswith("gitlab:"):
                links.append(dict(handle=h, url=f"https://gitlab.com/{h.split(':', 1)[1]}"))
            else:
                links.append(dict(handle=h, url=f"https://github.com/{h}"))
        out.append(dict(name=name, handles=links, role=cells[2] if len(cells) > 2 else ""))
    return out


def leads(registry):
    rows = []
    for project, p in sorted(registry.get("projects", {}).items()):
        if p.get("status") == "retired":
            continue
        running, since, msg, mtime, last, last_time = pass_info(
            f"{LAB}/state/pass-lead-{project}.running",
            f"{PROJECTS}/{project}/logs/lead-*.jsonl",
            f"{PROJECTS}/{project}/logs/lead-last.md")
        fam = (p.get("lead_model") or "codex").capitalize()
        if running and not msg and fam == "Claude":
            # claude -p writes the pass's log only at the end: read the live transcript (the newest session in
            # the project folder, in the lead account's home), as for Claude workers.
            live = claude_live(f"{PROJECTS}/{project}", p.get("account"))
            if live.get("message") and (live.get("updated") or 0) >= (since or 0):
                msg, mtime = live["message"], live["updated"]
        if running and not msg:   # nothing yet from this pass: show the last pass's summary
            msg, mtime = last, last_time
        rows.append(dict(kind="lead", project=project, status=p.get("status"), limit=p.get("limit"),
                         account=p.get("account"), model=fam,
                         model_label=_last_label(fam, f"{PROJECTS}/{project}/logs/lead-*.jsonl", f"{PROJECTS}/{project}", "lead"),
                         budget=p.get("hpc_sus_month"), people=people(project),
                         running=running, since=since, message=msg if running else last,
                         updated=mtime if running else last_time,
                         url=f"https://github.com/{ORG}/{project}"))
    return rows


def director():
    running, since, msg, mtime, last, last_time = pass_info(
        f"{LAB}/state/pass-director.running", f"{LAB}/state/logs/director-*.jsonl",
        f"{LAB}/state/director-last.md")
    fam = _setting("DIRECTOR_MODEL", "codex").capitalize()
    if running and not msg:   # a Claude pass logs only at the end (its transcript shares the lab folder with the PI's chat)
        msg, mtime = last, last_time
    return dict(kind="director", model=fam, model_label=_last_label(fam, f"{LAB}/state/logs/director-*.jsonl", LAB, "director"),
                running=running, since=since,
                message=msg if running else last, updated=mtime if running else last_time)


_alerts = [0, []]


def alerts():  # open lab-wide `alert` issues in ORG/lab (LAB-RULES.md, "Lab-wide problems")
    if time.time() - _alerts[0] < 60:
        return _alerts[1]
    out = run(["gh", "issue", "list", "-R", f"{ORG}/lab", "--label", "alert", "--state", "open",
               "--json", "number,title,url,createdAt,updatedAt,comments"])
    try:
        rows = json.loads(out)
    except Exception:
        return _alerts[1]  # keep the last answer if GitHub doesn't reply
    _alerts[:] = [time.time(), [dict(number=r["number"], title=r["title"], url=r["url"], created=r["createdAt"],
                                     updated=r["updatedAt"], comments=len(r.get("comments") or [])) for r in rows]]
    return _alerts[1]


def chats():
    out = run(["tmux", "list-windows", "-t", "agents", "-F", "#W"])
    return [w for w in out.split() if w.startswith("chat")]


def status():
    try:
        registry = json.load(open(f"{LAB}/registry.json"))
    except Exception:
        registry = {"projects": {}}
    js = jobs()
    counts = {}
    for j in js:
        if j["state"] == "running":
            counts[j["project"]] = counts.get(j["project"], 0) + 1
    ls = leads(registry)
    for lead in ls:
        lead["jobs"] = counts.get(lead["project"], 0)
    data = dict(time=time.time(), machine=machine(), director=director(), leads=ls, jobs=js, chats=chats(), usage=usage(), org=ORG, alerts=alerts())
    data["estimates"] = estimates(data["usage"], js)
    return data


def usage():
    """`lab usage`'s summary, refreshed when older than five minutes, with Claude's live limits."""
    usage_dir = f"{LAB}/state/usage"
    summary = f"{usage_dir}/summary.json"
    try:
        stale = time.time() - os.path.getmtime(summary) > 300
    except OSError:
        stale = True
    if stale:
        run(["lab", "usage", "--refresh"], timeout=60)
    try:
        data = json.load(open(summary))
    except Exception:
        return {}
    try:  # written more often than the summary
        plan = json.load(open(f"{usage_dir}/claude-limits.json"))
        if plan.get("seen", 0) >= (data.get("claude", {}).get("plan") or {}).get("seen", 0):
            data.setdefault("claude", {})["plan"] = plan
    except Exception:
        pass
    data["mtime"] = os.path.getmtime(summary)
    try:
        data.setdefault("claude", {})["credits"] = credits()
    except Exception:
        pass
    try:   # the center's own report on the allocation (lab-usage saves HPC_BALANCE_CMD's output), shown as text
        path = f"{usage_dir}/hpc-allocation.txt"
        data.setdefault("hpc", {})["allocation"] = dict(text=open(path).read()[:3000], as_of=os.path.getmtime(path))
    except OSError:
        pass
    try:
        data.setdefault("hpc", {})["scratch"] = json.load(open(SCRATCH))
    except (OSError, ValueError):
        pass
    return data



# --- Claude credits: what the lab's Claude runs cost (each claude -p result line reports total_cost_usd, at API
# prices), and the balance the PI last reported. The account's balance itself can't be read from the machine, so
# the PI (or the director, relaying the PI's words) appends a line to state/usage/claude-credits.tsv:
# <epoch>\t<balance in USD>\t<note>, e.g. after buying credits or reading the balance on the account page.

CREDITS_LOG = f"{LAB}/state/usage/claude-credits.tsv"  # time, balance in USD, note: the PI's reported balances/deposits
PLAN_LOG = f"{LAB}/state/usage/claude-plan.tsv"  # seen, 5-hour %, its reset, week %, its reset: each new plan reading


def record_plan():
    """Append the plan's latest reading (claude-limits.json) when it is new, so runs can later be dated against it."""
    try:
        p = json.load(open(f"{LAB}/state/usage/claude-limits.json"))
        h = p.get("five_hour") or {}   # plans without a 5-hour limit report none
        row = [p["seen"], h.get("used_percentage", 0), h.get("resets_at", 0),
               p["seven_day"]["used_percentage"], p["seven_day"]["resets_at"]]
        last = open(PLAN_LOG).read().rstrip("\n").rsplit("\n", 1)[-1].split("\t") if os.path.exists(PLAN_LOG) else []
        if not last or float(last[0]) < row[0]:
            with open(PLAN_LOG, "a") as f:
                f.write("\t".join(str(x) for x in row) + "\n")
    except Exception:
        pass


def plan_full_at():
    """A function t -> True when the plan was used up at time t (5-hour or weekly limit at 100%, not yet reset),
    i.e. when Claude was running on credits. Uses the latest reading at or before t, however old: readings come
    only from interactive Claude sessions, so they can be hours apart, and a full window stays full until its reset."""
    rows = []
    try:
        for l in open(PLAN_LOG):
            f = l.split("\t")
            if len(f) >= 5 and not l.startswith("#"):
                rows.append([float(x) for x in f[:5]])
    except OSError:
        pass
    rows.sort()
    times = [r[0] for r in rows]

    def full(t):
        import bisect
        i = bisect.bisect_right(times, t) - 1
        if i < 0:
            return False
        _, h, hr, w, wr = rows[i]
        return (h >= 100 and t < hr) or (w >= 100 and t < wr)
    return full
_cost_cache = {}   # path -> (mtime, [(time, cost)])
COST_GLOBS = [f"{PROJECTS}/*/logs/*.jsonl", f"{LAB}/state/logs/*.jsonl"]


def _file_costs(path):
    try:
        mt = os.path.getmtime(path)
    except OSError:
        return []
    hit = _cost_cache.get(path)
    if hit and hit[0] == mt:
        return hit[1]
    out = []
    try:
        with open(path, "rb") as f:
            for line in f:
                if b'"total_cost_usd"' in line and b'"type":"result"' in line:
                    try:
                        d = json.loads(line)
                        out.append((mt, float(d.get("total_cost_usd") or 0), (d.get("duration_ms") or 0) / 1000))
                    except Exception:
                        pass
    except OSError:
        pass
    _cost_cache[path] = (mt, out)
    return out


def credits():
    now, spend = time.time(), []   # (time, project, cost); a run is dated by when its log was last written
    for g in COST_GLOBS:
        for path in glob.glob(g):
            if now - os.path.getmtime(path) > 8 * 86400:
                continue
            project = "director" if path.startswith(f"{LAB}/") else os.path.relpath(path, PROJECTS).split("/")[0]
            spend += [(t, project, c, dur) for t, c, dur in _file_costs(path)]
    record_plan()
    full = plan_full_at()
    # Only what ran while the plan was used up was paid from credits. A run's cost is taken as spread evenly over
    # its duration (it ends when its log was last written), so a long run is split between plan and credits.
    spend = [(t, p, c * sum(full(t - d * (k + 0.5) / 20) for k in range(20)) / 20) for t, p, c, d in spend]
    day = sum(c for t, _, c in spend if now - t <= 86400)
    week = sum(c for t, _, c in spend if now - t <= 7 * 86400)
    by = {}
    for t, p, c in spend:
        if now - t <= 86400:
            by[p] = by.get(p, 0) + c
    try:
        first = float(open(PLAN_LOG).readline().split("\t")[0])
    except Exception:
        first = now
    out = dict(day=round(day, 2), week=round(week, 2), by_project_day={k: round(v, 2) for k, v in by.items()},
               tracked_since=first)
    try:
        rows = [l.rstrip("\n").split("\t") for l in open(CREDITS_LOG) if l.strip() and not l.startswith("#")]
        t0, bal, note = float(rows[-1][0]), float(rows[-1][1]), rows[-1][2] if len(rows[-1]) > 2 else ""
        since = sum(c for t, _, c in spend if t > t0)
        out.update(reported=bal, reported_at=t0, reported_note=note, spent_since=round(since, 2),
                   estimate=round(bal - since, 2))
    except Exception:
        pass
    mode = _setting("CLAUDE_CREDITS", "off")
    out_flag = f"{LAB}/state/usage/claude-credits-out"
    if mode == "on" and os.path.exists(out_flag) and now - os.path.getmtime(out_flag) < 6 * 3600:
        mode = "paused"   # a run failed for lack of credits: Claude waits 6 h (lib.sh claude_credits_out)
    out["mode"] = mode
    return out


# --- How many more workers fit: from samples of plan usage and of the number of running workers.

SAMPLES = f"{LAB}/state/usage/samples.tsv"  # time, codex %, codex reset, claude week %, claude reset, codex jobs, claude jobs


def sample(u, jobs):
    c = ((u.get("codex") or {}).get("windows") or [{}])[0]
    p = ((u.get("claude") or {}).get("plan") or {}).get("seven_day") or {}
    running = [j for j in jobs if j["state"] == "running"]
    row = [time.time(), c.get("used_percent"), c.get("resets_at"), p.get("used_percentage"), p.get("resets_at"),
           sum(j["model"] != "Claude" for j in running), sum(j["model"] == "Claude" for j in running)]
    try:
        last = float(open(SAMPLES).read().splitlines()[-1].split("\t")[0])
    except (OSError, IndexError, ValueError):
        last = 0
    if row[1] is not None and time.time() - last >= 300:
        with open(SAMPLES, "a") as f:
            f.write("\t".join("" if v is None else str(v) for v in row) + "\n")


def read_samples(hours):
    rows = []
    try:
        for line in open(SAMPLES):
            v = line.rstrip("\n").split("\t")
            if len(v) == 7 and float(v[0]) >= time.time() - hours * 3600:
                rows.append([float(x) if x else None for x in v])
    except OSError:
        pass
    return rows


def headroom(name, used, reset, stop, rows, col, jobs_col, running, fallback_start):
    """Per-worker burn (points of the plan per hour) from the samples, and the workers that fit."""
    now = time.time()
    if used is None or reset is None:
        return dict(name=name, note="no usage data")
    hours_left = max(0.1, (reset - now) / 3600)
    pts = [(r[0], r[col], r[jobs_col]) for r in rows if r[col] is not None and r[2 if col == 1 else 4] == reset]
    rate = basis = None
    # The plans report whole percents, so a trend needs several points of change (or a long span)
    # before it means anything: one tick in half an hour could be anything from 0 to 2 points an hour.
    if len(pts) >= 2 and (pts[-1][1] - pts[0][1] >= 3 or pts[-1][0] - pts[0][0] >= 3 * 3600):
        burn = (pts[-1][1] - pts[0][1]) / ((pts[-1][0] - pts[0][0]) / 3600)
        agents = sum(p[2] for p in pts) / len(pts)
        if agents >= 0.5:
            rate, basis = max(burn, 0) / agents, f"trend over the last {(pts[-1][0] - pts[0][0]) / 3600:.1f} h, {agents:.1f} workers on average"
    if rate is None and fallback_start and running:
        h = max(0.5, (now - fallback_start) / 3600)
        rate, basis = used / h / running, f"rough: all {used:.0f}% so far over {h:.1f} h, today's {running} workers"
    out = dict(name=name, used=used, stop=stop, hours_left=hours_left, running=running, basis=basis)
    if rate is None or rate <= 0:
        out["note"] = ("not enough data yet: the plan reports whole percents, so the estimate waits for "
                       "3 points of change or 3 hours of samples with workers running")
        return out
    room = max(0.0, stop - used)
    sustain = room / hours_left / rate
    out.update(rate=rate, sustain=sustain, extra=math.floor(sustain - running),
               hours_at_now=room / (rate * running) if running else None)
    return out


def estimates(u, jobs):
    sample(u, jobs)
    rows = read_samples(6)
    c = ((u.get("codex") or {}).get("windows") or [{}])[0]
    cl = u.get("claude") or {}
    p = (cl.get("plan") or {}).get("seven_day") or {}
    running = [j for j in jobs if j["state"] == "running"]
    n_codex = sum(j["model"] != "Claude" for j in running)
    n_claude = sum(j["model"] == "Claude" for j in running)
    # Until samples accumulate, average from the start of the current window.
    start = (c.get("resets_at") or time.time()) - 7 * 86400
    codex = headroom("Codex", c.get("used_percent"), c.get("resets_at"), 95.0, rows, 1, 5, n_codex, start)
    claude = headroom("Claude", p.get("used_percentage"), p.get("resets_at"), float(cl.get("stop_percent") or 60),
                      rows, 3, 6, n_claude, None)
    runs, cap = cl.get("lab_runs_7d") or 0, cl.get("lab_runs_cap") or 30
    claude["runs_left"] = max(0, cap - runs)
    return dict(codex=codex, claude=claude)

PAGE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "index.html")  # read at each request

# Names this page answers to. Checking the Host header stops a web page elsewhere from reading the status
# through DNS rebinding; filled in at startup with this machine's names and Tailscale address and name.
ALLOWED_HOSTS = {"localhost", "127.0.0.1"}

_status = [0.0, None]
_status_lock = threading.Lock()


def cached_status(max_age=15):
    """status() at most every max_age seconds, however many pages are open."""
    with _status_lock:
        if _status[1] is None or time.time() - _status[0] > max_age:
            _status[:] = [time.time(), json.dumps(status()).encode()]
        return _status[1]


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        host = (self.headers.get("Host") or "").rsplit(":", 1)[0].strip("[]").lower()
        if host not in ALLOWED_HOSTS:
            self.send_error(403)
            return
        if self.path.startswith("/api/status"):
            body, kind = cached_status(), "application/json"
        elif self.path in ("/", "/index.html"):
            body, kind = open(PAGE, "rb").read(), "text/html; charset=utf-8"
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


# --- Capacity statistics, for deciding the numbers later (agent pool, project limits, machine size). Every 5
# minutes, one JSON line in state/usage/capacity.jsonl: Slurm CPUs given out and actually busy, the agent pools,
# memory, the queue (how many wait, how long), lab-run jobs, and agents per project against its limit.
# `lab-capacity` summarizes it.
CAPACITY = f"{LAB}/state/usage/capacity.jsonl"


def _cg_cpu_usec(path):
    try:
        return int(next(l.split()[1] for l in open(f"{path}/cpu.stat") if l.startswith("usage_usec")))
    except (OSError, StopIteration, ValueError):
        return None


def capacity_sample(prev):
    now = time.time()
    v = [int(x) for x in open("/proc/stat").readline().split()[1:]]
    idle, all_ = v[3] + v[4], sum(v[:8])
    cur = {"t": now, "idle": idle, "all": all_}
    rec = {"time": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "cpus": os.cpu_count(), "load1": os.getloadavg()[0]}
    if prev and all_ > prev["all"]:
        rec["busy_cpus"] = round((1 - (idle - prev["idle"]) / (all_ - prev["all"])) * os.cpu_count(), 2)
    mem = {}
    for line in open("/proc/meminfo"):
        k, val = line.split(":")
        mem[k] = int(val.split()[0]) * 1024
    rec["mem_used_gb"] = round((mem["MemTotal"] - mem["MemAvailable"]) / 1e9, 2)
    rec["mem_total_gb"] = round(mem["MemTotal"] / 1e9, 2)
    out = run(["sinfo", "-h", "-o", "%C"]).strip().split("/")
    if len(out) == 4:
        rec["slurm_alloc"], rec["slurm_total"] = int(out[0]), int(out[3])
    # The queue: running and pending jobs, CPUs asked, and how long the pending ones have waited.
    q = {"running": 0, "pending": 0, "pending_cpus": 0, "max_wait_min": 0, "lab_run_running": 0, "lab_run_pending": 0,
         "slurm_agents": 0}
    for line in run(["squeue", "-h", "-o", "%i|%j|%T|%C|%V"]).splitlines():
        try:
            jid, name, state, cpus, submit = line.split("|")
        except ValueError:
            continue
        parts = name.split(":")
        if len(parts) == 5 and parts[2] == "run":
            q["lab_run_running" if state == "RUNNING" else "lab_run_pending"] += 1
        if len(parts) == 4 and parts[0] == "lab" and parts[2] in ("worker", "explorer", "verifier") and state == "RUNNING":
            q["slurm_agents"] += 1
        if state == "RUNNING":
            q["running"] += 1
        elif state == "PENDING":
            q["pending"] += 1
            q["pending_cpus"] += int(cpus) if cpus.isdigit() else 0
            try:
                w = (now - time.mktime(time.strptime(submit, "%Y-%m-%dT%H:%M:%S"))) / 60
                q["max_wait_min"] = max(q["max_wait_min"], round(w))
            except ValueError:
                pass
    rec["queue"] = q
    # The agent pools, per account.
    pools = {}
    for user, d in _pool_dirs():
        usec = _cg_cpu_usec(d)
        if usec is None:
            continue
        cur["pool_" + user] = usec
        p = {}
        try:
            qv, period = open(f"{d}/cpu.max").read().split()
            p["cap"] = None if qv == "max" else int(qv) / int(period)
            p["mem_gb"] = round(int(open(f"{d}/memory.current").read()) / 1e9, 2)
        except (OSError, ValueError):
            pass
        if prev and prev.get("pool_" + user) is not None:
            p["used"] = round((usec - prev["pool_" + user]) / 1e6 / (now - prev["t"]), 2)
        pools[user] = p
    rec["pools"] = pools
    # Agents per project (outside Slurm and in it) against the project's limit.
    try:
        reg = json.load(open(f"{LAB}/registry.json")).get("projects", {})
    except (OSError, ValueError):
        reg = {}
    counts = {}
    for a in agent_registrations():
        parts = a.get("name", "").split(":")
        if len(parts) == 4:
            counts[parts[1]] = counts.get(parts[1], 0) + 1
    for line in run(["squeue", "-h", "-t", "R,PD", "-o", "%j"]).splitlines():
        parts = line.split(":")
        if len(parts) == 4 and parts[0] == "lab" and parts[2] in ("worker", "explorer", "verifier"):
            counts[parts[1]] = counts.get(parts[1], 0) + 1
    rec["projects"] = {k: {"agents": counts.get(k, 0), "limit": v.get("limit"), "status": v.get("status")}
                       for k, v in reg.items() if v.get("status") in ("active", "paused")}
    try:
        u = json.load(open(f"{LAB}/state/usage/summary.json"))
        rec["claude_week_pct"] = ((u.get("claude") or {}).get("plan") or {}).get("seven_day", {}).get("used_percentage")
        rec["codex_week_pct"] = max((w.get("used_percent", 0) for w in (u.get("codex") or {}).get("windows", [])), default=None)
    except (OSError, ValueError):
        pass
    return rec, cur


SCRATCH = f"{LAB}/state/usage/hpc-scratch.json"
_SAFE = re.compile(r"[A-Za-z0-9_./-]+")


def scratch_sample():
    """The cluster's scratch quota (Lustre `lfs quota`) for the lab's group (HPC_SCRATCH_GROUP; on many centers the
    group's limit is the one that matters, since everyone in the allocation shares it) and for HPC_USER, on the
    filesystem HPC_SCRATCH_FS, via the shared connection (hpc-check first, so a lost connection costs nothing).
    Unset HPC_SCRATCH_FS: nothing is sampled."""
    fs, group, user = _conf("HPC_SCRATCH_FS"), _conf("HPC_SCRATCH_GROUP"), _conf("HPC_USER")
    if not fs or not all(_SAFE.fullmatch(x) for x in (fs, group or "x", user or "x")):
        return
    if subprocess.run(["hpc-check"], capture_output=True, timeout=60).returncode:
        return
    cmds = ([f"lfs quota -g {group} {fs}"] if group else []) + ([f"lfs quota -u {user} {fs}"] if user else [])
    if not cmds:
        return
    out = subprocess.run(["ssh", "-n", "cluster", "; ".join(cmds)], capture_output=True, text=True, timeout=120).stdout
    nums = [l.split() for l in out.splitlines() if l.strip() and l.split()[0].rstrip("*").isdigit()]
    if len(nums) < len(cmds):   # kbytes used, quota, limit, (grace), files ...; a '*' marks over a limit
        return
    rec = dict(time=time.time())
    if group:
        g = nums.pop(0)
        rec.update(group=group, group_used_kb=int(g[0].rstrip("*")), group_limit_kb=int(g[2].rstrip("*")))
    if user:
        u = nums.pop(0)
        rec.update(user=user, user_used_kb=int(u[0].rstrip("*")), user_limit_kb=int(u[2].rstrip("*")))
    tmp = SCRATCH + ".tmp"
    open(tmp, "w").write(json.dumps(rec))
    os.replace(tmp, SCRATCH)


def capacity_loop(every=300):
    prev, n = None, 0
    while True:
        if n % 6 == 0:   # every 30 minutes
            try:
                scratch_sample()
            except Exception:
                pass
        n += 1
        record_plan()   # plan readings, also when nobody has the page open
        try:
            rec, cur = capacity_sample(prev)
            if prev is not None:   # the first sample only sets the baseline for CPU rates
                with open(CAPACITY, "a") as f:
                    f.write(json.dumps(rec, separators=(",", ":")) + "\n")
            prev = cur
        except Exception:
            pass
        time.sleep(every)


if __name__ == "__main__":
    threading.Thread(target=capacity_loop, daemon=True).start()
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8765)
    args = ap.parse_args()
    # Also listen on the Tailscale address, so the PI's phone (on their tailnet) can open it.
    ALLOWED_HOSTS.update({socket.gethostname().lower(), socket.getfqdn().lower()})
    try:
        me = json.loads(subprocess.run(["tailscale", "status", "--json"], capture_output=True, text=True,
                                       timeout=5).stdout or "{}").get("Self", {})
        ALLOWED_HOSTS.update(n.lower() for n in [(me.get("DNSName") or "").rstrip("."), me.get("HostName") or ""] if n)
        ALLOWED_HOSTS.update(me.get("TailscaleIPs") or [])
    except Exception:
        pass
    try:
        ts = subprocess.run(["tailscale", "ip", "-4"], capture_output=True, text=True, timeout=5).stdout.split()
        if ts:
            srv = ThreadingHTTPServer((ts[0], args.port), Handler)
            threading.Thread(target=srv.serve_forever, daemon=True).start()
    except Exception:
        pass
    ThreadingHTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
