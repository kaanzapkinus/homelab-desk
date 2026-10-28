#!/usr/bin/python3
"""Native recovery ownership and maintenance; lock inode is never removed.

flock is released by the kernel, not by guessing whether a PID is stale. The Node
session also executes its commands, retaining ownership if its client disappears.
"""
import argparse
import contextlib
import contextvars
import fcntl
import json
import math
import os
from pathlib import Path
import select
import socket
import subprocess
import stat
import sys
import tempfile
import time

DEFAULT_MAINTENANCE = str(Path(__file__).with_name("maintenance.json"))
ACTIVE_FD = contextvars.ContextVar("lifecycle_owner_fd", default=None)


def boot_identity():
    if sys.platform == "darwin":
        return subprocess.check_output(["/usr/sbin/sysctl", "-n", "kern.bootsessionuuid"],
                                       timeout=3, text=True).strip()
    return Path("/proc/sys/kernel/random/boot_id").read_text().strip()


def data_directory():
    override = os.environ.get("HOMELAB_ORBSTACK_DATA_DIR")
    if override is not None:
        directory = override
    else:
        config = os.environ.get("HOMELAB_ORBSTACK_CONFIG", str(Path.home() / ".orbstack/vmconfig.json"))
        with open(config, encoding="utf-8") as handle:
            directory = json.load(handle).get("data_dir")
    if not isinstance(directory, str) or not os.path.isabs(directory):
        raise RuntimeError("OrbStack configured data_dir missing or not absolute; start prohibited")
    return directory


