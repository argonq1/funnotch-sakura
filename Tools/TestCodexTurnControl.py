"""Isolated router fixtures. No real Codex chat is interrupted by this suite."""
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import threading

binary = str(Path(sys.argv[1]).resolve())
errors = []


def run_case(name, expected, behavior):
    with tempfile.TemporaryDirectory(prefix="fn-stop-", dir="/tmp") as folder:
        endpoint = str(Path(folder) / "ipc.sock")
        server = socket.socket(socket.AF_UNIX)
        server.bind(endpoint)
        os.chmod(endpoint, 0o600)
        server.listen(1)
        server.settimeout(4)
        issues = []

        def serve():
            try:
                with server.accept()[0] as peer:
                    peer.settimeout(4)

                    def read(count):
                        out = b""
                        while len(out) < count:
                            data = peer.recv(count - len(out))
                            if not data:
                                raise EOFError()
                            out += data
                        return out

                    def receive():
                        return json.loads(read(struct.unpack("<I", read(4))[0]))

                    def send(obj):
                        body = json.dumps(obj, ensure_ascii=False).encode()
                        frame = struct.pack("<I", len(body)) + body
                        # Fragment the header and body to exercise stream framing.
                        for i in range(0, len(frame), 3):
                            peer.sendall(frame[i:i + 3])

                    def reply(request, result):
                        send(dict(type="response", requestId=request["requestId"], resultType="success",
                                  method=request["method"], handledByClientId="owner", result=result))

                    init = receive()
                    assert init["method"] == "initialize"
                    assert init["params"]["clientType"] == "funnotch"
                    if behavior == "oversized":
                        peer.sendall(struct.pack("<I", 0x7fffffff))
                        return
                    if behavior == "closed":
                        return
                    reply(init, {"clientId": "funnotch-client"})
                    owner = receive()
                    assert owner["method"] == "thread-owner-discovery" and owner["version"] == 1
                    assert owner["params"] == dict(hostId="local", conversationId="00000000-0000-4000-8000-000000000001")
                    if behavior == "no-owner":
                        send(dict(type="response", requestId=owner["requestId"], resultType="error", error="no-client-found"))
                        return
                    # The client refuses discovery requests, and ignores broadcasts.
                    send(dict(type="broadcast", method="unrelated", params={}))
                    send(dict(type="client-discovery-request", requestId="discover-client", request={}))
                    refusal = receive()
                    assert refusal == dict(type="client-discovery-response", requestId="discover-client", response={"canHandle": False})
                    reply(owner, {"supportsUntrustedAppInput": True})
                    stop = receive()
                    assert stop["method"] == "thread-follower-interrupt-turn" and stop["version"] == 4
                    assert stop["sourceClientId"] == "funnotch-client" and stop["targetClientId"] == "owner"
                    assert stop["params"] == dict(conversationId="00000000-0000-4000-8000-000000000001",
                                                  mode="user-stop", expectedTurnId="turn-visible-at-click")
                    if behavior == "rejected":
                        send(dict(type="response", requestId=stop["requestId"], resultType="error", error="request-version-mismatch"))
                        return
                    interrupted = None if behavior == "stale" else "wrong-turn" if behavior == "wrong-turn" else "turn-visible-at-click"
                    reply(stop, dict(ok=behavior != "not-ok", interruptedTurnId=interrupted))
                    # No retries or additional commands after the result.
                    assert peer.recv(1) == b""
            except Exception as error:
                issues.append(repr(error))
            finally:
                server.close()

        worker = threading.Thread(target=serve)
        worker.start()
        outcome = subprocess.run([binary, endpoint, expected, name], text=True, capture_output=True, timeout=15)
        worker.join(5)
        print(outcome.stdout.strip() or outcome.stderr.strip())
        if outcome.returncode or issues or worker.is_alive():
            errors.append((name, outcome.returncode, issues))


run_case("exact thread/turn routed to owner, fragmented frames", "stopped", "ok")
run_case("completed or replaced turn never retries against newer reply", "stale", "stale")
run_case("missing owner is an error", "error", "no-owner")
run_case("version mismatch is an error", "error", "rejected")
run_case("oversized frame rejected before allocation", "error", "oversized")
run_case("disconnected peer is an error", "error", "closed")
run_case("wrong interrupted turn is not success", "error", "wrong-turn")
run_case("negative acknowledgment is not success", "error", "not-ok")

with tempfile.TemporaryDirectory(prefix="fn-stop-", dir="/tmp") as folder:
    endpoint = str(Path(folder) / "ipc.sock")
    peer = socket.socket(socket.AF_UNIX)
    peer.bind(endpoint)
    os.chmod(endpoint, 0o666)
    outcome = subprocess.run([binary, endpoint, "error", "other-user-accessible socket refused"], text=True, capture_output=True)
    print(outcome.stdout.strip())
    if outcome.returncode:
        errors.append(("unsafe socket", outcome.returncode))
    peer.close()

if errors:
    print(errors)
    sys.exit(1)
print("All 9 Codex stop transport checks passed")
