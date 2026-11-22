import asyncio
import os
import stat
import time

import pytest
from fastapi.testclient import TestClient

from app import avatar3d
from app.main import Settings, create_app
from app.mock import placeholder_png

PNG = placeholder_png()
MODEL = b"PK\x03\x04 pretend usdz"


class FakeBuilder:
    """Stands in for build.sh. `hold` keeps a build running until the test releases it."""

    ready = True

    def __init__(self, failure=None, hold=False):
        self.portraits, self.failure = [], failure
        self.release = None if not hold else asyncio.Event()

    async def build(self, portrait, progress):
        self.portraits.append(portrait)
        progress.stage("shape")
        progress.percent(40)
        if self.release is not None:
            await self.release.wait()
        if self.failure:
            raise self.failure
        return avatar3d.Built(MODEL, face_sharpened=True)


def start(c, headers=None, body=PNG):
    return c.post("/v1/avatar-3d", files={"portrait": ("avatar.png", body, "image/png")}, headers=headers or {})


def wait_for(c, job, status, headers=None):
    for _ in range(200):
        state = c.get(f"/v1/avatar-3d/{job}", headers=headers or {}).json()
        if state["status"] == status:
            return state
        time.sleep(0.01)
    raise AssertionError(f"build never became {status}: {state}")


def test_builds_from_the_portrait_and_hands_over_the_model():
    builder = FakeBuilder()
    with TestClient(create_app(Settings(), builder=builder)) as c:
        started = start(c)
        assert started.status_code == 202 and started.json()["status"] in ("queued", "running")
        job = started.json()["job"]
        done = wait_for(c, job, "done")
        assert done["face_sharpened"] is True and done["error"] is None and done["progress"] == 100
        model = c.get(f"/v1/avatar-3d/{job}/model")
        assert model.status_code == 200 and model.content == MODEL
        assert model.headers["content-type"] == "model/vnd.usdz+zip" and model.headers["cache-control"] == "no-store"
        assert builder.portraits == [PNG]


def test_reports_the_stage_and_refuses_the_model_until_it_is_finished():
    with TestClient(create_app(Settings(), builder=FakeBuilder(hold=True))) as c:
        job = start(c).json()["job"]
        running = wait_for(c, job, "running")
        assert running["stage"] == "shape" and running["progress"] == 40 and running["face_sharpened"] is None
        assert c.get(f"/v1/avatar-3d/{job}/model").json()["error"]["code"] == "not_ready"


def test_one_build_at_a_time_and_later_ones_know_their_place():
    builder = FakeBuilder(hold=True)
    with TestClient(create_app(Settings(), builder=builder)) as c:
        first, second = start(c).json()["job"], start(c).json()["job"]
        wait_for(c, first, "running")
        waiting = c.get(f"/v1/avatar-3d/{second}").json()
        assert waiting["status"] == "queued" and waiting["position"] == 1 and len(builder.portraits) == 1
        c.portal.call(builder.release.set)
        wait_for(c, second, "done")


def test_turns_more_builds_away_when_the_queue_is_full():
    with TestClient(create_app(Settings(avatar3d_rate_limit_per_hour=50), builder=FakeBuilder(hold=True))) as c:
        codes = [start(c).status_code for _ in range(6)]
        assert codes[:4] == [202] * 4 and 503 in codes[4:]


def test_a_failed_build_says_why_in_words_for_the_user():
    failure = avatar3d.BuildFailed("no_person", "FitMix couldn't find one person in the portrait.")
    with TestClient(create_app(Settings(), builder=FakeBuilder(failure=failure))) as c:
        job = start(c).json()["job"]
        failed = wait_for(c, job, "failed")
        assert failed["error"] == {"code": "no_person", "message": "FitMix couldn't find one person in the portrait."}
        assert c.get(f"/v1/avatar-3d/{job}/model").status_code == 409


def test_cancelling_stops_the_build_and_forgets_it():
    builder = FakeBuilder(hold=True)
    with TestClient(create_app(Settings(), builder=builder)) as c:
        job = start(c).json()["job"]
        wait_for(c, job, "running")
        assert c.delete(f"/v1/avatar-3d/{job}").status_code == 204
        assert c.get(f"/v1/avatar-3d/{job}").status_code == 404
        # The builder is free again for the next person.
        c.portal.call(builder.release.set)
        wait_for(c, start(c).json()["job"], "done")


