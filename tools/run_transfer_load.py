#!/usr/bin/env python3
"""Isolated concurrent CLI transfers over trusted WSS signaling (macOS/Linux).

Every case owns its server and clients, temporary CA, state and payloads. The
TURN case explicitly enables loopback peers. No system trust store is changed.
Results are local-loopback regression measurements, not public-network capacity.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import socket
import ssl
import subprocess
import tempfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def Hash(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while block := stream.read(1 << 20):
            digest.update(block)
    return digest.hexdigest()


def FreePort(kind=socket.SOCK_STREAM):
    with socket.socket(socket.AF_INET, kind) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def Events(path):
    for line in path.read_text(errors="replace").splitlines():
        if line.startswith("{"):
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                pass


def CreateCA(work, openssl):
    def Run(*args):
        subprocess.run([openssl, *args], cwd=work, check=True, capture_output=True)
    (work / "root.cnf").write_text(
        "[req]\ndistinguished_name=dn\nx509_extensions=ca\n[dn]\n[ca]\n"
        "basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n"
        "subjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid:always\n")
    Run("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "root.key",
        "-out", "root.pem", "-days", "1", "-subj", "/CN=CrossTransfer Load Test CA", "-config", "root.cnf")
    Run("req", "-newkey", "rsa:2048", "-nodes", "-keyout", "server.key",
        "-out", "server.csr", "-subj", "/CN=CrossTransfer Local Test")
    (work / "server.ext").write_text(
        "basicConstraints=critical,CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\n"
        "extendedKeyUsage=serverAuth\nsubjectAltName=IP:127.0.0.1\n"
        "subjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid,issuer\n")
    Run("x509", "-req", "-in", "server.csr", "-CA", "root.pem", "-CAkey", "root.key",
        "-CAcreateserial", "-out", "server.pem", "-days", "1", "-extfile", "server.ext")


def RunCase(args, work, server, source, expected, name):
    case = work / name
    case.mkdir()
    processes, handles = {}, []
    peak_rss, peak_metrics = {}, {}
    metrics = {}
    port = FreePort()
    endpoint = f"127.0.0.1:{port}"
    context = ssl.create_default_context(cafile=str(work / "root.pem"))
    # Ignore ambient CT_* config and test packet-drop injection for reproducibility.
    env = {k: v for k, v in os.environ.items() if not k.startswith(("CT_", "MINIRTC_TEST_"))}
    env["SSL_CERT_FILE"] = str(work / "root.pem")
    rate = args.relay_rate if name == "relay-limited" else 0
    service_env = dict(env, CT_LISTEN=endpoint, CT_TURN_PORT="0", CT_LOG_LEVEL="error",
                       CT_TLS_CERT=str(work / "server.pem"), CT_TLS_KEY=str(work / "server.key"),
                       CT_METRICS="true", CT_CLAIM_BURST_PER_IP=str(args.receivers + 1),
                       CT_RELAY_RATE_LIMIT=str(rate))
    if name == "turn":
        service_env.update(CT_TURN_PORT=str(FreePort(socket.SOCK_DGRAM)),
                           CT_PUBLIC_IP="127.0.0.1", CT_TURN_ALLOW_PRIVATE_PEERS="true",
                           CT_TURN_SECRET="isolated-load-test-only")

    def Start(label, command, process_env=env):
        log = (case / f"{label}.log").open("w")
        handles.append(log)
        process = subprocess.Popen(command, cwd=case, env=process_env, stdout=log, stderr=subprocess.STDOUT)
        processes[label] = process
        return process

    def Metrics():
        with urllib.request.urlopen(f"https://{endpoint}/metrics", context=context, timeout=3) as response:
            values = {}
            for line in response.read().decode().splitlines():
                if line and not line.startswith("#"):
                    key, value = line.split()
                    values[key] = int(value)
            return values

    def Sample():
        nonlocal metrics
        alive = {process.pid: label for label, process in processes.items() if process.poll() is None}
        if alive:
            sample = subprocess.run(["ps", "-o", "pid=,rss=", "-p", ",".join(map(str, alive))],
                                    capture_output=True, text=True)
            for line in sample.stdout.splitlines():
                pid, rss = map(int, line.split())
                label = alive[pid]
                peak_rss[label] = max(peak_rss.get(label, 0), rss * 1024)
        metrics = Metrics()
        for key, value in metrics.items():
            peak_metrics[key] = max(peak_metrics.get(key, 0), value)

    try:
        service = Start("server", [str(server)], service_env)
        ready_deadline = time.monotonic() + 15
        while True:
            if service.poll() is not None:
                raise RuntimeError("server exited")
            try:
                metrics = Metrics()
                break
            except OSError:
                if time.monotonic() > ready_deadline:
                    raise TimeoutError("server startup timed out")
                time.sleep(0.1)
        common = ["--server", endpoint, "--tls", "--json", "--log-level", "warn",
                  "--timeout", str(args.timeout), "--turn", "force" if name == "turn" else "off",
                  "--relay", "force" if name.startswith("relay") else "off"]
        sender = Start("sender", [str(args.cli), "share", str(source), "--mode", "open",
                                  "--wait", str(args.receivers), "--ttl", str(args.timeout + 60),
                                  "--data-dir", str(case / "sender-state"), *common])
        share_deadline = time.monotonic() + 20
        code = None
        while code is None:
            code = next((event["code"] for event in Events(case / "sender.log")
                         if event.get("type") == "share_state" and event.get("state") == "ready"), None)
            if sender.poll() is not None or time.monotonic() > share_deadline:
                raise RuntimeError("sender failed before share registration")
            if code is None:
                time.sleep(0.1)
        started = time.monotonic()
        for index in range(args.receivers):
            label = f"receiver-{index}"
            Start(label, [str(args.cli), "receive", code, "--dir", str(case / label),
                          "--data-dir", str(case / (label + "-state")), *common])
        while True:
            Sample()
            for label, process in processes.items():
                if process.poll() not in (None, 0):
                    raise RuntimeError(f"{label} exited with {process.returncode}")
            if all(process.poll() == 0 for label, process in processes.items() if label != "server"):
                break
            if time.monotonic() - started > args.timeout + 10:
                raise TimeoutError(f"{name} concurrent transfer timed out")
            time.sleep(0.2)
        elapsed = time.monotonic() - started
        expected_path = "relay" if name.startswith("relay") else name
        for index in range(args.receivers):
            label = f"receiver-{index}"
            received = case / label / source.name
            actual = {str(path.relative_to(received)): Hash(path) for path in received.rglob("*") if path.is_file()}
            assert actual == expected, f"{label}: received files differ from source"
            assert (received / "子目录" / "empty_dir").is_dir(), "empty directory lost"
            completed = [event for event in Events(case / (label + ".log"))
                         if event.get("type") == "transfer_state" and event.get("state") == "completed"]
            assert len(completed) == 1 and completed[0]["path"] == expected_path, f"{label}: wrong transfer path"
        sender_completions = [event for event in Events(case / "sender.log")
                              if event.get("type") == "transfer_state" and event.get("state") == "completed"]
        assert len(sender_completions) == args.receivers, "sender did not acknowledge every receiver"
        assert all(event["path"] == expected_path for event in sender_completions), "sender reported wrong data path"
        deadline = time.monotonic() + 5
        while True:
            Sample()
            if metrics["ct_peers"] == metrics["ct_shares"] == metrics["ct_sessions"] == 0:
                break
            if time.monotonic() > deadline:
                raise AssertionError("server retained disconnected peers/shares/sessions")
            time.sleep(0.1)
        assert metrics["ct_claims_ok_total"] == args.receivers
        assert metrics["ct_claims_rate_limited_total"] == 0
        assert peak_metrics["ct_sessions"] == args.receivers, "test did not overlap every receiver"
        if name == "turn":
            assert peak_metrics["ct_turn_allocations"] > 0, "no actual TURN allocations"
        assert (metrics["ct_relay_bytes_total"] > 0) == name.startswith("relay"), "wrong server data route"
        if name == "relay-limited":
            assert metrics["ct_relay_dropped_total"] > 0, "load did not exercise relay rate limiting"
        total_bytes = sum(path.stat().st_size for path in source.rglob("*") if path.is_file()) * args.receivers
        result = dict(case=name, receivers=args.receivers, verified_bytes=total_bytes,
                      elapsed_seconds=round(elapsed, 3), aggregate_mib_per_second=round(total_bytes / elapsed / (1 << 20), 3),
                      peak_rss_bytes=peak_rss, peak_metrics=peak_metrics, final_metrics=metrics,
                      relay_rate_bytes_per_second=rate)
        print(json.dumps(result, ensure_ascii=False), flush=True)
        return result
    except BaseException:
        for log in case.glob("*.log"):
            print(log.name, log.read_text(errors="replace")[-6000:], flush=True)
        if args.output:
            logs = args.output.parent / (args.output.stem + "-failure-logs")
            logs.mkdir(parents=True, exist_ok=True)
            for log in case.glob("*.log"):
                shutil.copy2(log, logs / (name + "-" + log.name))
        raise
    finally:
        for process in reversed(list(processes.values())):
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
        for handle in handles:
            handle.close()
        # Avoid retaining N payload copies across cases on constrained CI runners.
        shutil.rmtree(case)


def Main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", type=Path, required=True)
    parser.add_argument("--openssl", default="openssl")
    parser.add_argument("--receivers", type=int, default=4)
    parser.add_argument("--mib", type=int, default=16, help="payload MiB per receiver")
    parser.add_argument("--timeout", type=int, default=180)
    parser.add_argument("--relay-rate", type=int, default=1024 * 1024)
    parser.add_argument("--cases", nargs="+", default=["p2p", "turn", "relay", "relay-limited"],
                        choices=["p2p", "turn", "relay", "relay-limited"])
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if os.name == "nt" or not 2 <= args.receivers <= 32 or not 1 <= args.mib <= 1024:
        parser.error("requires macOS/Linux, 2–32 receivers, 1–1024 MiB")
    if args.timeout < 30 or args.relay_rate <= 0:
        parser.error("timeout must be >=30 seconds; relay rate must be positive")
    args.cli = args.cli.resolve(strict=True)
    if args.output:
        args.output = args.output.resolve()
        args.output.parent.mkdir(parents=True, exist_ok=True)
    report = dict(environment=platform.platform(), sample_interval_seconds=0.2,
                  transport="trusted WSS signaling, local loopback data paths", results=[])
    with tempfile.TemporaryDirectory(prefix="ct-load-") as directory:
        work = Path(directory)
        CreateCA(work, args.openssl)
        server = work / "ctserver"
        subprocess.run(["go", "build", "-o", str(server), "./cmd/ctserver"], cwd=ROOT / "server", check=True)
        source = work / "source-tree"
        (source / "子目录" / "empty_dir").mkdir(parents=True)
        with (source / "子目录" / "payload.bin").open("wb") as stream:
            for _ in range(args.mib):
                stream.write(os.urandom(1 << 20))
            stream.write(os.urandom(37))
        (source / "zero.bin").write_bytes(b"")
        (source / "中文 文件.txt").write_bytes(os.urandom(777))
        expected = {str(path.relative_to(source)): Hash(path) for path in source.rglob("*") if path.is_file()}
        for name in args.cases:
            report["results"].append(RunCase(args, work, server, source, expected, name))
            if args.output:
                args.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    print("PASS: concurrent file hashes, actual data routes and peer/share/session cleanup", flush=True)


if __name__ == "__main__":
    Main()
