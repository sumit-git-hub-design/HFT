"""
Minimal trading dashboard backend.

What this does:
  - Simulates market ticks, a position, and a risk state (this is where you'd
    later plug in a real feed from your C++ engine / shared memory / a database).
  - Pushes updates to the browser over a WebSocket, so the GUI updates live
    without the browser having to keep asking "anything new?" (that's called polling).
  - Exposes one HTTP endpoint (POST /kill-switch) the frontend's button calls
    to flip the risk state — this mirrors the real kill-switch idea from the
    architecture doc, just without real hardware behind it yet.

How to run:
  pip install fastapi uvicorn
  uvicorn app:app --reload
  Then open frontend/index.html in your browser.
"""

import asyncio
import csv
import json
import random
import time
from dataclasses import dataclass, field
from pathlib import Path

from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware

app = FastAPI()

# --- Live file feed (from the C++ tick_writer program) -------------------
# If cpp/tick_writer.exe is running and writing live_state.json, we prefer
# that as the data source. Otherwise we fall back to replaying the CSV.
# This means you can start/stop the C++ program independently, at any time,
# without touching or restarting the Python backend — that decoupling is
# the whole point of talking through a file instead of hard-wiring them together.
LIVE_STATE_FILE = Path(__file__).parent / "live_state.json"
last_seen_sequence: int | None = None


def read_live_file() -> dict | None:
    if not LIVE_STATE_FILE.exists():
        return None
    try:
        with LIVE_STATE_FILE.open() as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError):
        # Extremely unlikely thanks to the atomic rename in tick_writer.cpp,
        # but if it ever happens, just skip this tick rather than crash.
        return None

# --- Historical tick replay ---------------------------------------------
# Loads sample_ticks.csv once at startup, then "replays" it row by row,
# looping back to the start when it runs out. This is the bridge between
# "random numbers" and "a real feed": the *shape* of the pipeline (read one
# tick, update state, broadcast) doesn't change at all when you eventually
# swap this for a live source — only this loading/reading part does.
def load_ticks(csv_path: Path) -> list[dict]:
    with csv_path.open() as f:
        reader = csv.DictReader(f)
        return [
            {"timestamp": float(row["timestamp"]), "price": float(row["price"]), "qty": int(row["qty"])}
            for row in reader
        ]


TICKS_FILE = Path(__file__).parent / "sample_ticks.csv"
historical_ticks: list[dict] = load_ticks(TICKS_FILE)
tick_cursor: int = 0

# Allow the frontend (opened as a plain file, or served from another port) to connect.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


@dataclass
class SystemState:
    """The one source of truth the backend serves. In a real system this would
    be updated by your engine, not by random numbers."""
    price: float = 24500.0
    position_qty: int = 0
    pnl: float = 0.0
    kill_switch_engaged: bool = False
    msgs_this_second: int = 0


state = SystemState()
connected_clients: set[WebSocket] = set()


def simulate_one_tick() -> None:
    """Prefer the live file written by tick_writer.cpp; fall back to the CSV
    replay if that file doesn't exist (e.g. you haven't started the C++
    program, or you stopped it). Either way, everything downstream of this
    function — the WebSocket broadcast, the frontend — is unaffected."""
    global tick_cursor, last_seen_sequence

    if state.kill_switch_engaged:
        return  # mirrors the real rule: nothing trades while the kill switch is up

    live = read_live_file()

    if live is not None:
        # Only apply it if it's a genuinely new tick (sequence advanced).
        # Without this check we'd re-apply the same fill logic multiple
        # times per second whenever Python polls faster than C++ writes.
        if live["sequence"] == last_seen_sequence:
            return
        last_seen_sequence = live["sequence"]

        previous_price = state.price
        state.price = live["price"]
        state.msgs_this_second += 1

        if random.random() < 0.1:
            qty_delta = random.choice([-1, 1]) * live["qty"]
            state.position_qty += qty_delta
            state.pnl += -qty_delta * (state.price - previous_price) / 100.0
        return

    # --- fallback: CSV replay, unchanged from before ---
    if not historical_ticks:
        return

    tick = historical_ticks[tick_cursor]
    previous_price = state.price
    state.price = tick["price"]
    state.msgs_this_second += 1

    if random.random() < 0.1:
        qty_delta = random.choice([-1, 1]) * tick["qty"]
        state.position_qty += qty_delta
        state.pnl += -qty_delta * (state.price - previous_price) / 100.0

    tick_cursor = (tick_cursor + 1) % len(historical_ticks)


async def broadcaster() -> None:
    """Runs forever: ticks the simulated state and pushes it to every connected browser."""
    while True:
        simulate_one_tick()
        payload = {
            "type": "state_update",
            "timestamp": time.time(),
            "price": round(state.price, 2),
            "position_qty": state.position_qty,
            "pnl": round(state.pnl, 2),
            "kill_switch_engaged": state.kill_switch_engaged,
            "msgs_this_second": state.msgs_this_second,
        }
        state.msgs_this_second = 0

        dead_clients = set()
        for ws in connected_clients:
            try:
                await ws.send_json(payload)
            except Exception:
                dead_clients.add(ws)
        connected_clients.difference_update(dead_clients)

        await asyncio.sleep(0.2)  # 5 updates/sec — plenty for a human-readable dashboard


@app.on_event("startup")
async def start_background_task():
    asyncio.create_task(broadcaster())


@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket):
    await websocket.accept()
    connected_clients.add(websocket)
    try:
        while True:
            await websocket.receive_text()  # we don't expect messages from the client here
    except WebSocketDisconnect:
        connected_clients.discard(websocket)


@app.post("/kill-switch/engage")
async def engage_kill_switch():
    state.kill_switch_engaged = True
    return {"kill_switch_engaged": True}


@app.post("/kill-switch/clear")
async def clear_kill_switch():
    state.kill_switch_engaged = False
    return {"kill_switch_engaged": False}
