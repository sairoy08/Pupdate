"""Gemini writing for the buddy and for friends.

- checkin_line: the buddy's own words when it checks in ("Still good, Jordan? Almost past Cady Mall!").
- alert_summary: a short situational brief for the friend when an alert fires.

Both return an instant fallback first; Gemini runs in a background thread and replaces the text
when (and if) it answers within a few seconds. Nothing in the safety engine ever waits on it.
"""
import json
import logging
import os
import random
import threading

import httpx

log = logging.getLogger("pupdate.buddy_ai")
BASE = "https://generativelanguage.googleapis.com/v1beta"

FALLBACK_LINES = {
    "scheduled": ["Still good, {walker}?", "Quick check, {walker}: all OK?", "{walker}, give me a pet if you're fine!"],
    "off_route": ["Hey {walker}, this isn't our usual way. All good?", "We took a turn, {walker}. You OK?"],
    "moving_fast": ["Whoa, we're moving fast, {walker}. Everything OK?"],
    "stopped": ["We've stopped for a bit, {walker}. All good?"],
    "stop_answering": ["{walker}? Pet me so I know you're OK."],
    "demo": ["Still good, {walker}?"],
    "irregular_pace": ["Your pace changed, {walker}. Everything OK?", "Whoa, what's up, {walker}? Pet me if you're fine."],
    "flagged_area": ["{walker}, a friend flagged this spot. You OK?", "Careful, {walker}: flagged area. All good?"],
}


def _gemini_text(prompt, max_chars):
    key = os.getenv("GEMINI_API_KEY")
    if not key:
        return None
    model = os.getenv("GEMINI_MODEL") or "gemini-3.5-flash-lite"
    body = {"contents": [{"role": "user", "parts": [{"text": prompt}]}],
            "generationConfig": {"responseMimeType": "application/json", "temperature": 0.8}}
    r = httpx.post(f"{BASE}/models/{model}:generateContent", headers={"x-goog-api-key": key}, json=body, timeout=6)
    r.raise_for_status()
    parts = r.json()["candidates"][0]["content"]["parts"]
    text = next(p["text"] for p in parts if p.get("text") and not p.get("thought"))
    out = json.loads(text[text.find("{"): text.rfind("}") + 1]).get("text", "").strip()
    return out[:max_chars] if out else None


def gemini_json(prompt, temperature=0.3, timeout=6):
    """One Gemini call that must answer with a JSON object. Raises on any failure."""
    key = os.getenv("GEMINI_API_KEY")
    if not key:
        raise RuntimeError("no GEMINI_API_KEY")
    model = os.getenv("GEMINI_MODEL") or "gemini-3.5-flash-lite"
    body = {"contents": [{"role": "user", "parts": [{"text": prompt}]}],
            "generationConfig": {"responseMimeType": "application/json", "temperature": temperature}}
    r = httpx.post(f"{BASE}/models/{model}:generateContent", headers={"x-goog-api-key": key}, json=body, timeout=timeout)
    r.raise_for_status()
    parts = r.json()["candidates"][0]["content"]["parts"]
    text = next(p["text"] for p in parts if p.get("text") and not p.get("thought"))
    return json.loads(text[text.find("{"): text.rfind("}") + 1])


def fallback_line(reason, walker):
    pool = FALLBACK_LINES.get(reason or "scheduled", FALLBACK_LINES["scheduled"])
    return random.choice(pool).format(walker=walker)


def checkin_prompt(buddy, species, walker, reason, place):
    why = {"off_route": "the walker left their usual route", "moving_fast": "the walker started moving at car speed",
           "stopped": "the walker stopped for a while", "stop_answering": "the walker has not answered yet",
           "irregular_pace": "the walker's pace suddenly changed", "flagged_area": "the walker entered an area a friend flagged to avoid"}.get(
        reason or "", "a routine safety check")
    return (f"You are {buddy}, a cute pet {species} walking {walker} home at night in a safety app. "
            f"Write one short check-in line asking if they're OK (reason: {why}; where: {place}). "
            "Warm and playful, max 70 characters, mention a place if given, no emoji. "
            'Reply as JSON: {"text": "..."}')


def alert_prompt(walker, kind, place, minutes_in, last_checkin, buddy, context=""):
    what = {"no_answer": f"{walker} did not answer their buddy's check-ins for almost two minutes",
            "duress": f"{walker} sent a silent duress signal",
            "lost_contact": f"{walker}'s phone stopped checking in for 90 seconds",
            "help": f"{walker} ended their walk early and tapped 'I need help'"}.get(kind, "an alert fired")
    tone = "Tell the friend NOT to call first; suggest texting or going there with someone." if kind == "duress" else \
        "Suggest calling first."
    return (f"Write a calm, factual 1-2 sentence alert for a friend. Facts: {what}. Location: {place}. "
            f"{minutes_in} minutes into the walk. Last answered check-in: {last_checkin}. {context} {tone} "
            "Max 200 characters, no emoji, no speculation about crime. Reply as JSON: {\"text\": \"...\"}")


def fill_async(target, key, prompt, max_chars):
    """Run Gemini in the background and write its text into target[key] when it answers."""
    if not os.getenv("GEMINI_API_KEY"):
        return

    def run():
        try:
            text = _gemini_text(prompt, max_chars)
            if text:
                from .walks import LOCK
                with LOCK:
                    target[key] = text
                    target[key + "_source"] = "gemini"
        except Exception as e:
            log.warning("gemini %s failed: %s", key, e)

    threading.Thread(target=run, daemon=True).start()
