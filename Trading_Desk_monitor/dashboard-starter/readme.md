Trading Desk Monitor — Build Log & Reference Guide

A running reference of everything set up so far: a minimal GUI/frontend/backend stack for a trading dashboard, built step by step while learning full-stack basics on a Windows machine.

1. Core Concepts (the "why" behind the folder structure)
Piece	What it is	In this project
Backend	A program holding the real data/logic, answering questions about it over a network API	backend/app.py — a Python (FastAPI) server
Frontend	Code that runs in the browser and turns backend data into visuals	frontend/index.html — plain HTML/CSS/JS, no framework, no build step
GUI	What the user actually sees and clicks	The rendered dashboard page in the browser

Golden rule: the frontend never talks to the data source directly. It only talks to the backend over the network (HTTP + WebSocket here). This means the backend's data source can be swapped — random numbers → CSV replay → a live C++ program — without ever touching the frontend code.

┌──────────────┐      WebSocket/HTTP       ┌──────────────┐      file / later: sockets, shared memory
│   Browser    │ ◀───────────────────────▶ │   Backend    │ ◀──────────────────────────────────────
│ (Frontend/GUI)│      JSON messages        │  (Python)    │                                         │
└──────────────┘                           └──────────────┘                              ┌────────────┴──┐
                                                                                          │ tick_writer.cpp │
                                                                                          │   (C++)         │
                                                                                          └─────────────────┘
2. Folder Structure
dashboard-starter/
├── backend/
│   ├── app.py            # FastAPI server: WebSocket broadcast + kill-switch endpoints
│   └── sample_ticks.csv   # synthetic historical tick data (fallback data source)
├── frontend/
│   └── index.html         # the entire GUI: HTML + CSS + JS in one file
└── cpp/
    └── tick_writer.cpp    # standalone C++ producer, writes live_state.json

Data source priority in app.py: if backend/live_state.json exists (written by the running tick_writer.exe), it's used. Otherwise, app.py falls back to replaying sample_ticks.csv on a loop. This lets you start/stop the C++ producer independently, at any time, without restarting the Python backend.

3. Windows Setup (one-time)
Install Python 3.9+ from python.org — during install, tick "Add python.exe to PATH."
Open PowerShell and confirm: python --version
Install backend dependencies (WebSocket support requires the [standard] extra):
   python -m pip install "uvicorn[standard]" fastapi

(If that quoting causes issues in PowerShell: python -m pip install websockets fastapi uvicorn) 4. For the C++ producer, install a compiler — MSYS2 (msys2.org) is the easiest route to MinGW-w64 on Windows:

   pacman -S mingw-w64-x86_64-gcc

Confirm with: g++ --version

4. Running It

Terminal 1 — backend:

cd path\to\dashboard-starter\backend
python -m uvicorn app:app --reload

Look for: Uvicorn running on http://127.0.0.1:8000 with no "Unsupported upgrade request" warning (that warning means the [standard]/websockets package above wasn't installed correctly — reinstall it and restart).

Terminal 2 — optional C++ producer, for live-file mode:

cd path\to\dashboard-starter\cpp
g++ -O2 -std=c++17 tick_writer.cpp -o tick_writer.exe
copy tick_writer.exe ..\backend\
cd ..\backend
.\tick_writer.exe

tick_writer.exe must be run from inside the backend folder, since it writes live_state.json into whatever folder it's launched from, and app.py looks for that file next to itself.

Frontend: Double-click frontend/index.html — no server needed for it, it's a plain file the browser opens directly. It connects out to ws://127.0.0.1:8000/ws.

5. Troubleshooting Log (issues actually hit, and the fixes)
Symptom	Cause	Fix
uvicorn not recognized	pip/Python Scripts folder not on PATH	Use python -m uvicorn ... instead of bare uvicorn ...
PowerShell error Got unexpected extra argument	Extra word accidentally typed/pasted after the real command	Retype the command exactly, nothing extra after --reload
WARNING: No supported WebSocket library detected + /ws returns 404	uvicorn was installed without WebSocket support	python -m pip install "uvicorn[standard]" (or pip install websockets), then restart the server
Frontend stuck on "disconnected"	Backend not running, wrong port, or firewall block	Test http://127.0.0.1:8000 directly in the browser first; check the backend terminal is still running; allow through Windows Firewall if prompted
g++ compiles with no errors, but .exe never appears in dir	Antivirus/corporate EDR silently deletes freshly-compiled unsigned .exe files right after creation	On a personal machine: add a folder exclusion in Windows Security → Virus & threat protection → Manage settings. On a corporate laptop: this usually requires an IT/security ticket requesting a folder exclusion for the dev directory — you generally cannot self-exclude
Need to keep working while waiting on an IT exclusion ticket	Corporate EDR blocks compiled binaries, ticket takes time	Swap the C++ producer for a Python producer script instead (same file-based JSON protocol, same atomic-rename pattern) — since it's not a compiled .exe, it's far less likely to trip the same block. Swap back to the real C++ version once IT clears the exclusion; the backend doesn't care which one wrote the file
6. What Each Backend Data Source Taught
Random numbers (random.uniform) — proved the WebSocket → frontend render loop works, with zero external dependencies.
CSV replay (sample_ticks.csv) — introduced reading structured data from a file and replaying it deterministically (same sequence every restart), closer to how you'd back-test against historical data.
Live file from a separate process (tick_writer.cpp → live_state.json) — introduced inter-process communication (IPC): two independently running programs, one producing, one consuming, coordinated only through a file on disk. Key lesson: atomic writes (write to a .tmp file, then rename() it on top of the real file) are required so the reader never sees a half-written file. Also surfaced a real limitation of file-based IPC: there's no built-in "are you still alive?" signal — if the producer dies, the consumer just keeps reading stale data forever, unlike a WebSocket which detects disconnects automatically.
7. Next Steps (not yet done)
 Get IT to add a folder exclusion so tick_writer.exe survives compilation
 Build a Python-producer fallback (tick_writer.py) to keep progressing while waiting on the IT ticket
 Add a second data type (e.g. a small order-book table: a few bid/ask levels) instead of a single price
 Add a "producer alive?" indicator to the dashboard — e.g. track the file's last-modified time in app.py and flag it stale if it hasn't changed in >1 second, mirroring the real watchdog-timeout idea from the hardware risk-circuit design
 Eventually move from file-based IPC to a faster mechanism (local socket, shared memory) once the concept is solid — file-based is deliberately the slowest, simplest starting point
