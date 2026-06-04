#!/usr/bin/env python3
import argparse
import email.utils
import fcntl
import json
import os
import random
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

APP_NAME = "Linear"
ENDPOINT = "https://api.linear.app/graphql"
DEFAULT_NOTIFY_SEND = "@notifySend@"
DEFAULT_XDG_OPEN = "@xdgOpen@"
STATE_VERSION = 1

QUERY = """
query LinearNotifications($first: Int!, $after: String) {
  notifications(first: $first, after: $after, orderBy: updatedAt) {
    nodes { id title subtitle url inboxUrl readAt archivedAt category type createdAt updatedAt actor { name } }
    pageInfo { hasNextPage endCursor }
  }
  notificationsUnreadCount
}
"""


class FetchError(RuntimeError):
    def __init__(self, message, retry_after=None):
        super().__init__(message)
        self.retry_after = retry_after


class LockError(RuntimeError):
    pass


def log(message):
    print(f"linear-notify: {message}", file=sys.stderr, flush=True)


def truncate(value, limit=500):
    return (value or "")[:limit]


def positive_int(value):
    try:
        parsed = int(value)
    except ValueError:
        raise argparse.ArgumentTypeError("must be an integer") from None
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be > 0")
    return parsed


def non_empty_path(value):
    if not value:
        raise argparse.ArgumentTypeError("must not be empty")
    return value


def default_state_file():
    state_home = os.environ.get("XDG_STATE_HOME") or os.path.join(Path.home(), ".local", "state")
    return os.path.join(state_home, "linear-notify", "state.json")


def state_dir(path):
    return os.path.dirname(path) or "."


def ensure_state_dir(path):
    directory = state_dir(path)
    os.makedirs(directory, mode=0o700, exist_ok=True)
    if directory != ".":
        os.chmod(directory, 0o700)
    return directory


def empty_state():
    return {"schemaVersion": STATE_VERSION, "seenNotificationIds": [], "lastSeenCreatedAt": None}


def parse_retry_after(value):
    if not value:
        return None
    try:
        return max(0, int(value))
    except ValueError:
        pass
    try:
        retry_at = email.utils.parsedate_to_datetime(value)
    except (TypeError, ValueError):
        return None
    if retry_at.tzinfo is None:
        retry_at = retry_at.replace(tzinfo=timezone.utc)
    return max(0, int((retry_at - datetime.now(timezone.utc)).total_seconds()))


def read_token(path):
    with open(path, "r", encoding="utf-8") as f:
        token = f.read().strip()
    if not token:
        raise RuntimeError("token file empty")
    return token


def wait_for_token(path, timeout):
    deadline = time.monotonic() + timeout
    while True:
        try:
            return read_token(path)
        except OSError:
            pass
        except RuntimeError:
            pass
        if time.monotonic() >= deadline:
            raise RuntimeError(f"token file not readable or empty: {path}")
        time.sleep(1)


def load_state(path):
    if not os.path.exists(path):
        return empty_state(), True, False
    try:
        with open(path, "r", encoding="utf-8") as f:
            state = json.load(f)
        if state.get("schemaVersion") != STATE_VERSION:
            raise ValueError("unsupported state schema")
        if not isinstance(state.get("seenNotificationIds"), list):
            raise ValueError("seenNotificationIds must be a list")
        state.setdefault("lastSeenCreatedAt", None)
        return state, False, False
    except Exception as e:
        backup = f"{path}.corrupt.{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}"
        shutil.move(path, backup)
        log(f"state corrupt; moved to {backup}: {truncate(str(e))}")
        return empty_state(), True, True


