"""Pace watch: notices irregular movement and lets Gemini decide whether to check in.

Every 5 s of walk time we record a pace sample (speed, and distance to the destination).
A rule layer looks for patterns that don't fit a normal walk home:
    running        well above the walker's own usual pace for 15 s (but slower than a car)
    stop_and_go    4+ switches between standing and walking within a minute
    backtracking   moving 40 m+ away from the destination within a minute
    sudden_stop    standing still for 75 s after walking briskly
When one shows up, Gemini gets the recent pace trace and decides: is this irregular enough to
check in? It also writes the buddy's line and a short pace note for friends. If Gemini says no,
the walk carries on and the log shows why. If Gemini is not configured, fails or times out, the
buddy checks in anyway: the safety path never depends on the AI answering.
After a pace check-in the usual ladder applies: no pet -> nudge -> final -> countdown -> friends.
"""
import logging
import os
import statistics
import threading

from .geo import dist_m

log = logging.getLogger("pupdate.pace")

SAMPLE_EVERY_S = 5.0
KEEP = 36  # 3 minutes of samples
DEFAULT_BASE = 1.35  # m/s, a normal walk
COOLDOWN_S = 120.0  # after a pace check-in, give the walker 2 minutes before the next one
ASYNC = True  # tests switch this off to run the Gemini judge inline

PATTERN_TEXT = {
    "running": "started running",
    "stop_and_go": "keeps stopping and starting",
    "backtracking": "turned back, away from home",
    "sudden_stop": "stopped suddenly after walking briskly",
    "vehicle": "is moving at car speed",
}


def new_state():
    return {"samples": [], "last": None, "pattern": "steady", "note": None, "source": None,
            "episode": None, "cooldown_until": None, "judging": False, "mps": None, "baseline": None}


def features(samples):
    """samples: [[t, mps, dist_to_dest_or_None], ...] oldest first."""
    if len(samples) < 3:
        return None
    sp = [s[1] for s in samples]
    cur = statistics.median(sp[-3:])
    older = [v for v in sp[:-6] if v > 0.5]
    baseline = statistics.median(older) if len(older) >= 4 else DEFAULT_BASE
    baseline = max(0.8, min(2.0, baseline))
    t_end = samples[-1][0]
    recent = [s for s in samples if t_end - s[0] <= 60]
    # Stop/go flips, ignoring the in-between speeds.
    flips, prev = 0, None
    for s in recent:
        st = "stop" if s[1] < 0.3 else "go" if s[1] > 1.0 else None
        if st and prev and st != prev:
            flips += 1
        if st:
            prev = st
    dd = [s[2] for s in recent if s[2] is not None]
    backtrack = (dd[-1] - min(dd)) if len(dd) >= 2 else 0.0
    fast_line = max(2.6, 1.9 * baseline)

    def run_for(pred):
        n_t = None
        for s in reversed(samples):
            if not pred(s[1]):
                break
            n_t = s[0]
        return 0.0 if n_t is None else t_end - n_t + SAMPLE_EVERY_S

    return {"cur": round(cur, 2), "baseline": round(baseline, 2), "flips": flips, "backtrack_m": round(backtrack),
            "fast_for": run_for(lambda v: fast_line < v < 7.0), "stopped_for": run_for(lambda v: v < 0.3),
            "vehicle_for": run_for(lambda v: v >= VEHICLE_MPS)}


VEHICLE_MPS = 7.0  # 25 km/h: nobody walks or jogs home this fast for long
VEHICLE_FOR_S = 20.0


def mode_of(mps):
    if mps is None:
        return None
    if mps >= VEHICLE_MPS:
        return "vehicle"
    if mps >= 2.6:
        return "running"
    if mps >= 0.3:
        return "walking"
    return "still"


def detect(f):
    if not f:
        return None
    if f["vehicle_for"] >= VEHICLE_FOR_S:
        return "vehicle"
    if f["fast_for"] >= 15:
        return "running"
    if f["flips"] >= 4:
        return "stop_and_go"
    if f["backtrack_m"] >= 40 and f["cur"] > 0.5:
        return "backtracking"
    if f["stopped_for"] >= 75 and f["baseline"] >= 1.0:
        return "sudden_stop"
    return None


def trace_text(samples, n=18):
    t_end = samples[-1][0]
    rows = []
    for s in samples[-n:]:
        dest = "" if s[2] is None else f", {s[2]} m from home"
        rows.append(f"t-{round(t_end - s[0])}s: {s[1]} m/s{dest}")
    return "\n".join(rows)


def judge_prompt(walker, buddy, pattern, f, samples, place, hour):
    return (
        f"You watch the walking pace of {walker}, a student walking home at night (local hour {hour}) "
        f"with their virtual pet {buddy}. A simple rule noticed: {walker} {PATTERN_TEXT.get(pattern, pattern)}. "
        f"Usual pace {f['baseline']} m/s, now {f['cur']} m/s, {f['flips']} stop/go switches in the last minute, "
        f"{f['backtrack_m']} m moved away from home. Where: {place}.\n"
        f"Pace trace (oldest first):\n{trace_text(samples)}\n"
        "Decide if this looks irregular enough that the pet should check in now (a short wait at a crosswalk is "
        "normal; running, erratic stop-and-go or turning back at night is worth a check-in). Be cautious: when "
        "unsure, check in. Reply as JSON only: {\"check_in\": bool, \"pattern\": \"running|stop_and_go|backtracking|"
        "sudden_stop|normal\", \"buddy_line\": \"the pet's warm check-in question, max 70 chars, no emoji\", "
        "\"friend_note\": \"one factual sentence about the pace for friends, max 110 chars\", "
        "\"why\": \"max 80 chars\"}"
    )


