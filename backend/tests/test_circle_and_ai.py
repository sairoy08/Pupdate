from fastapi.testclient import TestClient

from app import buddy_ai, demo, walks
from app.main import app

c = TestClient(app)


def test_add_and_remove_friends(monkeypatch):
    c.post("/demo/reset")
    names = {f["name"] for f in c.get("/users/jordan/circle").json()}
    assert names == {"Maya", "Sam"}
    alex = c.post("/users/jordan/circle", json={"name": "Alex Kim", "phone": "(480) 555-0199"}).json()
    assert alex["name"] == "Alex Kim" and alex["phone"] == "4805550199"
    assert len(c.get("/users/jordan/circle").json()) == 3
    assert c.post("/users/jordan/circle", json={"name": "  "}).status_code == 400
    assert c.delete("/users/jordan/circle/sam").json()["ok"]
    assert {f["name"] for f in c.get("/users/jordan/circle").json()} == {"Maya", "Alex Kim"}
    assert c.delete("/users/jordan/circle/sam").status_code == 404
    # Removed friends stop getting alerts; added friends start getting them.
    w = c.post("/demo/start", json={}).json()
    c.post(f"/walks/{w['id']}/duress")
    assert c.get("/friends/sam/feed").json()["open_alerts"] == []
    assert len(c.get(f"/friends/{alex['id']}/feed").json()["open_alerts"]) == 1
    # Reset keeps the circle.
    c.post("/demo/reset")
    assert {f["name"] for f in c.get("/users/jordan/circle").json()} == {"Maya", "Alex Kim"}
    # Put the demo circle back.
    c.delete(f"/users/jordan/circle/{alex['id']}")
    c.post("/users/jordan/circle", json={"name": "Sam"})
    assert {f["name"] for f in c.get("/users/jordan/circle").json()} == {"Maya", "Sam"}


def test_checkin_line_and_alert_summary_fallbacks(monkeypatch):
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    c.post("/demo/reset")
    w = c.post("/demo/start", json={}).json()
    v = c.post("/demo/checkin").json()
    assert v["buddy_line"] and "Jordan" in v["buddy_line"] and v["buddy_line_source"] == "fallback"
    c.post(f"/walks/{w['id']}/duress")
    a = c.get("/friends/maya/feed").json()["open_alerts"][0]
    assert "Don't call" in a["summary"] and a["summary_source"] == "fallback"
    r = c.post(f"/walks/{w['id']}/pet").json()
    assert r["walk"]["buddy_line"] is None  # calm again: no prompt


def test_prompts_are_grounded():
    p = buddy_ai.alert_prompt("Jordan", "duress", "near Tooker House", 6, "none yet", "Melvin")
    assert "NOT to call" in p and "no speculation" in p
    assert "70 characters" in buddy_ai.checkin_prompt("Melvin", "dog", "Jordan", "off_route", "near Cady Mall")