def save_state(path, state, max_seen_ids):
    directory = ensure_state_dir(path)
    durable_state = {
        "schemaVersion": STATE_VERSION,
        "seenNotificationIds": state.get("seenNotificationIds", [])[-max_seen_ids:],
        "lastSeenCreatedAt": state.get("lastSeenCreatedAt"),
    }

    fd, tmp = tempfile.mkstemp(prefix="state.", suffix=".tmp", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            os.chmod(tmp, 0o600)
            json.dump(durable_state, f, separators=(",", ":"))
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
        os.chmod(path, 0o600)
        dir_fd = os.open(directory, os.O_DIRECTORY)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
    finally:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass


def acquire_state_lock(path):
    lock = open(path + ".lock", "w", encoding="utf-8")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError as e:
        lock.close()
        raise LockError(f"another linear-notify instance holds lock: {path}.lock") from e
    return lock


def graphql_request(args, token):
    body = json.dumps({"query": QUERY, "variables": {"first": args.page_size, "after": None}}).encode()
    request = urllib.request.Request(
        ENDPOINT,
        data=body,
        headers={"Content-Type": "application/json", "Authorization": token},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=args.request_timeout) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        retry_after = parse_retry_after(e.headers.get("Retry-After"))
        try:
            error_body = e.read().decode("utf-8", errors="replace")
        except Exception:
            error_body = ""
        message = f"HTTP {e.code}"
        if retry_after is not None:
            message += f" retry-after={retry_after}"
        if error_body:
            message += ": " + truncate(error_body)
        raise FetchError(message, retry_after=retry_after) from e


def fetch_notifications(args, token):
    response = graphql_request(args, token)
    if response.get("errors"):
        raise FetchError("GraphQL errors: " + truncate(json.dumps(response["errors"])))
    try:
        return response["data"]["notifications"]["nodes"]
    except (KeyError, TypeError) as e:
        raise FetchError("unexpected GraphQL response shape") from e


def notification_url(notification):
    return notification.get("inboxUrl") or notification.get("url") or ""


def notification_text(notification):
    title = notification.get("title") or "Linear notification"
    body = "\n".join(x for x in [notification.get("subtitle") or "", notification_url(notification)] if x)
    return title, body


def url_allowed(url):
    try:
        parsed = urllib.parse.urlparse(url)
    except Exception:
        return False
    return parsed.scheme == "https" and (parsed.netloc == "linear.app" or parsed.netloc.endswith(".linear.app"))


def open_url(xdg_open, url):
    if url_allowed(url):
        subprocess.Popen([xdg_open, url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


def notify_plain(args, notification):
    title, body = notification_text(notification)
    command = [args.notify_send, "--app-name", APP_NAME, title, body]
    result = subprocess.run(command, text=True, capture_output=True, timeout=10)
    if result.returncode != 0:
        log("notify-send failed: " + truncate(result.stderr))
        return False
    return True


def notify_with_action(args, notification):
    title, body = notification_text(notification)
    url = notification_url(notification)

    def worker():
        command = [
            args.notify_send,
            "--app-name",
            APP_NAME,
            "--expire-time",
            str(args.action_expire_time_ms),
            "--action=open=Open",
            title,
            body,
        ]
        try:
            result = subprocess.run(command, text=True, capture_output=True, timeout=args.action_wait_timeout)
            if result.returncode != 0:
                log("action notify-send failed; trying fallback: " + truncate(result.stderr))
                notify_plain(args, notification)
                return
            if result.stdout.strip() == "open":
                open_url(args.xdg_open, url)
        except Exception as e:
            log("action helper failed: " + truncate(str(e)))

    threading.Thread(target=worker, daemon=True).start()
    return True


def unread_unarchived(notifications):
    return [n for n in notifications if n.get("readAt") is None and n.get("archivedAt") is None]


def remember(state, notification):
    state["seenNotificationIds"].append(notification["id"])
    state["lastSeenCreatedAt"] = notification.get("createdAt") or state.get("lastSeenCreatedAt")


def seed_existing(state, notifications):
    seen = set(state.get("seenNotificationIds", []))
    for notification in notifications:
        if notification.get("id") not in seen:
            remember(state, notification)
            seen.add(notification["id"])


def notify_new(args, state, notifications):
    seen = set(state.get("seenNotificationIds", []))
    new_notifications = [n for n in notifications if n.get("id") not in seen]
    new_notifications.sort(key=lambda n: n.get("createdAt") or "")

    changed = False
    for notification in new_notifications:
        notify = notify_with_action if args.enable_actions else notify_plain
        if notify(args, notification):
            remember(state, notification)
            changed = True
    return changed


def sleep_with_jitter(seconds):
    time.sleep(max(1, seconds + random.uniform(-3, 3)))


def build_parser():
    parser = argparse.ArgumentParser(description="Poll Linear notifications and forward unread items to notify-send.")
    parser.add_argument("--token-file", type=non_empty_path, required=True)
    parser.add_argument("--interval", type=positive_int, default=45)
    parser.add_argument("--page-size", type=positive_int, default=50)
    parser.add_argument("--max-seen-ids", type=positive_int, default=1000)
    parser.add_argument("--max-backoff-seconds", type=positive_int, default=300)
    parser.add_argument("--request-timeout", type=positive_int, default=15)
    parser.add_argument("--startup-secret-timeout", type=positive_int, default=60)
    parser.add_argument("--notify-send", type=non_empty_path, default=DEFAULT_NOTIFY_SEND)
    parser.add_argument("--xdg-open", type=non_empty_path, default=DEFAULT_XDG_OPEN)
    parser.add_argument("--state-file", type=non_empty_path, default=default_state_file())
    parser.add_argument("--notify-existing-on-first-run", action="store_true")
    parser.add_argument("--enable-actions", action="store_true")
    parser.add_argument("--action-expire-time-ms", type=positive_int, default=15000)
    parser.add_argument("--action-wait-timeout", type=positive_int, default=20)
    return parser


def poll_once(args, state, first_run):
    notifications = unread_unarchived(fetch_notifications(args, read_token(args.token_file)))
    if first_run and not args.notify_existing_on_first_run:
        seed_existing(state, notifications)
        return True
    return notify_new(args, state, notifications)


def run(args):
    ensure_state_dir(args.state_file)
    lock = acquire_state_lock(args.state_file)
    wait_for_token(args.token_file, args.startup_secret_timeout)
    state, first_run, corrupt_state = load_state(args.state_file)
    should_seed = first_run or corrupt_state
    backoff = 1

    try:
        while True:
            try:
                changed = poll_once(args, state, should_seed)
                if changed:
                    save_state(args.state_file, state, args.max_seen_ids)
                should_seed = False
                backoff = 1
                sleep_with_jitter(args.interval)
            except FetchError as e:
                log(truncate(str(e)))
                delay = e.retry_after if e.retry_after is not None else backoff
                sleep_with_jitter(min(args.max_backoff_seconds, delay))
                backoff = min(args.max_backoff_seconds, backoff * 2)
            except Exception as e:
                log(truncate(str(e)))
                sleep_with_jitter(min(args.max_backoff_seconds, backoff))
                backoff = min(args.max_backoff_seconds, backoff * 2)
    finally:
        lock.close()


def main():
    run(build_parser().parse_args())


if __name__ == "__main__":
    main()