def sample(w, now, pos, allow_trigger=True):
    """Record a pace sample. Returns engine events (a check-in) when a pattern starts."""
    p = w.setdefault("pace", new_state())
    last = p["last"]
    if last and now - last[0] < SAMPLE_EVERY_S - 1e-6:
        return []
    dest = w.get("dest")
    d_dest = round(dist_m(pos, dest)) if dest else None
    if last:
        dt = max(1e-6, now - last[0])
        mps = round(dist_m(last[1], pos) / dt, 2)
        p["samples"].append([round(now, 1), mps, d_dest])
        del p["samples"][:-KEEP]
    p["last"] = [now, list(pos)]
    if p.get("judging") and now - (p.get("judging_at") or now) > 40:
        p["judging"] = False  # a judge that never came back (e.g. server restart)
    f = features(p["samples"])
    if f:
        p["mps"], p["baseline"] = f["cur"], f["baseline"]
    if not allow_trigger or not w.get("watch_speed", True):
        return []
    pat = detect(f)
    if pat is None:
        p["episode"] = None
        if p["pattern"] != "steady" and not p.get("judging"):
            p["pattern"] = "steady"
        return []
    if p["episode"] == pat or (p["cooldown_until"] and now < p["cooldown_until"]) or p.get("judging"):
        return []
    p["episode"] = pat
    p["pattern"] = pat
    if pat == "vehicle":
        # Not a judgment call: 25+ km/h for 20 s is a vehicle. Tell the walker and their friends.
        kmh = round(f["cur"] * 3.6)
        from . import walks
        first = walks.user(w["walker_id"])["name"].split(" ")[0]
        walks.add_notice(w, "in_vehicle", f"{first} is moving at {kmh} km/h, likely in a car or bus.")
        p["note"], p["source"] = f"Moving at {kmh} km/h for {round(f['vehicle_for'])} s: a vehicle, not walking.", "rule"
        p["cooldown_until"] = now + COOLDOWN_S
        return [{"type": "pace_irregular", "pattern": pat, "at": now, "mps": f["cur"], "baseline": f["baseline"]}] + \
            w["engine"].request_checkin(now, "moving_fast")
    ev = [{"type": "pace_irregular", "pattern": pat, "at": now, "mps": f["cur"], "baseline": f["baseline"]}]
    if os.getenv("GEMINI_API_KEY") or _judge_override is not None:
        p["judging"], p["judging_at"] = True, now
        _start_judge(w, pat, f)
        return ev
    p["note"] = f"{PATTERN_TEXT[pat].capitalize()} ({f['cur']} m/s, usually {f['baseline']} m/s)."
    p["source"] = "rule"
    return ev + _checkin(w, now)


def _checkin(w, now, line=None):
    p = w["pace"]
    p["cooldown_until"] = now + COOLDOWN_S
    ev = w["engine"].request_checkin(now, "irregular_pace")
    if line:
        for e in ev:
            if e["type"] == "checkin_started":
                e["line"] = line
    return ev


_judge_override = None  # tests: a function(prompt) -> dict


def _gemini_judge(prompt):
    if _judge_override is not None:
        return _judge_override(prompt)
    from .buddy_ai import gemini_json
    return gemini_json(prompt, temperature=0.3, timeout=6)


def _start_judge(w, pattern, f):
    from . import walks
    u = walks.user(w["walker_id"])
    from datetime import datetime
    prompt = judge_prompt(u["name"].split(" ")[0], u["buddy"]["name"], pattern, f, w["pace"]["samples"],
                          walks.place_of(w), datetime.now().hour)

    def run():
        try:
            verdict = _gemini_judge(prompt) or {}
            source = "gemini"
        except Exception as e:  # any failure: be safe and check in
            log.warning("gemini pace judge failed: %s", e)
            verdict, source = {}, "rule"
        with walks.LOCK:
            _apply_verdict(w, pattern, f, verdict, source)

    if ASYNC:
        threading.Thread(target=run, daemon=True).start()
    else:
        run()


def _apply_verdict(w, pattern, f, verdict, source):
    from . import walks
    p = w["pace"]
    p["judging"] = False
    if w["status"] != "active":
        return
    now = w["clock"].now()
    check = bool(verdict.get("check_in", True)) if source == "gemini" else True
    note = str(verdict.get("friend_note") or "").strip()[:140] or \
        f"{PATTERN_TEXT[pattern].capitalize()} ({f['cur']} m/s, usually {f['baseline']} m/s)."
    p["note"], p["source"] = note, source
    if check:
        line = str(verdict.get("buddy_line") or "").strip()[:80] or None
        ev = _checkin(w, now, line if source == "gemini" else None)
        if not ev:  # already mid check-in: nothing new to start
            ev = []
        walks.handle(w, [{"type": "pace_judged", "pattern": pattern, "check_in": True, "source": source,
                          "why": str(verdict.get("why") or "")[:100], "at": now}] + ev)
    else:
        p["pattern"] = "steady"
        p["cooldown_until"] = now + COOLDOWN_S / 2
        walks.handle(w, [{"type": "pace_judged", "pattern": pattern, "check_in": False, "source": source,
                          "why": str(verdict.get("why") or "Looks like a normal pause")[:100], "at": now}])


def view(w):
    p = w.get("pace")
    if not p:
        return None
    return {"mps": p.get("mps"), "kmh": None if p.get("mps") is None else round(p["mps"] * 3.6, 1),
            "mode": mode_of(p.get("mps")), "baseline": p.get("baseline"), "pattern": p.get("pattern", "steady"),
            "note": p.get("note"), "source": p.get("source"), "judging": p.get("judging", False),
            "samples": [s[1] for s in p["samples"][-24:]]}
