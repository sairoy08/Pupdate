"""Users, walks, alerts. In-memory store guarded by one lock; reseeded by /demo/reset.

Alert rules:
- Alerts open when the engine raises them and stay open until a FRIEND closes them.
- A late pet after an alert calms the engine but does not close the alert; the
  friend sees "petted after the alert" instead.
- Duress alerts are silent: the walker's own view never shows them.
"""
import copy
import threading
import time
from datetime import datetime, timezone

from . import buddy as buddy_mod
from .engine import ESCALATING, Engine
from .routes import load_routes

LOCK = threading.RLock()

SEED_USERS = {
    "jordan": {"id": "jordan", "name": "Jordan", "phone": "+15555550100", "friends": ["maya", "sam"], "streak": 6,
               "buddy": {"name": "Melvin", "xp": 90, "form": "sprout", "species": "dog"}},
    "maya": {"id": "maya", "name": "Maya", "phone": "+15555550101", "friends": ["jordan"], "streak": 2,
             "buddy": {"name": "Pip", "xp": 40, "form": "sprout", "species": "cat"}},
    "sam": {"id": "sam", "name": "Sam", "phone": "+15555550102", "friends": ["jordan"], "streak": 11,
            "buddy": {"name": "Moss", "xp": 130, "form": "strider", "species": "dog"}},
}

STATE = {"users": {}, "walks": {}, "alerts": {}, "seq": 0}


def new_id(prefix):
    """IDs come from the persisted state, so they stay unique across server instances."""
    STATE["seq"] = STATE.get("seq", 0) + 1
    return "%s%d" % (prefix, STATE["seq"])


def iso(ts=None):
    return datetime.fromtimestamp(ts if ts is not None else time.time(), timezone.utc).isoformat()


class Clock:
    """Engine time. Real walks: wall clock. Demo walks: a sim clock with a speed factor."""

    def __init__(self, demo, speed=1.0):
        self.demo = demo
        self.base_real = time.time()
        self.base_sim = 0.0 if demo else self.base_real
        self.speed = speed if demo else 1.0

    def now(self):
        return self.base_sim + (time.time() - self.base_real) * self.speed

    def set_speed(self, speed):
        if not self.demo or speed == self.speed:
            return
        self.base_sim = self.now()
        self.base_real = time.time()
        self.speed = speed


def reset():
    """Reseed XP, streaks, walks and alerts. Keeps each buddy's chosen name and species,
    and keeps Jordan's circle (friends added or removed in Settings)."""
    with LOCK:
        old = STATE.get("users", {})
        keep = {uid: {k: u["buddy"][k] for k in ("name", "species") if k in u["buddy"]}
                for uid, u in old.items()}
        circle = {uid for uid, u in old.items() if "jordan" in u.get("friends", [])} if old else None
        added = {uid: u for uid, u in old.items() if u.get("added")}
        STATE["users"] = copy.deepcopy(SEED_USERS)
        for uid, u in added.items():
            STATE["users"][uid] = copy.deepcopy(u)
        for uid, extra in keep.items():
            if uid in STATE["users"]:
                STATE["users"][uid]["buddy"].update(extra)
        if circle is not None:
            for uid, u in STATE["users"].items():
                if uid == "jordan":
                    continue
                if uid in circle and "jordan" not in u["friends"]:
                    u["friends"].append("jordan")
                if uid not in circle and "jordan" in u["friends"]:
                    u["friends"].remove("jordan")
        # two past walks, so the trip history is the same for every judge
        day = 86400
        STATE["users"]["jordan"]["trips"] = [
            {"id": "seed2", "started_at": iso(time.time() - day), "ended_at": iso(time.time() - day + 840), "demo": False,
             "from": "Hayden Library", "to": "Tooker House", "minutes": 14, "distance_m": 1100, "checkins": 2, "alerts": 0,
             "ended_early": None},
            {"id": "seed1", "started_at": iso(time.time() - 3 * day), "ended_at": iso(time.time() - 3 * day + 540), "demo": False,
             "from": "Memorial Union", "to": "Tooker House", "minutes": 9, "distance_m": 700, "checkins": 1, "alerts": 0,
             "ended_early": "got a ride"},
        ]
        STATE["walks"] = {}
        STATE["alerts"] = {}
        STATE["updates"] = []
        STATE.setdefault("seq", 0)
        STATE.setdefault("flags", {})
        from . import flags as flags_mod
        flags_mod.seed()  # demo flags come back fresh; flags people added stay


