#!/usr/bin/env python3
"""End-to-end checks for a prepared CAN Viewer running without Internet."""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

from websockets.exceptions import ConnectionClosed
from websockets.sync.client import connect


def request_json(
    url: str,
    *,
    method: str = "GET",
    body: dict[str, Any] | None = None,
    timeout: float = 5,
) -> dict[str, Any]:
    data = None if body is None else json.dumps(body).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers={"Content-Type": "application/json"} if data is not None else {},
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        assert 200 <= response.status < 300, (response.status, url)
        return json.load(response)


def wait_for_server(base_url: str, timeout: float = 20) -> None:
    deadline = time.monotonic() + timeout
    last_error: Exception | None = None
    while time.monotonic() < deadline:
        try:
            if request_json(f"{base_url}/api/v1/health") == {"status": "ok"}:
                return
        except (OSError, urllib.error.URLError, AssertionError) as error:
            last_error = error
        time.sleep(0.1)
    raise RuntimeError(f"backend did not become ready: {last_error}")


class Cdp:
    def __init__(self, debugger_url: str) -> None:
        self.socket = connect(debugger_url, open_timeout=5, legacy=True)
        self.next_id = 1
        self.events: list[dict[str, Any]] = []

    def close(self) -> None:
        self.socket.close()

    def command(self, method: str, params: dict[str, Any] | None = None) -> Any:
        identifier = self.next_id
        self.next_id += 1
        self.socket.send(
            json.dumps({"id": identifier, "method": method, "params": params or {}})
        )
        while True:
            message = json.loads(self.socket.recv(timeout=10))
            if message.get("id") == identifier:
                if "error" in message:
                    raise RuntimeError(f"CDP {method} failed: {message['error']}")
                return message.get("result", {})
            self.events.append(message)

    def collect_until(self, predicate: Any, timeout: float = 20) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                message = json.loads(self.socket.recv(timeout=0.25))
            except TimeoutError:
                continue
            self.events.append(message)
            if predicate(message):
                return
        raise RuntimeError("browser page did not finish loading")


def wait_for_debugger(port: int, timeout: float = 15) -> str:
    endpoint = f"http://127.0.0.1:{port}/json/list"
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(endpoint, timeout=1) as response:
                pages = json.load(response)
            page = next(item for item in pages if item.get("type") == "page")
            return str(page["webSocketDebuggerUrl"])
        except (OSError, urllib.error.URLError, StopIteration, KeyError):
            time.sleep(0.1)
    raise RuntimeError("Chrome DevTools endpoint did not become ready")


