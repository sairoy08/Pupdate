"""Demo simulator: plays a walker along a route on the sim clock.

- Walk at 2x, escalation at 4x (about 27 s real for the full 110 s escalation).
- The sim NEVER pets. Every pet comes from the phone.
- Arrival is blocked: the sim walks back and forth along the route.
- "Deviate" walks the sim off the route so the off-route check-in can be shown.
"""
import logging
import math
import threading
import time

from . import walks
from .engine import ESCALATING
from .geo import offset, point_along
from .routes import OFF_ROUTE_M, load_routes, off_route_m

log = logging.getLogger("pupdate.demo")
WALK_SPEED = 1.4  # m/s, a brisk walk
# Escalation used to jump to 4x, which left a 20 s countdown about 5 real seconds: too short to
# rub the buddy in time. It now stays at walking speed (the speed control still overrides it).
WALK_X, ESCALATE_X = 2.0, 2.0
TICK_REAL_S = 0.25
DEVIATE_SIM_S = 70.0  # how long the sim stays off route
OFF_ROUTE_CHECKIN_S = 20.0  # off route this long (sim s) -> check-in

_thread = None
_stop = threading.Event()


def step(w):
    """Advance one demo walk to the current sim time. Caller holds walks.LOCK."""
    sim = w["sim"]
    clock = w["clock"]
    e = w["engine"]
    # 4x only once the walker is really not answering: after "Stop answering", or
    # past the first check-in stage. A normal check-in stays at 2x (15 s real to pet).
    escalating = e.ignore_pets or e.state in ESCALATING - {"checkin"}
    want = sim["speed_override"] or (ESCALATE_X if escalating else WALK_X)
    clock.set_speed(want)
    now = clock.now()
    # Replay any gap (cloud catch-up after nobody polled) in small sim steps, so the
    # simulated phone keeps "ticking" and no false lost-contact alert fires.
    route = load_routes().get(w["route_id"]) if w["route_id"] else None
    out = []
    t = sim["last_now"]
    while t < now - 1e-9 and w["status"] == "active":
        t = min(now, t + CATCH_UP_STEP_S)
        out += _step_to(w, t, route)
    if not out and t >= now and w["status"] == "active":
        out += _step_to(w, now, route)
    return out


CATCH_UP_STEP_S = 5.0


def _step_to(w, now, route):
    sim = w["sim"]
    e = w["engine"]
    dt = max(0.0, now - sim["last_now"])
    sim["last_now"] = now
    if route is None:
        return walks.handle(w, e.tick(now, e.last_pos))
    # Move along the route, bouncing at the ends (arrival is blocked in demo mode).
    L = route["length_m"]
    mode = sim.get("pace_mode")
    if mode and sim.get("pace_until") is not None and now >= sim["pace_until"]:
        if sim.get("pace_dir") is not None:
            sim["dir"] = sim.pop("pace_dir")
        sim["pace_mode"] = mode = None
        sim["pace_until"] = None
    speed = 0.0 if sim.get("paused") else WALK_SPEED
    if sim.get("paused"):
        pass  # held in place by the demo controls; the phone keeps "ticking", so no lost-contact alert
    elif mode == "run":
        speed = RUN_SPEED
    elif mode == "car":
        speed = CAR_SPEED
    elif mode == "stop_go":
        speed = 0.0 if int(now / STOP_GO_PERIOD_S) % 2 == 0 else 1.8
    elif mode == "stop":
        speed = 0.0
    elif mode == "backtrack":
        sim["dir"] = -1
    sim["dist_m"] += sim["dir"] * speed * dt
    if sim.get("arriving") and sim["dist_m"] >= L:
        # "Arrive" from the demo controls: reach the destination and finish the walk like a real one.
        sim["dist_m"] = L
        events = e.tick(now, point_along(route["points"], L))
        out = walks.handle(w, events)
        walks.finish_walk(w)
        return out
    if sim["dist_m"] >= L:
        sim["dist_m"], sim["dir"] = L - (sim["dist_m"] - L), -1
    elif sim["dist_m"] <= 0:
        sim["dist_m"], sim["dir"] = -sim["dist_m"], 1
    pos = point_along(route["points"], sim["dist_m"])
    if sim["deviate_until"] is not None:
        if now < sim["deviate_until"]:
            # Drift sideways off the route, up to about 140 m.
            progress = 1 - (sim["deviate_until"] - now) / DEVIATE_SIM_S
            ahead = point_along(route["points"], min(L, sim["dist_m"] + 5))
            behind = point_along(route["points"], max(0.0, sim["dist_m"] - 5))
            dn = (ahead[0] - behind[0]) * 111320.0  # meters north along the route
            de = (ahead[1] - behind[1]) * 111320.0 * 0.834  # meters east (cos 33.4 deg)
            n = math.hypot(dn, de) or 1.0
            side = 140 * min(1.0, progress * 2)
            pos = offset(pos, -de / n * side, dn / n * side)  # perpendicular to the route
        else:
            sim["deviate_until"] = None
    events = e.tick(now, pos)
    # Pace and flags. In the demo the sim bounces at the route ends, which would look like turning
    # back, so pace check-ins only come from the injected patterns ("Irregular pace" controls).
    events += walks.on_position(w, now, pos, pace_trigger=bool(mode) or sim.get("pace_grace", 0) > now)
    off = w.get("watch_route", True) and off_route_m(pos, route) > OFF_ROUTE_M
    if off:
        sim.setdefault("off_since", now)
        if now - sim["off_since"] >= OFF_ROUTE_CHECKIN_S and not sim.get("off_checked"):
            sim["off_checked"] = True
            events += e.request_checkin(now, "off_route")
    else:
        sim.pop("off_since", None)
        sim["off_checked"] = False
    sim["off_route"] = off
    w["trail"].append([round(pos[0], 6), round(pos[1], 6)])
    del w["trail"][:-400]
    return walks.handle(w, events)


