from app import buddy
from app.engine import ESCALATION_TOTAL, Engine


def kinds(ev):
    return [e["type"] for e in ev]


def test_escalation_timing_table():
    e = Engine(0, demo=True)
    assert e.state == "calm" and e.next_checkin is None  # demo walks have no schedule
    e.request_checkin(0, "demo")
    checkpoints = [(29.9, "checkin"), (30, "nudge"), (59.9, "nudge"), (60, "final"),
                   (90, "countdown"), (109.9, "countdown")]
    for t, state in checkpoints:
        e.tick(t)
        assert e.state == state, (t, e.state)
    ev = e.tick(110)
    assert e.state == "alert" and e.alert_kind == "no_answer"
    assert {"type": "alert_raised", "kind": "no_answer", "at": 110} in ev
    assert ESCALATION_TOTAL == 110


def test_big_jump_walks_through_all_stages():
    e = Engine(0, demo=True)
    e.request_checkin(0, "demo")
    e.tick(100)
    ev = e.advance(150)
    assert kinds(ev) == ["alert_raised"] and e.state == "alert"
    e2 = Engine(0, demo=True)
    e2.request_checkin(0, "demo")
    e2.tick(1)
    ev = e2.advance(89)  # one call crosses three stage boundaries
    assert kinds(ev) == ["escalated", "escalated"] and e2.state == "final"


def test_on_time_pet_gives_xp_and_calms():
    e = Engine(0, demo=True)
    e.request_checkin(10, "demo")
    ev = e.pet(20)
    assert ev[-1]["xp"] == 10 and e.state == "calm"


def test_late_pet_no_xp():
    e = Engine(0, demo=True)
    e.request_checkin(0, "demo")
    ev = e.pet(45)  # in nudge
    assert ev[-1]["xp"] == 0 and e.state == "calm"


def test_pet_after_alert_calms_engine_without_xp():
    e = Engine(0, demo=True)
    e.request_checkin(0, "demo")
    e.tick(80); e.tick(111)
    assert e.state == "alert"
    ev = e.pet(115)
    assert ev[-1] == {"type": "pet_ok", "xp": 0, "after_alert": True, "at": 115}
    assert e.state == "calm"


def test_stop_answering_ignores_pets_until_alert():
    e = Engine(0, demo=True)
    e.request_checkin(0, "stop_answering", ignore_pets=True)
    ev = e.pet(5)
    assert kinds(ev) == ["pet_ignored"] and e.state == "checkin"
    e.tick(60); e.tick(110)
    assert e.state == "alert" and not e.ignore_pets
    assert e.pet(112)[-1]["after_alert"]


def test_duress_is_silent_and_immediate():
    e = Engine(0, demo=True)
    ev = e.duress(5)
    assert ev == [{"type": "alert_raised", "kind": "duress", "silent": True, "at": 5}]
    assert e.state == "calm"  # walker screen stays calm


def test_lost_contact_after_90s_and_restore():
    e = Engine(0, demo=True)
    e.tick(10, (33.42, -111.93))
    assert e.advance(99.9) == []
    ev = e.advance(100)
    assert ev == [{"type": "alert_raised", "kind": "lost_contact", "at": 100}]
    ev = e.tick(120, None)  # noisy fix: tick still counts, last good position kept
    assert kinds(ev) == ["contact_restored"] and e.last_pos == [33.42, -111.93]


def test_tick_without_position_prevents_lost_contact():
    e = Engine(0, demo=True)
    for t in range(0, 300, 30):
        e.tick(t, None)
    assert not e.lost_contact


def test_real_walk_checks_in_on_a_fixed_schedule():
    e = Engine(0, demo=False, every=300)
    assert e.next_checkin == 300
    for t in range(0, 300, 30):
        e.tick(t)
    ev = e.tick(300)
    assert kinds(ev) == ["checkin_started"] and e.state == "checkin"
    e.pet(310)
    assert e.next_checkin == 610  # rescheduled from the answer


def test_triggers_only_mode_never_schedules():
    e = Engine(0, demo=False, every=None)
    for t in range(0, 3000, 30):
        e.tick(t)
    assert e.state == "calm" and e.next_checkin is None
    e.request_checkin(3000, "off_route")
    assert e.state == "checkin"


def test_buddy_evolves_at_100():
    b = {"name": "Melvin", "xp": 90, "form": "sprout"}
    b, evolved = buddy.add_xp(b, 10)
    assert evolved == "strider" and b["xp"] == 100
    b, evolved = buddy.add_xp(b, 10)
    assert evolved is None
