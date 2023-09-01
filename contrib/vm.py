#!/usr/bin/env python3
import subprocess
import sys
from pathlib import Path
import os.path
import time
import json
import datetime
import typing

_VERSION = "{{VERSION}}"
_CONFIGS = os.path.join(str(Path.home()), ".vms")
_GET_TIME = json.dumps({"execute": "guest-get-time"}).encode("utf-8")
_TIME_SCREEN = "vm-time"
_ZSH_COMPLETION = """
#compdef _vm vm
 
_vm() { 
  local curcontext="$curcontext" state len
  typeset -A opt_args

  _arguments \
    '1: :->main'\
    '*: :->args'

  len=${#words[@]}
  case $state in
    main)
      _arguments '1:main:(start status version)'
    ;;
    *)
      case $words[2] in
        "status" | "start")
          compadd "$@" $(vm ls)
        ;;
      esac
  esac
}
"""


def _status(name: str) -> bool:
    result = subprocess.run(['screen', '-list'], stdout=subprocess.PIPE)
    search = ".{}".format(name)
    for item in result.stdout.decode("utf-8").split("\n"):
        if search in item.strip():
            return True
    return False


def _init(name: str) -> None:
    path = os.path.join(_CONFIGS, name)
    config_file = os.path.join(path, "config.json")
    subprocess.run(["vfu", "--config", config_file], cwd=path)


def _time() -> None:
    while True:
        ips: list[str] = []
        with open("/var/db/dhcpd_leases", "r") as f:
            for l in f.read().split("\n"):
                if "ip_address=" in l:
                    parts = l.split("=")
                    if len(parts) > 1:
                        ips.append(parts[1])
        ns_now = time.time_ns()
        j: typing.Dict[str, typing.Any] = {}
        j["execute"] = "guest-set-time"
        j["arguments"] = {"time": ns_now}
        cmd = json.dumps(j).encode("utf-8")
        for ip in ips:
            nc = ["nc", "-G", "1", ip, "9999"]
            update = True
            try:
                res = subprocess.Popen(nc,
                                       stdout=subprocess.PIPE,
                                       stdin=subprocess.PIPE)
                comm = res.communicate(input=_GET_TIME)
                data = comm[0].decode("utf-8")
                loaded = json.loads(data)
                if "return" in loaded:
                    guest_time = loaded["return"]
                diff = abs(ns_now - guest_time) / 1000000000
                if diff < 30:
                    update = False
                else:
                    print(datetime.datetime.now())
                    print("setting time for {} ({} seconds)".format(ip, diff))
            except:
                pass
            if update:
                res = subprocess.Popen(nc,
                                       stdout=subprocess.PIPE,
                                       stdin=subprocess.PIPE)
                out = res.communicate(input=cmd)[0]
                if out:
                    print(out)
        time.sleep(15)


def _start_screen(name: str, command: str, args: list[str]) -> None:
    subprocess.run(["screen", "-S", name, "-d", "-m", "vm", command] + args)


def _manage_time() -> None:
    if _status(_TIME_SCREEN):
        return
    print("starting time manager")
    _start_screen(_TIME_SCREEN, "time", [])


def _start(name: str) -> None:
    if _status(name):
        return
    print("\nstarting {}...\n".format(name))
    _manage_time()
    _start_screen(name, "init", [name])


def _usage() -> None:
    print("vm <command> <vm>")
    exit(1)


def _ls() -> None:
    for d in os.listdir(_CONFIGS):
        if d.startswith("."):
            continue
        print(d)


def main() -> None:
    args = sys.argv
    if len(args) <= 1:
        _usage()
    cmd = args[1]
    if cmd == "ls":
        _ls()
        return
    elif cmd == "time":
        _time()
        return
    elif cmd == "zsh":
        print(_ZSH_COMPLETION.strip())
        return
    elif cmd == "version":
        print(_VERSION)
        return
    if len(args) != 3:
        _usage()
    vm = args[2]
    if cmd == "start":
        _start(vm)
    elif cmd == "init":
        _init(vm)
    elif cmd == "status":
        if _status(vm):
            print("running")
        else:
            print("stopped")
    else:
        _usage()


if __name__ == "__main__":
    main()
