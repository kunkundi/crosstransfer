#!/usr/bin/env python3
"""Verify an already-built ctserver image using an isolated local container."""
import argparse
import http.client
import io
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import time
import uuid


def Docker(*args):
    return subprocess.check_output(["docker", *args], text=True).strip()


def Main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", nargs="?", default="crosstransfer/ctserver:local")
    args = parser.parse_args()
    name = "ctserver-check-" + uuid.uuid4().hex[:12]
    volume = name + "-acme"
    try:
        with tempfile.TemporaryDirectory(prefix=name) as directory:
            root = Path(directory)
            root.chmod(0o755)
            (root / "config.yaml").write_text(
                'listen: ":8097"\nturn_port: 0\nassociation_dir: /fixtures\n'
                'download_url: "https://example.test/releases"\n', encoding="utf-8")
            fixtures = {"apple-app-site-association": {"applinks": {"details": []}},
                        "assetlinks.json": []}
            for filename, body in fixtures.items():
                (root / filename).write_text(json.dumps(body), encoding="utf-8")
            for path in root.iterdir():
                path.chmod(0o644)
            Docker("volume", "create", "--label", "com.crosstransfer.test=server", volume)
            Docker("run", "-d", "--name", name, "--read-only", "--cap-drop=ALL",
                   "--security-opt=no-new-privileges", "-p", "127.0.0.1::8097",
                   "-e", "CT_CONFIG=/fixtures/config.yaml",
                   "--mount", f"type=bind,src={root},dst=/fixtures,readonly",
                   "--mount", f"type=volume,src={volume},dst=/var/lib/ctserver/acme",
                   args.image)
            port = int(Docker("port", name, "8097/tcp").rsplit(":", 1)[1])
            deadline = time.monotonic() + 20
            while True:
                probe = subprocess.run(["docker", "exec", name, "/ctserver", "-healthz"],
                                       capture_output=True)
                if probe.returncode == 0:
                    break
                if time.monotonic() >= deadline:
                    raise AssertionError("YAML-configured container never became healthy")
                time.sleep(0.2)

            def Get(path):
                conn = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
                try:
                    conn.request("GET", path)
                    response = conn.getresponse()
                    return response.status, dict(response.getheaders()), response.read()
                finally:
                    conn.close()

            status, _, body = Get("/healthz")
            assert status == 200 and json.loads(body)["ok"]
            status, headers, body = Get("/r/mxt3x-f8sk2")
            assert status == 200 and b"crosstransfer://r/MXT3XF8SK2" in body
            assert headers["Cache-Control"] == "no-store"
            assert headers["Referrer-Policy"] == "no-referrer"
            assert Get("/r/%3Cscript%3E")[0] == 400
            status, headers, _ = Get("/download?next=https://attacker.test")
            assert status == 303 and headers["Location"] == "https://example.test/releases"
            for filename, expected in fixtures.items():
                status, headers, body = Get("/.well-known/" + filename)
                assert status == 200 and json.loads(body) == expected
                assert headers["Content-Type"] == "application/json"
            assert Get("/.well-known/config.yaml")[0] == 404
            assert Get("/metrics")[0] == 404

            # Check named-volume initialization retains the nonroot user's ownership.
            archive = subprocess.check_output(["docker", "cp", name + ":/var/lib/ctserver/acme", "-"])
            with tarfile.open(fileobj=io.BytesIO(archive)) as stream:
                directory_info = next(item for item in stream.getmembers() if item.isdir())
                assert (directory_info.uid, directory_info.gid) == (65532, 65532)
                assert directory_info.mode & 0o700 == 0o700
            user = Docker("inspect", "--format", "{{.Config.User}}", name)
            assert user in ("nonroot:nonroot", "65532:65532")
            print("PASS: nonroot/read-only container, YAML healthcheck, landing/download, "
                  "association allowlist, private metrics, ACME volume ownership")
    except Exception:
        subprocess.run(["docker", "logs", name], check=False)
        raise
    finally:
        subprocess.run(["docker", "rm", "-f", name], capture_output=True)
        subprocess.run(["docker", "volume", "rm", volume], capture_output=True)


if __name__ == "__main__":
    Main()