reset()


def user(uid):
    u = STATE["users"].get(uid)
    if not u:
        raise KeyError(uid)
    return u


# The pup is the main pet; the chick was removed.
SPECIES = {"dog", "cat", "bunny", "poodle", "hedgehog", "chipmunk", "otter", "seal", "sloth", "turtle", "penguin"}


def customize_buddy(uid, name=None, species=None):
    with LOCK:
        u = user(uid)
        b = dict(u["buddy"])
        if name is not None:
            name = name.strip()[:16]
            if not name:
                raise ValueError("name can't be empty")
            b["name"] = name
        if species is not None:
            if species not in SPECIES:
                raise ValueError("unknown species")
            b["species"] = species
        u["buddy"] = b
        return b


def circle(walker_id):
    """People who get this walker's alerts."""
    with LOCK:
        user(walker_id)
        return [{"id": u["id"], "name": u["name"], "phone": u["phone"]}
                for u in STATE["users"].values() if walker_id in u.get("friends", []) and u["id"] != walker_id]


def add_friend(walker_id, name, phone=""):
    import re as _re
    with LOCK:
        user(walker_id)
        name = (name or "").strip()[:24]
        if not name:
            raise ValueError("name can't be empty")
        phone = _re.sub(r"[^0-9+]", "", phone or "")[:16]
        base = _re.sub(r"[^a-z0-9]", "", name.lower()) or "friend"
        uid, n = base, 2
        while uid in STATE["users"] and walker_id in STATE["users"][uid].get("friends", []):
            uid, n = f"{base}{n}", n + 1
        if uid in STATE["users"]:  # an existing person (like Maya) rejoining the circle
            u = STATE["users"][uid]
            u["friends"].append(walker_id)
            if phone:
                u["phone"] = phone
        else:
            STATE["users"][uid] = {"id": uid, "name": name, "phone": phone, "friends": [walker_id], "streak": 0,
                                   "added": True, "buddy": {"name": "Pal", "xp": 0, "form": "sprout", "species": "cat"}}
        return {"id": uid, "name": STATE["users"][uid]["name"], "phone": STATE["users"][uid]["phone"]}


def remove_friend(walker_id, friend_id):
    with LOCK:
        u = user(friend_id)
        if walker_id not in u.get("friends", []):
            raise KeyError(friend_id)
        u["friends"].remove(walker_id)
        return {"ok": True}


def friends_watching(walker_id):
    """Users who list the walker as a friend (they get the walker's alerts)."""
    return [u["id"] for u in STATE["users"].values() if walker_id in u["friends"]]


LONG_GAP_S = 900.0  # check-ins further apart than 15 minutes get a warning
SLOW_ALERT_S = 300.0  # friends hearing about it more than 5 minutes after a missed check-in


def timing_warnings(every, stages_total, checkins_off, first="You"):
    """Plain warnings about risky settings. Shown to the walker and sent to friends as notices."""
    out = []
    if checkins_off:
        out.append(("checkins_off", f"{first} turned check-ins off for this walk. Only the silent alert, "
                                    "lost contact and car-speed alerts still work."))
    elif every and every > LONG_GAP_S:
        out.append(("long_checkins", f"{first} set check-ins to every {round(every / 60)} min. "
                                     "If something happens, it could take that long to notice."))
    if stages_total > SLOW_ALERT_S:
        m, s_ = divmod(int(stages_total), 60)
        out.append(("slow_alerts", f"{first}'s buddy waits {m} min {s_:02d} s after a missed check-in before alerting friends."))
    return out


def add_notice(w, kind, text):
    notices = w.setdefault("notices", [])
    if any(n["kind"] == kind for n in notices):
        return None
    n = {"kind": kind, "text": text, "at": iso()}
    notices.append(n)
    _log(w, {"type": "notice", "kind": kind, "text": text})
    return n


