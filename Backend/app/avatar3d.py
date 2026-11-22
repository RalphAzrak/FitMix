"""3D avatars: the app posts the user's accepted portrait and this server builds a USDZ model from it.

The model is built on this computer by `Backend/avatar3d/build.sh`: nothing is sent to another service. A build
takes minutes, so it runs as a job the app polls. One build runs at a time; the portrait is written to a private
temporary folder for the length of that build and deleted with it, and a finished model is kept in memory until it
has been collected or the job expires.
"""

import asyncio
import os
import tempfile
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Protocol

BUILD_SCRIPT = Path(__file__).resolve().parents[1] / "avatar3d" / "build.sh"
FIXTURE = Path(__file__).parent / "fixtures" / "placeholder-avatar.usdz"
# The steps the app can show, in order. They are the "STAGE" lines build.sh prints.
STAGES = ("cutout", "shape", "face", "package")


class Progress(Protocol):
    """What a builder reports while it works."""

    def stage(self, name: str) -> None: ...

    def percent(self, value: int) -> None: ...


class BuildFailed(Exception):
    """A build that ended without a model. `message` is written for the person using the app."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code, self.message = code, message


@dataclass
class Built:
    model: bytes
    # False when the head could not be placed precisely on the model, so the face has only the whole-figure
    # texture's lower detail.
    face_sharpened: bool
    # Why the face step was left out, for the server log.
    face_note: str | None = None


class Builder(Protocol):
    ready: bool

    async def build(self, portrait: bytes, progress: Progress) -> Built: ...


class MockBuilder:
    """A labeled stand-in model, for trying the app without the tools or the wait (FITMIX_MOCK=1)."""

    ready = True

    def __init__(self, step_seconds: float = 0.6):
        self.step_seconds = step_seconds

    async def build(self, portrait: bytes, progress: Progress) -> Built:
        for index, stage in enumerate(STAGES):
            progress.stage(stage)
            for part in range(5):
                progress.percent((index * 5 + part) * 5)
                await asyncio.sleep(self.step_seconds / 5)
        progress.percent(100)
        return Built(FIXTURE.read_bytes(), face_sharpened=False, face_note="placeholder model")


class ScriptBuilder:
    """Runs build.sh on a portrait and reads its progress."""

    def __init__(self, script: Path = BUILD_SCRIPT, timeout_seconds: float = 1200.0):
        self.script, self.timeout_seconds = Path(script), timeout_seconds

    @property
    def ready(self) -> bool:
        tools = Path(os.environ.get("FITMIX_AVATAR3D_TOOLS") or self.script.parent / ".tools")
        return os.access(self.script, os.X_OK) and (tools / "trellis" / "trellis-cli").exists()

    async def build(self, portrait: bytes, progress: Progress) -> Built:
        with tempfile.TemporaryDirectory(prefix="fitmix-portrait-") as folder:   # private to this user (0700)
            source, model = Path(folder) / "portrait", Path(folder) / "avatar.usdz"
            source.write_bytes(portrait)
            process = await asyncio.create_subprocess_exec(
                str(self.script), str(source), str(model),
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE, start_new_session=True)
            face, note = False, None

            async def follow():
                nonlocal face, note
                async for raw in process.stdout:
                    line = raw.decode(errors="replace").strip()
                    if line.startswith("STAGE ") and line[6:] in STAGES:
                        progress.stage(line[6:])
                    elif line.startswith("PROGRESS ") and line[9:].isdigit():
                        progress.percent(int(line[9:]))
                    elif line.startswith(("FACE SKIPPED:", "BODY SKIPPED:")):
                        reason = ("face: " if line.startswith("FACE") else "whole-figure texture: ") + line[13:].strip()
                        note = f"{note}; {reason}" if note else reason
                    elif line.startswith("RESULT "):
                        face = "face=1" in line
                return (await process.stderr.read()).decode(errors="replace")

            try:
                errors = await asyncio.wait_for(follow(), self.timeout_seconds)
                code = await process.wait()
            except asyncio.TimeoutError:
                _stop(process)
                raise BuildFailed("timeout", "Building the 3D avatar took too long. Try again.")
            except asyncio.CancelledError:
                _stop(process)
                raise
            if code != 0 or not model.exists():
                for line in reversed(errors.splitlines()):
                    if line.startswith("ERROR "):
                        _, reason, message = line.split(" ", 2)
                        raise BuildFailed(reason, message)
                raise BuildFailed("build_failed", "The 3D avatar couldn't be built. Try again.")
            return Built(model.read_bytes(), face_sharpened=face, face_note=note)


def _stop(process: asyncio.subprocess.Process) -> None:
    """Ends the build and everything it started (Blender, the model runner)."""
    try:
        os.killpg(process.pid, 15)
    except ProcessLookupError:
        pass


class QueueFull(Exception):
    pass


class _Follow:
    """Writes a builder's progress onto its job."""

    def __init__(self, job: "Job"):
        self.job = job

    def stage(self, name: str) -> None:
        self.job.stage = name

    def percent(self, value: int) -> None:
        self.job.progress = max(self.job.progress, min(int(value), 99))   # 100 only once the model is in hand


@dataclass
class Job:
    id: str
    owner: str
    status: str = "queued"          # queued, running, done, failed
    stage: str | None = None
    progress: int = 0               # percent of the whole build, never going backwards
    started: float = field(default_factory=time.monotonic)
    built: Built | None = None
    error: BuildFailed | None = None
    finished: float | None = None
    task: asyncio.Task | None = field(default=None, repr=False)


class Jobs:
    """Builds in the order they arrive, one at a time, and keeps each result until collected or expired."""

    def __init__(self, builder: Builder, keep_seconds: float = 1800.0, max_waiting: int = 3):
        self.builder, self.keep_seconds, self.max_waiting = builder, keep_seconds, max_waiting
        self.jobs: dict[str, Job] = {}
        self._turn = asyncio.Lock()

    def submit(self, portrait: bytes, owner: str) -> Job:
        self._expire()
        if sum(job.status in ("queued", "running") for job in self.jobs.values()) > self.max_waiting:
            raise QueueFull()
        job = Job(id=uuid.uuid4().hex, owner=owner)
        self.jobs[job.id] = job
        job.task = asyncio.get_running_loop().create_task(self._run(job, portrait))
        return job

    def get(self, job_id: str) -> Job | None:
        self._expire()
        return self.jobs.get(job_id)

    def position(self, job: Job) -> int:
        """How many builds are ahead of this one."""
        if job.status != "queued":
            return 0
        ahead = 0
        for other in self.jobs.values():   # insertion order is arrival order
            if other is job:
                break
            ahead += other.status in ("queued", "running")
        return ahead

    def cancel(self, job: Job) -> None:
        if job.task and not job.task.done():
            job.task.cancel()
        self.jobs.pop(job.id, None)

    async def _run(self, job: Job, portrait: bytes) -> None:
        try:
            async with self._turn:
                job.status = "running"
                job.built = await self.builder.build(portrait, _Follow(job))
                job.status, job.progress = "done", 100
        except BuildFailed as error:
            job.status, job.error = "failed", error
        except asyncio.CancelledError:
            raise
        except Exception:   # never leave a job the app would poll forever
            job.status, job.error = "failed", BuildFailed("build_failed", "The 3D avatar couldn't be built. Try again.")
        finally:
            job.finished = time.monotonic()

    def _expire(self) -> None:
        now = time.monotonic()
        for job_id in [i for i, j in self.jobs.items() if j.finished and now - j.finished > self.keep_seconds]:
            del self.jobs[job_id]
