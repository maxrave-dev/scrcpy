#!/usr/bin/env python3
"""Isolated MCP fixture. Never invokes real adb, scrcpy, a device, or a host shell."""
import base64
import json
import os
import signal
import struct
import sys
import time
import zlib

if os.path.basename(sys.argv[0]) == "scrcpy":
    print("INFO: SCRCPY_MAC_WINDOW_READY", flush=True)
    time.sleep(120)
    sys.exit(0)

arguments = sys.argv[1:]
with open(os.environ["TEST_ADB_CALLS"], "a", encoding="utf-8") as output:
    output.write(json.dumps(arguments) + "\n")

args = list(arguments)
while args and args[0].startswith("-"):
    flag = args.pop(0)
    if flag in ("-s", "-t", "-H", "-P", "-L", "--one-device"):
        args.pop(0)
command = args[0] if args else "help"
rest = args[1:]

if command == "devices":
    print("List of devices attached\nfixture device model:Fixture_Device transport_id:1")
elif command == "connect":
    print("connected to " + rest[0])
elif command == "pair":
    sys.stdin.readline()
    print("Successfully paired")
elif command == "exec-out" and rest[:2] == ["screencap", "-p"]:
    def chunk(name, payload):
        return struct.pack(">I", len(payload)) + name + payload + struct.pack(">I", zlib.crc32(name + payload))
    sys.stdout.buffer.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(b"\x00\xff\x00\x00\xff")) + chunk(b"IEND", b""))
elif command == "logcat":
    if "-c" in rest:
        sys.exit(0)
    print("[ 2026-10-28 12:00:00.123 42: 43 E/AndroidRuntime ]\nFATAL EXCEPTION: main\n at App.start(App.kt:2)\n\n[ 2026-10-28 12:00:00.124 42: 43 I/Other ]\nafter\n", flush=True)
    if "-d" not in rest:
        time.sleep(120)
elif command == "shell":
    rest = [part for part in rest if part not in ("-T", "-tt")]
    script = " ".join(rest)
    if script == "fixture-stdin":
        sys.stdout.buffer.write(sys.stdin.buffer.read())
    elif script == "fixture-stream":
        print(os.getpid(), flush=True)
        print("stream stderr", file=sys.stderr, flush=True)
        time.sleep(120)
    elif script.startswith("ps"):
        print("PID NAME\n42 dev.example.app:remote")
    elif script.startswith("pm"):
        print("package:dev.example.app")
    elif "__SCRCPY_MAC_DONE__" in script:
        if "dumpsys trust" in script:
            print("User \"Owner\" (current): deviceLocked=true")
        print("__SCRCPY_MAC_DONE__")
    elif "uiautomator dump" in script:
        print('<?xml version="1.0"?><hierarchy><node text="Fixture" resource-id="fixture:id/title" bounds="[0,0][10,10]"/></hierarchy>')
    else:
        print(json.dumps(rest))
elif command == "fixture-binary":
    sys.stdout.buffer.write(b"\x00\xffA\r\n")
    sys.stderr.write("separate stderr")
elif command == "fixture-flood":
    sys.stdout.write("x" * 5000)
elif command == "fixture-fail":
    print("failure output")
    print("failure stderr", file=sys.stderr)
    sys.exit(7)
elif command == "fixture-sleep":
    time.sleep(120)
elif command == "fixture-stdin":
    sys.stdout.buffer.write(sys.stdin.buffer.read())
else:
    print(json.dumps(args))