def browser_check(base_url: str, chrome: str, debugger_port: int) -> None:
    application = urllib.parse.urlsplit(base_url)
    application_port = application.port or (443 if application.scheme == "https" else 80)

    def is_application_origin(url: str) -> bool:
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme not in {"http", "https", "ws", "wss"}:
            return True
        expected_schemes = (
            {"https", "wss"} if application.scheme == "https" else {"http", "ws"}
        )
        port = parsed.port or (443 if parsed.scheme in {"https", "wss"} else 80)
        return (
            parsed.scheme in expected_schemes
            and parsed.hostname == application.hostname
            and port == application_port
            and parsed.username is None
            and parsed.password is None
        )

    profile = tempfile.mkdtemp(prefix="can-viewer-clean-browser-")
    try:
        process = subprocess.Popen(
            [
                chrome,
                "--headless=new",
                "--no-sandbox",
                "--disable-background-networking",
                "--disable-component-update",
                "--disable-breakpad",
                "--disable-crash-reporter",
                "--disable-default-apps",
                "--disable-sync",
                "--metrics-recording-only",
                "--no-first-run",
                "--enable-unsafe-swiftshader",
                f"--remote-debugging-port={debugger_port}",
                f"--user-data-dir={profile}",
                "about:blank",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
        )
        cdp: Cdp | None = None
        try:
            debugger_url = wait_for_debugger(debugger_port)
            cdp = Cdp(debugger_url)
            cdp.command("Network.enable")
            cdp.command("Runtime.enable")
            cdp.command("Page.enable")
            cdp.command("Page.navigate", {"url": base_url})
            cdp.collect_until(
                lambda event: event.get("method") == "Page.loadEventFired"
            )

            deadline = time.monotonic() + 20
            rendered = False
            while time.monotonic() < deadline:
                result = cdp.command(
                    "Runtime.evaluate",
                    {
                        "expression": "document.title === 'CAN Monitor' && "
                        "document.querySelectorAll('flutter-view, flt-glass-pane').length > 0",
                        "returnByValue": True,
                    },
                )
                rendered = bool(result["result"].get("value"))
                if rendered:
                    break
                time.sleep(0.2)
            assert rendered, "Flutter did not render in a clean browser profile"

            registrations = cdp.command(
                "Runtime.evaluate",
                {
                    "expression": "navigator.serviceWorker.getRegistrations()"
                    ".then(items => items.length)",
                    "awaitPromise": True,
                    "returnByValue": True,
                },
            )
            assert registrations["result"].get("value") == 0, (
                "a service worker was registered in the clean profile"
            )

            time.sleep(1)
            while True:
                try:
                    cdp.events.append(json.loads(cdp.socket.recv(timeout=0.1)))
                except TimeoutError:
                    break

            requested = {
                event["params"]["request"]["url"]
                for event in cdp.events
                if event.get("method") == "Network.requestWillBeSent"
            }
            external = sorted(
                url
                for url in requested
                if not is_application_origin(url)
            )
            assert not external, f"external browser requests found: {external}"
            bad_responses = [
                {
                    "url": event["params"]["response"]["url"],
                    "status": event["params"]["response"]["status"],
                }
                for event in cdp.events
                if event.get("method") == "Network.responseReceived"
                and event["params"]["response"]["status"] >= 400
            ]
            assert not bad_responses, f"browser resources returned errors: {bad_responses}"
            failures = [
                event["params"]
                for event in cdp.events
                if event.get("method") == "Network.loadingFailed"
                and not event["params"].get("canceled")
            ]
            assert not failures, f"required browser resources failed: {failures}"
            print(f"browser: rendered with {len(requested)} local request(s), no service worker")
        finally:
            if cdp is not None:
                cdp.close()
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
            if process.returncode not in {0, -15}:
                details = process.stderr.read() if process.stderr is not None else ""
                print(details[-2000:], file=sys.stderr)
    finally:
        for _ in range(10):
            try:
                shutil.rmtree(profile)
                break
            except OSError:
                time.sleep(0.1)
        else:
            shutil.rmtree(profile, ignore_errors=True)


def api_and_websocket_check(base_url: str) -> None:
    health = request_json(f"{base_url}/api/v1/health")
    assert health == {"status": "ok"}
    interfaces = request_json(f"{base_url}/api/v1/can/interfaces")["interfaces"]
    assert any(item["name"] == "vcan0" for item in interfaces), interfaces

    session = request_json(
        f"{base_url}/api/v1/can/sessions",
        method="POST",
        body={"interface": "vcan0", "filter": {"mode": "all", "ids": []}},
    )
    session_id = session["id"]
    websocket_url = base_url.replace("http://", "ws://", 1).replace(
        "https://", "wss://", 1
    )
    try:
        with connect(
            f"{websocket_url}/api/v1/can/sessions/{session_id}/stream",
            origin=base_url,
            open_timeout=5,
        ) as websocket:
            hello = json.loads(websocket.recv(timeout=5))
            assert hello["type"] == "hello" and hello["version"] == 1
            submitted = request_json(
                f"{base_url}/api/v1/can/sessions/{session_id}/frames",
                method="POST",
                body={"can_id": 0x123, "data_hex": "0102"},
            )
            assert submitted == {"status": "submitted"}
            batch = json.loads(websocket.recv(timeout=5))
            assert batch["type"] == "frames" and batch["frames"]
            frame = batch["frames"][0]
            assert frame["can_id"] == 0x123 and frame["data_hex"] == "0102"
    except ConnectionClosed as error:
        raise AssertionError(f"WebSocket closed unexpectedly: {error}") from error
    finally:
        request_json(
            f"{base_url}/api/v1/can/sessions/{session_id}", method="DELETE"
        )
    print("api: health, SocketCAN/vcan TX-RX and same-origin WebSocket passed")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default="http://127.0.0.1:8000")
    parser.add_argument("--chrome", required=True)
    parser.add_argument("--debugger-port", type=int, default=9222)
    arguments = parser.parse_args()
    wait_for_server(arguments.base_url)
    browser_check(arguments.base_url, arguments.chrome, arguments.debugger_port)
    api_and_websocket_check(arguments.base_url)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