def start_walk(walker_id, route_id=None, dest=None, demo=False, every=600.0, watch_route=True, watch_speed=True,
               stages=None, checkins_off=False):
    with LOCK:
        user(walker_id)
        for w in STATE["walks"].values():
            if w["walker_id"] == walker_id and w["status"] == "active":
                w["status"] = "ended"
                w["ended_at"] = iso()
                _record_trip(w)
        routes = load_routes()
        route = routes.get(route_id) if route_id else None
        clock = Clock(demo, speed=2.0)
        wid = new_id("w")
        w = {
            "id": wid, "walker_id": walker_id, "demo": demo, "status": "active",
            "route_id": route["id"] if route else None, "dest": dest or (route["points"][-1] if route else None),
            "started_at": iso(), "clock": clock,
            "engine": Engine(clock.now(), demo=demo, every=every, stages=stages, checkins_off=checkins_off),
            "watch_route": watch_route and not checkins_off, "watch_speed": watch_speed and not checkins_off,
            "checkins_off": bool(checkins_off), "notices": [],
            "events": [], "trail": [], "sim": {"dist_m": 0.0, "dir": 1, "deviate_until": None,
                                                "speed_override": None, "last_now": clock.now()},
        }
        STATE["walks"][wid] = w
        first = user(walker_id)["name"].split(" ")[0]
        for kind, text in timing_warnings(every, w["engine"].escalation_total(), checkins_off, first):
            add_notice(w, kind, text)
        return w


def active_walk(walker_id):
    for w in STATE["walks"].values():
        if w["walker_id"] == walker_id and w["status"] == "active":
            return w
    return None


def _log(w, ev):
    ev = dict(ev, real_at=iso())
    w["events"].append(ev)
    del w["events"][:-60]
    return ev


def place_of(w):
    """Plain-language position on the route, e.g. 'about halfway from Hayden Library to Tooker House'."""
    route = load_routes().get(w["route_id"]) if w["route_id"] else None
    pos = w["engine"].last_pos
    if not route or not pos:
        return "on their walk"
    from .geo import dist_m
    pts = route["points"]
    total = sum(dist_m(pts[i], pts[i + 1]) for i in range(len(pts) - 1)) or 1
    best_i = min(range(len(pts)), key=lambda i: dist_m(pts[i], pos))
    done = sum(dist_m(pts[i], pts[i + 1]) for i in range(best_i))
    f = done / total
    where = "just after leaving" if f < 0.15 else "almost at" if f > 0.85 else \
        "about halfway between" if 0.35 < f < 0.65 else "partway between"
    if where in ("just after leaving",):
        return f"{where} {route['from']}"
    if where == "almost at":
        return f"{where} {route['to']}"
    return f"{where} {route['from']} and {route['to']}"


def minutes_in(w):
    try:
        start = datetime.fromisoformat(w["started_at"]).timestamp()
        return max(0, round((time.time() - start) / 60))
    except Exception:
        return 0


def handle(w, events):
    """Apply engine events to the store (XP, alerts). Caller holds LOCK."""
    out = []
    for ev in events:
        t = ev["type"]
        if t == "pet_ok":
            if ev.get("xp"):
                u = user(w["walker_id"])
                u["buddy"], evolved = buddy_mod.add_xp(u["buddy"], ev["xp"])
                if evolved:
                    ev = dict(ev, evolved=evolved)
            w.pop("buddy_line", None)
            if ev.get("after_alert"):
                for a in open_alerts(w["id"]):
                    a["petted_after"] = iso()
        elif t == "alert_raised":
            open_alert(w, ev["kind"])
        elif t == "checkin_started":
            from . import buddy_ai
            u = user(w["walker_id"])
            b = u["buddy"]
            if ev.get("line"):  # written by Gemini already (pace judge)
                w["buddy_line"], w["buddy_line_source"] = ev["line"], "gemini"
            else:
                w["buddy_line"] = buddy_ai.fallback_line(ev.get("reason"), u["name"])
                w["buddy_line_source"] = "fallback"
                buddy_ai.fill_async(w, "buddy_line", buddy_ai.checkin_prompt(
                    b["name"], b.get("species", "dog"), u["name"], ev.get("reason"), place_of(w)), 80)
        elif t == "contact_restored":
            for a in open_alerts(w["id"]):
                if a["kind"] == "lost_contact":
                    a["contact_restored"] = iso()
        out.append(_log(w, ev))
    return out


END_REASONS = {"ride": "got a ride", "plans": "changed plans", "friends": "is with friends now",
               "safe": "is somewhere safe", "help": "asked for help"}


def meters_left(w):
    route = load_routes().get(w["route_id"]) if w["route_id"] else None
    pos = w["engine"].last_pos
    if route and pos:
        from .geo import along_of
        return max(0, round(route["length_m"] - along_of(pos, route["points"])))
    if w.get("dest") and pos:
        from .geo import dist_m
        return round(dist_m(pos, w["dest"]))
    return None


KEEP_TRIPS = 30