def atomic_write_json(path, data):
    parent = str(Path(path).parent)
    fd, temporary = tempfile.mkstemp(prefix=".lifecycle-", dir=parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(data, handle, allow_nan=False)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        directory = os.open(parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temporary)


def read_maintenance(path=DEFAULT_MAINTENANCE, now=None):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, encoding="utf-8") as handle:
            info = os.fstat(handle.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_size > 65536:
                raise ValueError("maintenance must be a bounded regular file")
            record = json.load(handle)
    except FileNotFoundError:
        return {"active": False, "state": "clear", "reason": ""}
    except (OSError, ValueError):
        return {"active": True, "state": "maintenance-invalid", "reason": "maintenance unreadable or corrupt; operator required"}
    valid = (isinstance(record, dict) and isinstance(record.get("active"), bool)
             and all(isinstance(record.get(key), str) and record[key].strip()
                     for key in ("scope", "owner", "reason"))
             and all(isinstance(record.get(key), (float, int)) and not isinstance(record[key], bool)
                     and math.isfinite(record[key]) and record[key] >= 0
                     for key in ("since", "deadline"))
             and record["deadline"] > record["since"])
    if not valid:
        return {"active": True, "state": "maintenance-invalid", "reason": "maintenance schema invalid; operator required"}
    state = "clear"
    if record["active"]:
        state = "maintenance-expired" if record["deadline"] <= (time.time() if now is None else now) else "maintenance"
    return dict(record, state=state)


class OwnershipBusy(RuntimeError):
    pass


class Ownership:
    def __init__(self, maintenance_file=DEFAULT_MAINTENANCE):
        self.maintenance_file = maintenance_file
        self.fd = None

    def __enter__(self):
        self.fd = os.open(self.maintenance_file + ".lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BaseException:
            os.close(self.fd)
            self.fd = None
            raise OwnershipBusy("recovery operation already owned")
        self.context_token = ACTIVE_FD.set(self.fd)
        return self

    def __exit__(self, _kind, error, _trace):
        if self.fd is not None:
            if not getattr(error, "preserve_ownership", False):
                fcntl.flock(self.fd, fcntl.LOCK_UN)
            os.close(self.fd)
            ACTIVE_FD.reset(self.context_token)
            self.fd = None

    def check(self, deadline_ms=None):
        if self.fd is None:
            raise RuntimeError("recovery ownership not held")
        maintenance = read_maintenance(self.maintenance_file)
        if maintenance["active"]:
            raise RuntimeError(maintenance["state"] + ": " + maintenance["reason"])
        if deadline_ms is not None and (not math.isfinite(deadline_ms) or time.time() * 1000 >= deadline_ms):
            raise RuntimeError("job deadline exceeded")


def session(maintenance_file, deadline_ms):
    with Ownership(maintenance_file) as owner, tempfile.TemporaryDirectory(prefix="homelab-lifecycle-") as directory:
        owner.check(deadline_ms)
        endpoint = os.path.join(directory, "command.sock")
        with socket.socket(socket.AF_UNIX) as server:
            server.bind(endpoint)
            server.listen(1)
            print(json.dumps({"socket": endpoint}), flush=True)
            while True:
                ready, _, _ = select.select([server, sys.stdin], [], [])
                if sys.stdin in ready and not sys.stdin.buffer.read(1):
                    return
                if server not in ready:
                    continue
                with server.accept()[0] as client:
                    client.settimeout(5)
                    stuck_child = None
                    try:
                        raw = b""
                        while not raw.endswith(b"\n"):
                            part = client.recv(65536)
                            if not part or len(raw) > 1048576:
                                raise RuntimeError("invalid command request")
                            raw += part
                        request = json.loads(raw)
                        owner.check(deadline_ms)
                        timeout = min(float(request["timeout"]) / 1000, (deadline_ms - time.time() * 1000) / 1000)
                        # File-backed output cannot hang on pipe-inheriting descendants.
                        # Inherit flock into the CLI: even an unexpected session exit
                        # cannot make a still-live mutating command appear stale.
                        with tempfile.TemporaryFile() as output:
                            child = subprocess.Popen(request["args"], stdin=subprocess.DEVNULL,
                                                     stdout=output, stderr=subprocess.STDOUT, pass_fds=(owner.fd,))
                            try:
                                code = child.wait(timeout=max(.001, timeout))
                            except subprocess.TimeoutExpired:
                                with contextlib.suppress(ProcessLookupError):
                                    child.kill()  # CLI only; never a VM/process-group kill.
                                try:
                                    child.wait(timeout=1)
                                except subprocess.TimeoutExpired:
                                    stuck_child = child
                                    raise RuntimeError("CLI did not exit after kill; ownership retained; operator required")
                                raise RuntimeError("command deadline exceeded")
                            output.seek(0)
                            text = output.read(1048576).decode("utf-8", errors="replace")
                        response = {"code": code, "output": text}
                    except Exception as error:
                        response = {"code": 1, "output": str(error)}
                    with contextlib.suppress(BrokenPipeError, ConnectionResetError):
                        client.sendall(json.dumps(response).encode() + b"\n")
                    if stuck_child is not None:
                        # The request has already returned its deadline error.
                        # This detached safety holder does no further work, and
                        # cannot release ownership while its CLI is still alive.
                        while stuck_child.poll() is None:
                            time.sleep(1)
                        return


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--maintenance-file", default=os.environ.get("HOMELAB_MAINTENANCE_FILE", DEFAULT_MAINTENANCE))
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("status")
    commands.add_parser("data-dir")
    begin = commands.add_parser("begin")
    for field in ("scope", "owner", "reason"):
        begin.add_argument("--" + field, required=True)
    begin.add_argument("--deadline", type=float, required=True, help="Unix epoch seconds; expiry never clears maintenance")
    end = commands.add_parser("end")
    end.add_argument("--owner", required=True)
    serve = commands.add_parser("session")
    serve.add_argument("--deadline-ms", type=float, required=True)
    command = commands.add_parser("exec")
    command.add_argument("--socket", required=True)
    command.add_argument("--request", required=True)
    args = parser.parse_args()
    if args.command == "status":
        print(json.dumps(read_maintenance(args.maintenance_file)))
    elif args.command == "data-dir":
        print(data_directory())
    elif args.command == "session":
        session(args.maintenance_file, args.deadline_ms)
    elif args.command == "exec":
        with socket.socket(socket.AF_UNIX) as client:
            client.connect(args.socket)
            client.sendall(args.request.encode() + b"\n")
            response = b""
            while not response.endswith(b"\n"):
                part = client.recv(65536)
                if not part:
                    raise RuntimeError("lifecycle session disappeared")
                response += part
            result = json.loads(response)
            print(result["output"], end="")
            sys.exit(result["code"])
    else:
        with Ownership(args.maintenance_file):
            record = read_maintenance(args.maintenance_file)
            if args.command == "begin":
                if record["active"]:
                    raise RuntimeError("maintenance already active or invalid; resolve explicitly first")
                now = time.time()
                if not all(getattr(args, key).strip() for key in ("scope", "owner", "reason")) or not math.isfinite(args.deadline) or args.deadline <= now:
                    raise RuntimeError("maintenance needs nonempty scope/owner/reason and future deadline")
                atomic_write_json(args.maintenance_file, {"active": True, "scope": args.scope,
                    "owner": args.owner, "since": now, "reason": args.reason, "deadline": args.deadline})
            else:
                if record["state"] == "maintenance-invalid":
                    raise RuntimeError("invalid maintenance must be repaired by operator before end")
                if record["active"] and record["owner"] != args.owner:
                    raise RuntimeError("maintenance owner does not match")
                if record["active"]:
                    atomic_write_json(args.maintenance_file, dict(record, active=False))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
