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


ORG = _conf("ORG")
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
    return dict(cpus=os.cpu_count(), alloc=alloc, slurm_cpus=total, busy=busy,
                load=os.getloadavg(), mem_total=mem.get("MemTotal"),
                mem_used=mem.get("MemTotal", 0) - mem.get("MemAvailable", 0))


def claude_live(cwd):
    """A running Claude worker's latest message (and what it is doing now) from its live transcript.
    claude -p writes its own log only at the end; the transcript is written as it goes."""
    slug = re.sub(r"[^A-Za-z0-9]", "-", cwd)
    sessions = sorted(glob.glob(f"{HOME}/.claude/projects/{slug}/*.jsonl"), key=os.path.getmtime)
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
    for line in out.splitlines():
        jid, name, state, elapsed, limit, cpus, mem, user = line.split("|")
        parts = name.split(":")
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
                            else claude_live(f"{PROJECTS}/{project}/jobs/{jid}")),
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


def leads(registry):
    rows = []
    for project, p in sorted(registry.get("projects", {}).items()):
        if p.get("status") == "retired":
            continue
        running, since, msg, mtime, last, last_time = pass_info(
            f"{LAB}/state/pass-lead-{project}.running",
            f"{PROJECTS}/{project}/logs/lead-*.jsonl",
            f"{PROJECTS}/{project}/logs/lead-last.md")
        rows.append(dict(kind="lead", project=project, status=p.get("status"), limit=p.get("limit"),
                         account=p.get("account"), model=(fam := (p.get("lead_model") or "codex").capitalize()),
                         model_label=_last_label(fam, f"{PROJECTS}/{project}/logs/lead-*.jsonl", f"{PROJECTS}/{project}", "lead"),
                         budget=p.get("hpc_sus_month"),
                         running=running, since=since, message=msg if running else last,
                         updated=mtime if running else last_time,
                         url=f"https://github.com/{ORG}/{project}"))
    return rows


def director():
    running, since, msg, mtime, last, last_time = pass_info(
        f"{LAB}/state/pass-director.running", f"{LAB}/state/logs/director-*.jsonl",
        f"{LAB}/state/director-last.md")
    return dict(kind="director", model="Codex", model_label=_last_label("Codex", f"{LAB}/state/logs/director-*.jsonl", LAB, "director"),
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
    return data



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


if __name__ == "__main__":
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