def _record_trip(w):
    """Add one line to the walker's trip history, newest first. Silent (duress) alerts are left out:
    nothing the walker can open may show them."""
    u = STATE["users"].get(w["walker_id"])
    if not u:
        return
    route = load_routes().get(w["route_id"]) if w["route_id"] else None
    early = w.get("ended_early")
    left = (early or {}).get("meters_left") or 0
    u.setdefault("trips", []).insert(0, {
        "id": w["id"], "started_at": w["started_at"], "ended_at": w["ended_at"], "demo": w["demo"],
        "from": (route or {}).get("from"), "to": (route or {}).get("to"),
        "minutes": max(1, minutes_in(w)),
        "distance_m": round(max(0, route["length_m"] - left)) if route else None,
        "checkins": sum(1 for e in w["events"] if e["type"] == "pet_ok" and not e.get("unprompted")),
        "alerts": sum(1 for a in STATE["alerts"].values() if a["walk_id"] == w["id"] and a["kind"] != "duress"),
        "ended_early": END_REASONS[early["reason"]] if early else None,
    })
    del u["trips"][KEEP_TRIPS:]


def trips(uid):
    return user(uid).get("trips", [])


def finish_walk(w, early=False, reason=None):
    """End a walk. A finished walk with no alerts extends the safe-walk streak.
    Ending early tells the circle why and where, and leaves the streak as it was.
    Reason "help" also alerts the circle right away."""
    if w["status"] != "active":
        return None
    if early and reason not in END_REASONS:
        raise ValueError("reason must be one of " + ", ".join(END_REASONS))
    u = user(w["walker_id"])
    update = None
    if early:
        left = meters_left(w)
        route = load_routes().get(w["route_id"]) if w["route_id"] else None
        first = u["name"].split(" ")[0]
        where = f", {left} m from {route['to'] if route else 'home'}" if left is not None else ""
        text = f"{first} ended the walk early: {END_REASONS[reason]}{where}."
        w["ended_early"] = {"reason": reason, "meters_left": left, "at": iso()}
        _log(w, {"type": "ended_early", "reason": reason, "text": text})
        update = {"walker_id": u["id"], "walker_name": u["name"], "walk_id": w["id"], "reason": reason,
                  "text": text, "at": iso(), "ts": time.time(), "notify": friends_watching(u["id"])}
        STATE.setdefault("updates", []).append(update)
        del STATE["updates"][:-30]
        if reason == "help":
            open_alert(w, "help")
    w["status"] = "ended"
    w["ended_at"] = iso()
    _record_trip(w)
    if not early:
        had_alert = any(a["walk_id"] == w["id"] for a in STATE["alerts"].values())
        u["streak"] = 0 if had_alert else u.get("streak", 0) + 1
    return update


def open_alerts(walk_id=None):
    return [a for a in STATE["alerts"].values()
            if a["status"] == "open" and (walk_id is None or a["walk_id"] == walk_id)]


def open_alert(w, kind):
    for a in open_alerts(w["id"]):
        if a["kind"] == kind:
            return a
    aid = new_id("a")
    walker = user(w["walker_id"])
    a = {
        "id": aid, "walk_id": w["id"], "walker_id": walker["id"], "walker_name": walker["name"],
        "walker_phone": walker["phone"], "kind": kind, "status": "open", "opened_at": iso(),
        "pos": w["engine"].last_pos, "route_id": w["route_id"], "closed_by": None,
        "petted_after": None, "contact_restored": None, "notify": friends_watching(walker["id"]),
    }
    from . import buddy_ai
    place = place_of(w)
    mins = minutes_in(w)
    last = next((e.get("real_at") for e in reversed(w["events"]) if e["type"] == "pet_ok"), None)
    last_txt = "none yet" if not last else last[11:16] + " UTC"
    first = walker["name"].split(" ")[0]
    context = alert_context(w)
    a["context"] = context
    a["summary"] = {
        "no_answer": f"{first} stopped answering {place}, {mins} min into the walk. Call them first.",
        "duress": f"{first} sent a silent alert {place}. Don't call. Text, or go there with someone.",
        "lost_contact": f"{first}'s phone went quiet {place}, {mins} min into the walk. Try calling.",
        "help": f"{first} ended their walk early and asked for help {place}, {mins} min in. Call them now.",
    }.get(kind, f"Alert for {first} {place}.")
    if context and kind != "duress":
        a["summary"] += " " + context
    a["summary_source"] = "fallback"
    STATE["alerts"][aid] = a
    buddy_ai.fill_async(a, "summary", buddy_ai.alert_prompt(first, kind, place, mins, last_txt, walker["buddy"]["name"], context), 240)
    return a


