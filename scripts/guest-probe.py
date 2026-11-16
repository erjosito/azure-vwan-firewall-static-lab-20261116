import datetime
import json
import os
import socket
import subprocess
import sys
import time

design, source, phase = sys.argv[1:]
addresses = {"trusted-a": "10.10.0.4", "trusted-b": "10.20.0.4", "untrusted-a": "10.30.0.4"}


def emit(value):
    print(json.dumps(value, separators=(",", ":")), flush=True)


if phase == "prepare":
    subprocess.run(["cloud-init", "status", "--wait"], check=True, stdout=subprocess.DEVNULL)
    subprocess.run(["systemctl", "is-active", "--quiet", "fw177-echo"], check=True)
    emit({"kind": "guest-routes", "source": source, "design": design,
          "utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
          "routes": json.loads(subprocess.check_output(["ip", "-j", "route"]))})
    for protocol, port in [("tcp", 18080), ("tcp", 18081), ("udp", 18082), ("udp", 18083)]:
        kind = socket.SOCK_STREAM if protocol == "tcp" else socket.SOCK_DGRAM
        nonce = f"self:{design}:{source}:{port}".encode()
        with socket.socket(socket.AF_INET, kind) as client:
            client.settimeout(3)
            client.connect(("127.0.0.1", port))
            client.send(nonce)
            if client.recv(256) != nonce:
                raise RuntimeError("Local echo positive control failed")
    emit({"kind": "local-controls", "source": source, "allFourPortsReady": True})
elif phase == "probe":
    for target, address in addresses.items():
        if target == source:
            continue
        for protocol, port in [("tcp", 18080), ("tcp", 18081), ("udp", 18082), ("udp", 18083)]:
            kind = socket.SOCK_STREAM if protocol == "tcp" else socket.SOCK_DGRAM
            nonce = f"{design}:{source}:{target}:{port}:{time.time_ns()}".encode()
            started = datetime.datetime.now(datetime.timezone.utc).isoformat()
            with socket.socket(socket.AF_INET, kind) as client:
                client.settimeout(4)
                client.bind((addresses[source], 0))
                local_port = client.getsockname()[1]
                result = {"kind": "probe", "design": design, "source": source, "target": target,
                          "protocol": protocol, "sourcePort": local_port, "destinationPort": port,
                          "utc": started, "nonce": nonce.decode()}
                try:
                    client.connect((address, port))
                    client.send(nonce)
                    result["echo"] = client.recv(256) == nonce
                except OSError as error:
                    result.update(echo=False, error=type(error).__name__)
                emit(result)
elif phase == "receipts":
    if os.path.exists("/var/log/fw177-receipts.jsonl"):
        with open("/var/log/fw177-receipts.jsonl") as stream:
            for line in stream:
                receipt = json.loads(line)
                if receipt["nonce"].startswith(design + ":"):
                    emit({"kind": "receipt", "endpoint": source, **receipt})
else:
    raise ValueError("Unsupported phase")
