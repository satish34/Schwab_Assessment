#!/usr/bin/env python3
"""Minimal, no-log GCE metadata token endpoint for local Grafana evidence."""

from __future__ import annotations

import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlsplit


PROJECT_ID = os.environ.get("METADATA_PROJECT_ID", "")
PROJECT_NUMBER = os.environ.get("METADATA_PROJECT_NUMBER", "")
SERVICE_ACCOUNT = os.environ.get("METADATA_SERVICE_ACCOUNT", "")
LISTEN_PORT = int(os.environ.get("METADATA_LISTEN_PORT", "80"))


def fail(message: str) -> None:
    print(f"metadata-stub: {message}", file=sys.stderr)
    raise SystemExit(1)


def read_runtime_credential() -> tuple[str, int]:
    credential_file = os.environ.get("METADATA_CREDENTIAL_FILE", "")
    credential_stream = (
        open(credential_file, encoding="utf-8") if credential_file else sys.stdin
    )
    try:
        token = credential_stream.readline().strip()
        expiry_text = credential_stream.readline().strip()
    finally:
        if credential_file:
            credential_stream.close()
    if len(token) < 20:
        fail("a non-empty short-lived access token is required on standard input")
    try:
        expiry_epoch = int(expiry_text)
    except ValueError:
        fail("a numeric token expiry is required on standard input")
    if expiry_epoch <= int(time.time()):
        fail("the supplied access token is already expired")
    return token, expiry_epoch


def metadata_value(path: str, token: str, expiry_epoch: int) -> tuple[int, str, bytes]:
    prefix = "/computeMetadata/v1/"
    if not path.startswith(prefix):
        return 404, "text/plain; charset=utf-8", b"not found\n"

    suffix = unquote(path[len(prefix) :]).rstrip("/")
    if suffix == "project/project-id":
        return 200, "text/plain; charset=utf-8", PROJECT_ID.encode()
    if suffix == "project/numeric-project-id":
        return 200, "text/plain; charset=utf-8", PROJECT_NUMBER.encode()
    if suffix == "instance/zone":
        value = f"projects/{PROJECT_NUMBER}/zones/us-central1-a"
        return 200, "text/plain; charset=utf-8", value.encode()
    if suffix == "instance/service-accounts":
        value = f"default/\n{SERVICE_ACCOUNT}/\n"
        return 200, "text/plain; charset=utf-8", value.encode()

    service_prefix = "instance/service-accounts/"
    if suffix.startswith(service_prefix):
        remainder = suffix[len(service_prefix) :]
        account, separator, field = remainder.partition("/")
        if account not in ("default", SERVICE_ACCOUNT):
            return 404, "text/plain; charset=utf-8", b"not found\n"
        if not separator:
            value = "aliases\nemail\nscopes\ntoken\n"
            return 200, "text/plain; charset=utf-8", value.encode()
        if field == "email":
            return 200, "text/plain; charset=utf-8", SERVICE_ACCOUNT.encode()
        if field == "scopes":
            scope = "https://www.googleapis.com/auth/cloud-platform\n"
            return 200, "text/plain; charset=utf-8", scope.encode()
        if field == "token":
            expires_in = max(0, expiry_epoch - int(time.time()))
            if expires_in == 0:
                return 503, "application/json", b'{"error":"token expired"}'
            payload = json.dumps(
                {
                    "access_token": token,
                    "expires_in": expires_in,
                    "token_type": "Bearer",
                },
                separators=(",", ":"),
            ).encode()
            return 200, "application/json", payload

    return 404, "text/plain; charset=utf-8", b"not found\n"


class MetadataHandler(BaseHTTPRequestHandler):
    server_version = ""
    sys_version = ""

    def log_message(self, _format: str, *_args: object) -> None:
        return

    def _respond(self, include_body: bool) -> None:
        path = urlsplit(self.path).path
        if path == "/healthz":
            status, content_type, body = 200, "text/plain; charset=utf-8", b"ok\n"
        elif path == "/":
            status, content_type, body = 200, "text/plain; charset=utf-8", b"metadata\n"
        elif self.headers.get("Metadata-Flavor") != "Google":
            status, content_type, body = 403, "text/plain; charset=utf-8", b"forbidden\n"
        elif path.rstrip("/") == "/computeMetadata/v1":
            status, content_type, body = (
                200,
                "text/plain; charset=utf-8",
                b"instance/\nproject/\n",
            )
        else:
            status, content_type, body = metadata_value(
                path, self.server.access_token, self.server.expiry_epoch
            )

        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Metadata-Flavor", "Google")
        self.end_headers()
        if include_body:
            self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        self._respond(include_body=True)

    def do_HEAD(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        self._respond(include_body=False)


class MetadataServer(ThreadingHTTPServer):
    daemon_threads = True
    access_token: str
    expiry_epoch: int


def self_test() -> None:
    fixture = "fixture-token-that-is-never-a-credential"
    expiry = int(time.time()) + 600
    status, content_type, body = metadata_value(
        "/computeMetadata/v1/instance/service-accounts/default/token", fixture, expiry
    )
    parsed = json.loads(body)
    assert status == 200
    assert content_type == "application/json"
    assert parsed["access_token"] == fixture
    assert 0 < parsed["expires_in"] <= 600
    assert parsed["token_type"] == "Bearer"
    status, _, body = metadata_value(
        "/computeMetadata/v1/project/project-id", fixture, expiry
    )
    assert status == 200 and body.decode() == PROJECT_ID
    print("Verified metadata-stub routing with a non-secret fixture.")


def main() -> None:
    if sys.argv[1:] == ["--self-test"]:
        self_test()
        return
    if sys.argv[1:]:
        fail("usage: grafana-metadata-stub.py [--self-test]")
    if not PROJECT_ID or not PROJECT_NUMBER.isdigit() or not SERVICE_ACCOUNT:
        fail("project ID, numeric project ID, and service account are required")

    token, expiry_epoch = read_runtime_credential()
    server = MetadataServer(("0.0.0.0", LISTEN_PORT), MetadataHandler)
    server.access_token = token
    server.expiry_epoch = expiry_epoch
    try:
        server.serve_forever(poll_interval=0.25)
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