def catch_up():
    """Advance every active walk to now. Called by the local loop, and per request in the cloud."""
    with walks.LOCK:
        for w in list(walks.STATE["walks"].values()):
            if w["demo"] and w["status"] == "active":
                step(w)
            elif w["status"] == "active":
                # Real walks: run timeouts so alerts fire even if the phone goes quiet.
                walks.handle(w, w["engine"].advance(w["clock"].now()))


def loop():
    from . import store
    last_save = 0.0
    while not _stop.is_set():
        try:
            catch_up()
            if store.mongo_enabled() and time.time() - last_save > 5:
                with walks.LOCK:
                    snap = walks.dump()
                store.mongo_save(snap)
                last_save = time.time()
        except Exception:
            log.exception("demo loop error")
        time.sleep(TICK_REAL_S)


def start_loop():
    global _thread
    if _thread and _thread.is_alive():
        return
    _stop.clear()
    _thread = threading.Thread(target=loop, daemon=True, name="pupdate-sim")
    _thread.start()


def stop_loop():
    _stop.set()


FIRST_CHECKIN_SIM_S = 30.0  # demo walks ask "Still good?" once, 15 s real after start


def start(route_id="library-to-tooker", walker_id="jordan", watch_route=True, watch_speed=True, stages=None,
          checkins_off=False):
    w = walks.start_walk(walker_id, route_id=route_id, demo=True, watch_route=watch_route, watch_speed=watch_speed,
                         stages=stages, checkins_off=checkins_off)
    with walks.LOCK:
        if not checkins_off:
            w["engine"].next_checkin = w["clock"].now() + FIRST_CHECKIN_SIM_S
        step(w)
    return w


def checkin_now(w):
    return walks.apply(w, lambda now: w["engine"].request_checkin(now, "demo"))


def stop_answering(w):
    """Start a check-in right now and drop phone pets until the alert fires."""
    return walks.apply(w, lambda now: w["engine"].request_checkin(now, "stop_answering", ignore_pets=True))


def deviate(w):
    with walks.LOCK:
        w["sim"]["deviate_until"] = w["clock"].now() + DEVIATE_SIM_S
        return True


RUN_SPEED = 3.6  # m/s, a run
STOP_GO_PERIOD_S = 6.0
CAR_SPEED = 13.0  # m/s, about 47 km/h
PACE_MODES = {"car": 45.0, "run": 50.0, "stop_go": 70.0, "backtrack": 60.0, "stop": 100.0}


def pace(w, mode):
    """Make the sim walker move irregularly so the pace watch (and Gemini) can be shown."""
    if mode not in PACE_MODES:
        raise ValueError("mode must be one of " + ", ".join(PACE_MODES))
    with walks.LOCK:
        now = w["clock"].now()
        sim = w["sim"]
        if sim.get("pace_dir") is not None:
            sim["dir"] = sim.pop("pace_dir")
        if mode == "backtrack":
            sim["pace_dir"] = sim["dir"]
        sim["pace_mode"] = mode
        sim["pace_until"] = now + PACE_MODES[mode]
        sim["pace_grace"] = now + PACE_MODES[mode] + 20
        p = w.get("pace")
        if p:  # a fresh episode: forget the last cooldown so the demo always reacts
            p["cooldown_until"] = None
            p["episode"] = None
        return True


def set_speed(w, x):
    with walks.LOCK:
        w["sim"]["speed_override"] = x
        w["clock"].set_speed(x or WALK_X)


CONTROLS = ("pause", "resume", "forward", "backward", "jump", "arrive")


def control(w, action, value=None):
    """Drive the sim walker from a phone: pause, direction, jump along the route (0..1), arrive."""
    if action not in CONTROLS:
        raise ValueError("action must be one of " + ", ".join(CONTROLS))
    with walks.LOCK:
        sim = w["sim"]
        route = load_routes().get(w["route_id"]) if w["route_id"] else None
        if action == "pause":
            sim["paused"] = True
        elif action == "resume":
            sim["paused"] = False
        elif action in ("forward", "backward"):
            sim.pop("pace_dir", None)
            sim["dir"] = 1 if action == "forward" else -1
            sim["arriving"] = False if action == "backward" else sim.get("arriving", False)
        elif action == "jump":
            if route is None or value is None:
                raise ValueError("jump needs a demo route and a value from 0 to 1")
            sim["dist_m"] = max(0.0, min(1.0, float(value))) * route["length_m"]
            sim["deviate_until"] = None
            sim["arriving"] = False
        elif action == "arrive":
            sim.update(arriving=True, paused=False, dir=1, deviate_until=None)
            sim.pop("pace_dir", None)
        return view(w)


def view(w):
    """Sim walker state for the demo controls (demo walks only)."""
    if not w.get("demo"):
        return None
    sim = w["sim"]
    route = load_routes().get(w["route_id"]) if w["route_id"] else None
    L = route["length_m"] if route else 0
    return {"paused": bool(sim.get("paused")), "dir": sim.get("dir", 1), "arriving": bool(sim.get("arriving")),
            "progress": round(sim["dist_m"] / L, 3) if L else 0.0, "length_m": L,
            "speed_override": sim.get("speed_override")}
