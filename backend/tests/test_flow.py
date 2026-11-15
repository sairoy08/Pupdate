"""Scripted demo flow through the API, twice, with a reset in between."""
import pytest
from fastapi.testclient import TestClient

from app import demo, walks
from app.main import app

c = TestClient(app)  # no context manager: the background sim loop does not run; tests step it


def jump(seconds):
    """Advance the demo walk's sim clock and run one sim step."""
    w = walks.active_walk("jordan")
    with walks.LOCK:
        w["clock"].base_sim += seconds
        demo.step(w)
    return w


def jordan():
    return c.get("/users/jordan").json()


def run_demo_once():
    assert c.post("/demo/reset").status_code == 200
    assert jordan()["buddy"]["xp"] == 90
    w = c.post("/demo/start", json={"route_id": "library-to-tooker"}).json()
    wid = w["id"]
    assert w["demo"] and w["engine"]["state"] == "calm" and w["pos"]
    # Walker phone discovers the walk started from the friend phone.
    assert c.get("/users/jordan/active").json()["id"] == wid

    # The first scripted check-in arrives 30 sim s in; the sim never pets it.
    jump(31)
    v = c.get(f"/walks/{wid}").json()
    assert v["engine"]["state"] == "checkin" and v["engine"]["reason"] == "scheduled"

    # Answered from the phone: +10 XP, Melvin evolves.
    r = c.post(f"/walks/{wid}/pet").json()
    pet = [e for e in r["events"] if e["type"] == "pet_ok"][0]
    assert pet["xp"] == 10 and pet["evolved"] == "strider"
    assert jordan()["buddy"]["form"] == "strider"

    # Stop answering: immediate check-in, phone pets ignored, escalation at 4x.
    v = c.post("/demo/stop-answering").json()
    assert v["engine"]["state"] == "checkin" and v["engine"]["ignore_pets"]
    r = c.post(f"/walks/{wid}/pet").json()
    assert r["events"][-1]["type"] == "pet_ignored"
    wk = jump(1)
    assert wk["clock"].speed == demo.ESCALATE_X
    for _ in range(4):
        jump(30)
    feed = c.get("/friends/maya/feed").json()
    alerts = feed["open_alerts"]
    assert len(alerts) == 1 and alerts[0]["kind"] == "no_answer" and alerts[0]["walker_name"] == "Jordan"
    assert alerts[0]["pos"]

    # Late pet calms the engine, alert stays open and shows "petted after".
    r = c.post(f"/walks/{wid}/pet").json()
    assert r["walk"]["engine"]["state"] == "calm"
    a = c.get("/friends/maya/feed").json()["open_alerts"][0]
    assert a["status"] == "open" and a["petted_after"]
    assert jump(1)["clock"].speed == demo.WALK_X

    # Only a friend can close it.
    assert c.post(f"/alerts/{a['id']}/close", json={"friend_id": "jordan"}).status_code == 403
    assert c.post(f"/alerts/{a['id']}/close", json={"friend_id": "maya"}).json()["status"] == "closed"
    assert c.get("/friends/maya/feed").json()["open_alerts"] == []

    # Duress: friend sees it, walker does not.
    r = c.post(f"/walks/{wid}/duress").json()
    assert r["walk"]["alerts"] == [] and r["walk"]["engine"]["alert_kind"] is None
    f = c.get("/friends/sam/feed").json()["open_alerts"]
    assert [x["kind"] for x in f] == ["duress"]
    c.post(f"/alerts/{f[0]['id']}/close", json={"friend_id": "sam"})

    # Off route: the sim drifts away and a check-in fires.
    c.post("/demo/deviate")
    for _ in range(8):
        jump(5)
    v = c.get(f"/walks/{wid}").json()
    assert v["off_route"] and v["engine"]["state"] == "checkin" and v["engine"]["reason"] == "off_route"


def test_demo_flow_twice_with_reset():
    run_demo_once()
    run_demo_once()  # second judge sees the same evolution


def test_checkin_now_button():
    c.post("/demo/reset")
    c.post("/demo/start", json={})
    v = c.post("/demo/checkin").json()
    assert v["engine"]["state"] == "checkin"


def test_demo_controls_need_a_walk():
    c.post("/demo/reset")
    assert c.post("/demo/stop-answering").status_code == 409


def test_unknown_things_404():
    assert c.get("/users/nobody").status_code == 404
    assert c.get("/walks/nope").status_code == 404
    assert c.post("/alerts/nope/close", json={"friend_id": "maya"}).status_code == 404


def test_planned_route_from_phone_runs_as_demo():
    c.post("/demo/reset")
    pts = [[33.4196, -111.9346], [33.4186, -111.9330], [33.4180, -111.9300]]
    w = c.post("/walks", json={"walker_id": "jordan", "demo": True, "points": pts,
                                "from_name": "Here", "to_name": "Tooker House"}).json()
    assert w["demo"] and w["route_id"].startswith("planned-")
    r = [x for x in c.get("/routes").json() if x["id"] == w["route_id"]][0]
    assert r["to"] == "Tooker House" and r["length_m"] > 100
    jump(10)
    assert c.get(f"/walks/{w['id']}").json()["pos"] != pts[0]


def test_customize_buddy_and_reset_restores():
    c.post("/demo/reset")
    b = c.post("/users/jordan/buddy", json={"name": "Biscuit", "species": "dog"}).json()
    assert b["name"] == "Biscuit" and b["species"] == "dog" and b["xp"] == 90
    assert c.get("/users/jordan").json()["buddy"]["species"] == "dog"
    assert c.post("/users/jordan/buddy", json={"species": "dragon"}).status_code == 400
    assert c.post("/users/jordan/buddy", json={"name": "  "}).status_code == 400
    c.post("/demo/reset")  # keeps the chosen pet, resets XP
    b = c.get("/users/jordan").json()["buddy"]
    assert b["name"] == "Biscuit" and b["species"] == "dog" and b["xp"] == 90
    c.post("/users/jordan/buddy", json={"name": "Melvin", "species": "dog"})


def test_route_assess_falls_back_to_rule_without_gemini(monkeypatch):
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    r = c.post("/routes/assess", json={"routes": [
        {"id": "a", "distance_m": 650, "minutes": 9, "steps": ["Turn right onto E University Dr", "Turn left onto S Rural Rd"]},
        {"id": "b", "distance_m": 600, "minutes": 8, "steps": ["Turn left onto a path", "Walk through the parking lot"]},
    ]}).json()
    assert r["source"] == "rule" and r["safer_id"] == "a" and set(r["reasons"]) == {"a", "b"}