def test_rejects_what_is_not_a_picture_and_unknown_builds():
    with TestClient(create_app(Settings(), builder=FakeBuilder())) as c:
        assert start(c, body=b"not a picture").json()["error"]["code"] == "invalid_image"
        assert c.get("/v1/avatar-3d/nope").json()["error"]["code"] == "not_found"


def test_needs_the_app_token_to_start_follow_or_collect():
    good = {"Authorization": "Bearer secret"}
    with TestClient(create_app(Settings(app_token="secret"), builder=FakeBuilder())) as c:
        assert start(c).status_code == 401
        job = start(c, headers=good).json()["job"]
        assert c.get(f"/v1/avatar-3d/{job}").status_code == 401
        wait_for(c, job, "done", headers=good)
        assert c.get(f"/v1/avatar-3d/{job}/model").status_code == 401
        assert c.get(f"/v1/avatar-3d/{job}/model", headers=good).status_code == 200


def test_limits_how_many_builds_one_device_can_start_in_an_hour():
    with TestClient(create_app(Settings(avatar3d_rate_limit_per_hour=2), builder=FakeBuilder())) as c:
        assert [start(c).status_code for _ in range(3)] == [202, 202, 429]


def test_says_so_when_the_builder_is_not_installed():
    class Missing(FakeBuilder):
        ready = False
    with TestClient(create_app(Settings(), builder=Missing())) as c:
        assert c.get("/health").json()["avatar3d_ready"] is False
        response = start(c)
        assert response.status_code == 503 and response.json()["error"]["code"] == "not_configured"


def test_mock_mode_returns_the_labeled_placeholder_model():
    with TestClient(create_app(Settings(mock=True), builder=avatar3d.MockBuilder(step_seconds=0))) as c:
        assert c.get("/health").json()["avatar3d_ready"] is True
        job = start(c).json()["job"]
        assert wait_for(c, job, "done")["face_sharpened"] is False
        assert c.get(f"/v1/avatar-3d/{job}/model").content[:2] == b"PK"


class Seen:
    """Records what a builder reports."""

    def __init__(self):
        self.stages, self.percents = [], []

    def stage(self, name):
        self.stages.append(name)

    def percent(self, value):
        self.percents.append(value)


def script(tmp_path, body):
    path = tmp_path / "build.sh"
    path.write_text("#!/bin/bash\n" + body)
    path.chmod(path.stat().st_mode | stat.S_IXUSR)
    return path


def test_the_script_builder_reads_progress_and_the_result(tmp_path):
    builder = avatar3d.ScriptBuilder(script(tmp_path, 'echo "STAGE cutout"; echo "PROGRESS 2"; echo "STAGE shape"; echo "PROGRESS 57"; cp "$1" "$2"; echo "RESULT face=1"\n'))
    seen = Seen()
    built = asyncio.run(builder.build(PNG, seen))
    assert built.model == PNG and built.face_sharpened and seen.stages == ["cutout", "shape"] and seen.percents == [2, 57]


def test_the_script_builder_keeps_the_reason_the_face_step_was_skipped(tmp_path):
    builder = avatar3d.ScriptBuilder(script(tmp_path, 'echo "FACE SKIPPED: no face was found in the portrait"; cp "$1" "$2"; echo "RESULT face=0"\n'))
    built = asyncio.run(builder.build(PNG, Seen()))
    assert not built.face_sharpened and built.face_note == "face: no face was found in the portrait"


def test_progress_never_goes_backwards_and_reaches_100_only_at_the_end():
    job = avatar3d.Job(id="j", owner="o")
    follow = avatar3d._Follow(job)
    for value in (10, 40, 25, 100):
        follow.percent(value)
    assert job.progress == 99


def test_the_script_builder_passes_on_the_reason_a_build_failed(tmp_path):
    builder = avatar3d.ScriptBuilder(script(tmp_path, 'echo "ERROR no_person No person here." >&2; exit 1\n'))
    with pytest.raises(avatar3d.BuildFailed) as failure:
        asyncio.run(builder.build(PNG, Seen()))
    assert failure.value.code == "no_person" and failure.value.message == "No person here."


def test_the_script_builder_deletes_the_portrait_when_the_build_ends(tmp_path):
    seen = tmp_path / "where"
    builder = avatar3d.ScriptBuilder(script(tmp_path, f'echo "$1" > "{seen}"; cp "$1" "$2"\n'))
    asyncio.run(builder.build(PNG, Seen()))
    assert not os.path.exists(seen.read_text().strip())
