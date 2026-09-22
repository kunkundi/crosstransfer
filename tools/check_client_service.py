#!/usr/bin/env python3
"""Check a commercial native library's service policy through the public C ABI.

Build with --ct_developer=n --ct_service_host=service-policy.invalid, then pass
the library path. The reserved .invalid domain is for this offline test only.
"""
import argparse
import ctypes
import json
from pathlib import Path
import subprocess
import sys
import tempfile


SERVICE_KEYS = ("server", "link_host", "turn_mode", "ws_relay", "enable_srtp",
                "enable_upnp", "ice_timeout_ms")


def Check(library, directory):
    legacy = {
        "server": {"host": "user-override.invalid", "port": 12345, "tls": False},
        "link_host": "user-links.invalid", "turn_mode": "force", "ws_relay": "off",
        "enable_srtp": False, "enable_upnp": True, "ice_timeout_ms": 1,
        "save_dir": str(directory / "received"), "share": {"mode": "open", "ttl_sec": 1234},
        "log_level": "error",
    }
    config_file = directory / "config.json"
    config_file.write_text(json.dumps(legacy), encoding="utf-8")
    lib = ctypes.CDLL(str(library))
    lib.CtCreate.argtypes = [ctypes.c_char_p]
    lib.CtCreate.restype = ctypes.c_void_p
    lib.CtDestroy.argtypes = [ctypes.c_void_p]
    lib.CtUpdateConfig.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
    lib.CtUpdateConfig.restype = ctypes.c_int
    lib.CtQuery.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
    lib.CtQuery.restype = ctypes.c_void_p
    lib.CtFreeString.argtypes = [ctypes.c_void_p]

    def Snapshot(core):
        ptr = lib.CtQuery(core, b'{"what":"config"}')
        assert ptr, "query failed"
        try:
            return json.loads(ctypes.string_at(ptr))["config"]
        finally:
            lib.CtFreeString(ptr)

    for restart in range(2):
        core = lib.CtCreate(json.dumps({"data_dir": str(directory),
                                      "server": {"host": "caller-override.invalid"}}).encode())
        assert core, "core creation failed"
        try:
            config = Snapshot(core)
            assert config["service_available"] is True
            assert not set(config).intersection(SERVICE_KEYS), "service settings exposed by query"
            assert config["save_dir"] == legacy["save_dir"], "save directory lost during migration"
            assert config["share"]["mode"] == "open", "share mode lost during migration"
            assert config["share"]["ttl_sec"] == (600 if restart else 1234)
            for key in SERVICE_KEYS:
                rc = lib.CtUpdateConfig(core, json.dumps({key: None}).encode())
                assert rc == -1, f"managed override accepted: {key}"
            assert lib.CtUpdateConfig(core, b'{"share":{"ttl_sec":600}}') == 0
            assert Snapshot(core)["share"]["ttl_sec"] == 600  # drains async updates
            saved = json.loads(config_file.read_text(encoding="utf-8"))
            assert not set(saved).intersection(SERVICE_KEYS), "service settings persisted"
        finally:
            lib.CtDestroy(core)
    print("PASS: legacy migration, redacted query/storage, override rejection, preference persistence and restart")


def Main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("library", type=Path)
    parser.add_argument("--worker", type=Path)
    args = parser.parse_args()
    if args.worker:
        Check(args.library.resolve(), args.worker)
    else:
        # Logging is process-wide. Exit the worker before deleting its files on Windows.
        with tempfile.TemporaryDirectory(prefix="ct-service-policy-") as directory:
            subprocess.run([sys.executable, __file__, str(args.library.resolve()),
                            "--worker", directory], check=True)


if __name__ == "__main__":
    Main()
