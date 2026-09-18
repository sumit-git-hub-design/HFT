// tick_writer.cpp
//
// A standalone C++ program that simulates market ticks and writes the
// current state to live_state.json every 200ms. Run this ALONGSIDE the
// Python backend (two separate terminal windows) — the Python side will
// pick up this file automatically once it exists.
//
// This is intentionally the simplest possible producer: no sockets, no
// shared memory, just a file on disk. That makes the IPC (inter-process
// communication) mechanism itself easy to see and reason about before
// you move to faster mechanisms later.
//
// KEY IDEA — atomic writes:
//   We never write directly to live_state.json. We write to a temp file
//   (live_state.json.tmp), close it fully, THEN rename it on top of
//   live_state.json. A rename on the same filesystem is atomic — the
//   reader (Python) will only ever see the file fully absent or fully
//   present with complete content, never a half-written one.
//
// Build (Windows, MinGW-w64):
//   g++ -O2 -std=c++17 tick_writer.cpp -o tick_writer.exe
//
// Build (Windows, MSVC — from a "Developer Command Prompt for VS"):
//   cl /EHsc /std:c++17 tick_writer.cpp
//
// Run:
//   .\tick_writer.exe
//   (Ctrl+C to stop)

#include <chrono>
#include <cstdio>
#include <fstream>
#include <iostream>
#include <random>
#include <sstream>
#include <string>
#include <thread>

int main() {
    std::mt19937 rng(std::random_device{}());
    std::uniform_real_distribution<double> price_step(-3.0, 3.0);
    std::uniform_int_distribution<int> qty_dist(25, 150);

    double price = 24500.0;
    long long sequence = 0;

    const std::string final_path = "live_state.json";
    const std::string temp_path = "live_state.json.tmp";

    std::cout << "tick_writer: writing to " << final_path
              << " every 200ms. Press Ctrl+C to stop.\n";

    while (true) {
        price += price_step(rng);
        const int qty = qty_dist(rng);
        ++sequence;

        const auto now = std::chrono::system_clock::now();
        const auto epoch_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                                   now.time_since_epoch())
                                   .count();

        std::ostringstream json;
        json << "{"
             << "\"timestamp\": " << (epoch_ms / 1000.0) << ", "
             << "\"price\": " << price << ", "
             << "\"qty\": " << qty << ", "
             << "\"sequence\": " << sequence
             << "}";

        // 1. Write to the temp file and make sure it's fully flushed to disk
        //    before we touch the real filename.
        {
            std::ofstream out(temp_path, std::ios::trunc);
            out << json.str();
        } // destructor closes + flushes the file here

        // 2. Atomically publish it. std::rename() on the same drive is a
        //    single filesystem operation — there is no in-between state
        //    a reader can observe.
        if (std::rename(temp_path.c_str(), final_path.c_str()) != 0) {
            std::perror("rename failed");
        }

        std::cout << "seq=" << sequence << " price=" << price << "\r" << std::flush;

        std::this_thread::sleep_for(std::chrono::milliseconds(200));
    }

    return 0;
}