def alert_context(w):
    """What led up to the alert, for the friend: an irregular pace, a flagged area."""
    bits = []
    e = w["engine"]
    p = w.get("pace") or {}
    if (e.reason == "irregular_pace" or p.get("pattern") not in (None, "steady")) and p.get("note"):
        bits.append("Pace: " + p["note"].rstrip(".") + ".")
    if e.reason == "flagged_area" and w.get("flags_entered"):
        from . import flags as flags_mod
        f = flags_mod._state().get(w["flags_entered"][-1])
        if f:
            bits.append(f"They were inside an area {f['by_name']} flagged: {f['reason'].lower()}.")
    if e.reason == "off_route":
        bits.append("They had left their planned route.")
    return " ".join(bits)


def on_position(w, now, pos, pace_trigger=True):
    """Everything that watches the walker's position: pace and flagged areas. Caller holds LOCK."""
    from . import flags as flags_mod
    from . import pace
    ev = pace.sample(w, now, pos, allow_trigger=pace_trigger)
    entered = w.setdefault("flags_entered", [])
    seen = w.setdefault("flags_seen", [])
    for f in flags_mod.visible(w["walker_id"]):
        if f["status"] == "avoid" and flags_mod.inside(pos, f) and f["id"] not in entered:
            entered.append(f["id"])
            ev.append({"type": "flag_entered", "flag": flags_mod.brief(f), "at": now})
            ev += w["engine"].request_checkin(now, "flagged_area")
        elif f["status"] in ("avoid", "caution") and flags_mod.inside(pos, f, flags_mod.NEAR_EXTRA_M) and f["id"] not in seen:
            seen.append(f["id"])
            ev.append({"type": "flag_nearby", "flag": flags_mod.brief(f), "at": now})
    return ev


def flag_ahead(w):
    from . import flags as flags_mod
    pos = w["engine"].last_pos
    if not pos:
        return None
    from .geo import dist_m
    near = [(dist_m(pos, [f["lat"], f["lng"]]) - f["radius_m"], f) for f in flags_mod.visible(w["walker_id"])
            if f["status"] != "ok" and flags_mod.inside(pos, f, flags_mod.NEAR_EXTRA_M)]
    if not near:
        return None
    d, f = min(near, key=lambda x: x[0])
    return dict(flags_mod.brief(f), in_m=max(0, round(d)), inside=d <= 0)


def close_alert(alert_id, friend_id):
    with LOCK:
        a = STATE["alerts"].get(alert_id)
        if not a:
            raise KeyError(alert_id)
        if friend_id == a["walker_id"] or friend_id not in a["notify"]:
            raise PermissionError("only a friend of %s can close this alert" % a["walker_name"])
        a["status"] = "closed"
        a["closed_by"] = friend_id
        a["closed_at"] = iso()
        return a


def apply(w, fn, *args):
    """Run an engine input at the walk's current engine time and handle its events."""
    with LOCK:
        now = w["clock"].now()
        events = fn(now, *args)
        return handle(w, events)


def walk_view(w, viewer="walker"):
    """Public JSON for a walk. The walker never sees duress state."""
    e = w["engine"]
    now = w["clock"].now()
    snap = e.snapshot(now)
    alerts = open_alerts(w["id"])
    if viewer == "walker":
        alerts = [a for a in alerts if a["kind"] != "duress"]
        if snap["alert_kind"] == "duress":
            snap["alert_kind"] = None
    u = user(w["walker_id"])
    from . import nav, pace
    route = load_routes().get(w["route_id"]) if w["route_id"] else None
    return {
        "id": w["id"], "walker_id": w["walker_id"], "walker_name": u["name"], "demo": w["demo"], "streak": u.get("streak", 0),
        "status": w["status"], "route_id": w["route_id"], "dest": w["dest"], "started_at": w["started_at"],
        "engine": snap, "escalating": snap["state"] in ESCALATING, "speed": w["clock"].speed,
        "pos": e.last_pos, "trail": w["trail"][-200:], "buddy": u["buddy"],
        "next_form_at": buddy_mod.next_form_at(u["buddy"]["xp"]),
        "alerts": alerts, "events": w["events"][-12:],
        "off_route": w["sim"].get("off_route", False),
        "buddy_line": w.get("buddy_line") if snap["state"] != "calm" else None,
        "buddy_line_source": w.get("buddy_line_source"),
        "checkin_every_s": w["engine"].every, "watch_route": w.get("watch_route", True), "watch_speed": w.get("watch_speed", True),
        "next_turn": nav.next_turn(w, route) if w["status"] == "active" else None,
        "pace": pace.view(w), "flag_ahead": flag_ahead(w),
        "notices": w.get("notices", []), "checkins_off": w.get("checkins_off", False),
        "ended_early": w.get("ended_early"),
        "escalation_s": w["engine"].escalation_total(),
        "stages": {n: v for n, v in w["engine"]._stages()},
        "sim": demo_view(w),
    }


def demo_view(w):
    from . import demo
    return demo.view(w)


def feed(friend_id):
    """What a friend's phone polls: walks of people they watch, and open alerts for them."""
    with LOCK:
        user(friend_id)
        watched = [uid for uid, u in STATE["users"].items() if friend_id in friends_watching(uid)]
        walks = [walk_view(w, viewer="friend") for w in STATE["walks"].values()
                 if w["status"] == "active" and w["walker_id"] in watched]
        alerts = [a for a in STATE["alerts"].values() if friend_id in a["notify"]]
        alerts.sort(key=lambda a: a["opened_at"], reverse=True)
        cutoff = time.time() - 3 * 3600
        updates = [{k: v for k, v in x.items() if k != "notify"} for x in reversed(STATE.get("updates", []))
                   if friend_id in x["notify"] and x["ts"] > cutoff][:10]
        return {"walks": walks, "open_alerts": [a for a in alerts if a["status"] == "open"],
                "recent_alerts": alerts[:10], "updates": updates}


# ---------------------------------------------------------------------------
# Persistence (see store.py): plain-JSON snapshot of the whole state, and back.
# ---------------------------------------------------------------------------

KEEP_ENDED_WALKS = 5


def dump():
    from . import routes
    walks_out = {}
    ended = sorted((w for w in STATE["walks"].values() if w["status"] != "active"),
                   key=lambda w: w.get("ended_at") or "", reverse=True)[:KEEP_ENDED_WALKS]
    keep = {w["id"] for w in ended} | {w["id"] for w in STATE["walks"].values() if w["status"] == "active"}
    for wid, w in STATE["walks"].items():
        if wid not in keep:
            continue
        d = dict(w)
        d["engine"] = dict(w["engine"].__dict__)
        d["clock"] = dict(w["clock"].__dict__)
        if "speedstate" in d:
            ss = dict(d["speedstate"])
            ss["flagged"] = sorted(ss.get("flagged", []))
            ss["fixes"] = [[t, p] for t, p in ss.get("fixes", [])]
            d["speedstate"] = ss
        walks_out[wid] = d
    live_alert_walks = set(walks_out)
    alerts = {k: a for k, a in STATE["alerts"].items() if a["status"] == "open" or a["walk_id"] in live_alert_walks}
    return {"users": STATE["users"], "walks": walks_out, "alerts": alerts, "seq": STATE.get("seq", 0),
            "custom_routes": routes.CUSTOM, "flags": STATE.get("flags", {}), "updates": STATE.get("updates", [])}


def restore(data):
    from . import routes
    walks_in = {}
    for wid, d in data.get("walks", {}).items():
        w = dict(d)
        e = Engine.__new__(Engine)
        e.__dict__.update(d["engine"])
        c = Clock.__new__(Clock)
        c.__dict__.update(d["clock"])
        w["engine"], w["clock"] = e, c
        if "speedstate" in w:
            ss = dict(w["speedstate"])
            ss["flagged"] = set(ss.get("flagged", []))
            ss["fixes"] = [(t, p) for t, p in ss.get("fixes", [])]
            w["speedstate"] = ss
        walks_in[wid] = w
    STATE.clear()
    STATE.update({"users": data["users"], "walks": walks_in, "alerts": data.get("alerts", {}), "seq": data.get("seq", 0),
                  "flags": data.get("flags", {}), "updates": data.get("updates", [])})
    if not STATE["flags"]:
        from . import flags as flags_mod
        flags_mod.seed()
    routes.CUSTOM.clear()
    routes.CUSTOM.update(data.get("custom_routes", {}))
    # Buddies saved as a chick before it was removed become pups.
    for u in STATE["users"].values():
        if isinstance(u.get("buddy"), dict) and u["buddy"].get("species", "chick") == "chick":
            u["buddy"]["species"] = "dog"
