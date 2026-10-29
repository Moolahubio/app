#!/usr/bin/env bash
# Runs the Moolahub UI tests on a simulator against the local dev backend.
#
#   apps/ios/scripts/ui-test.sh <simulator name> <derived data path> [xcodebuild args...]
#   apps/ios/scripts/ui-test.sh MH-Savings <your-derived-data> -only-testing:MoolahubUITests/SavingsFlowUITests
#
# The demo password is read from the backend seed file and handed to the test
# runner as MH_DEMO_PASSWORD (xcodebuild forwards TEST_RUNNER_* variables), so
# it is never copied into the iOS sources. Set MH_BACKEND_LOG to the backend's
# log file for tests that read emailed codes (UITestBackendLog).
#
# Face ID: the iOS 26.5 simulator reports a passcode, so every money-move
# confirm and the app lock open the system prompt (the passcode screen when no
# face is enrolled, which a test can't answer). For the run this script enrolls
# Face ID on the simulator and starts a host helper that watches a directory
# (MH_FACEID_DIR in the tests): each time a `request` file appears it posts one
# simulated face (`match` or `nomatch`, the file's contents) and deletes the
# file (see UITestFaceID in MoolahubUITests/UITestSupport.swift). When the run
# ends, Face ID is unenrolled again. MH_FACEID=0 skips all of this.
#
# Slow server: HomeFlowUITests' slow-server test needs a proxy that holds the
# dashboard and activity reads (scripts/slow-api-proxy.py, 127.0.0.1 only,
# logs nothing). This script starts it on a free port and hands its URL to the
# tests as MH_HOME_SLOW_API, unless TEST_RUNNER_MH_HOME_SLOW_API is already
# set. MH_SLOW_PROXY=0 skips it (that test then skips itself).
#
# Fault proxy: QAExploratoryUITests' uncertain-outcome, failed-balance-read,
# gateway-504 and View-activity-over-Pay-in tests run the app through
# scripts/fault-api-proxy.py (127.0.0.1 only, logs nothing), whose mode the
# test writes to a file. This script starts it on a free port and hands the
# tests MH_QA_FAULT_API and MH_QA_FAULT_MODE_FILE, unless
# TEST_RUNNER_MH_QA_FAULT_API is already set. MH_FAULT_PROXY=0 skips it
# (those tests then skip themselves).
#
# Face ID enrollment is checked every few seconds while the tests run: a
# test-runner restart or a simulator reboot (SpringBoard crashing under load)
# clears it, and every later Face ID test would then meet the passcode screen.
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <simulator name> <derived data path> [xcodebuild args...]" >&2
  exit 64
fi
SIMULATOR="$1"; DERIVED="$2"; shift 2

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
SEED="$REPO/artifacts/api-server/scripts/seed-ios-dev.ts"

PASSWORD="$(sed -nE 's/^export const DEMO_PASSWORD = "([^"]+)";$/\1/p' "$SEED")"
if [[ -z "$PASSWORD" ]]; then
  echo "could not read DEMO_PASSWORD from $SEED" >&2
  exit 1
fi

if ! curl -fsS -o /dev/null --max-time 3 http://localhost:8787/api/healthz; then
  echo "the dev backend is not answering on http://localhost:8787 (run scripts/dev-ios-backend.sh)" >&2
  exit 1
fi

# Optional: the dev backend's log, for tests that need an emailed code.
export TEST_RUNNER_MH_BACKEND_LOG="${MH_BACKEND_LOG:-}"

HELPER_PID=""
FACEID_DIR=""
PROXY_PID=""
PROXY_PORT_FILE=""
FAULT_PID=""
FAULT_PORT_FILE=""
FAULT_MODE_FILE=""

set_face_enrollment() {
  xcrun simctl spawn "$SIMULATOR" notifyutil -s com.apple.BiometricKit.enrollmentChanged "$1" >/dev/null
  xcrun simctl spawn "$SIMULATOR" notifyutil -p com.apple.BiometricKit.enrollmentChanged >/dev/null
}

cleanup() {
  if [[ -n "$FAULT_PID" ]]; then
    kill "$FAULT_PID" 2>/dev/null || true
    wait "$FAULT_PID" 2>/dev/null || true
  fi
  if [[ -n "$FAULT_PORT_FILE" ]]; then
    rm -f "$FAULT_PORT_FILE"
  fi
  if [[ -n "$FAULT_MODE_FILE" ]]; then
    rm -f "$FAULT_MODE_FILE"
  fi
  if [[ -n "$PROXY_PID" ]]; then
    kill "$PROXY_PID" 2>/dev/null || true
    wait "$PROXY_PID" 2>/dev/null || true
  fi
  if [[ -n "$PROXY_PORT_FILE" ]]; then
    rm -f "$PROXY_PORT_FILE"
  fi
  if [[ -n "$HELPER_PID" ]]; then
    kill "$HELPER_PID" 2>/dev/null || true
    wait "$HELPER_PID" 2>/dev/null || true
  fi
  if [[ -n "$FACEID_DIR" ]]; then
    set_face_enrollment 0 || true
    rm -rf "$FACEID_DIR"
  fi
}
trap cleanup EXIT

if [[ "${MH_FACEID:-1}" != "0" ]]; then
  mkdir -p "$DERIVED"
  FACEID_DIR="$(cd "$DERIVED" && pwd)/faceid-helper"
  rm -rf "$FACEID_DIR"
  mkdir -p "$FACEID_DIR"
  # The simulator must be booted for notifyutil.
  xcrun simctl boot "$SIMULATOR" 2>/dev/null || true
  xcrun simctl bootstatus "$SIMULATOR" -b >/dev/null
  set_face_enrollment 1
  (
    ticks=0
    while true; do
      ticks=$((ticks + 1))
      if (( ticks % 15 == 0 )); then
        # About every 5 s: re-enroll if a restart cleared the enrollment.
        state="$(xcrun simctl spawn "$SIMULATOR" notifyutil -g com.apple.BiometricKit.enrollmentChanged 2>/dev/null | awk '{print $NF}')"
        if [[ "$state" == "0" ]]; then
          set_face_enrollment 1 2>/dev/null || true
          echo "faceid-helper: Face ID was unenrolled (simulator restart?); enrolled again" >&2
        fi
      fi
      if [[ -f "$FACEID_DIR/request" ]]; then
        kind="$(cat "$FACEID_DIR/request" 2>/dev/null || true)"
        case "$kind" in
          match|nomatch)
            xcrun simctl spawn "$SIMULATOR" notifyutil -p "com.apple.BiometricKit_Sim.pearl.$kind" >/dev/null 2>&1 || true
            echo "faceid-helper: posted $kind" >&2
            ;;
        esac
        rm -f "$FACEID_DIR/request"
      fi
      sleep 0.3
    done
  ) &
  HELPER_PID=$!
  export TEST_RUNNER_MH_FACEID_DIR="$FACEID_DIR"
  # The Savings and Account tests read their own names for the same helper.
  export TEST_RUNNER_MH_SAVINGS_FACEID_DIR="$FACEID_DIR"
  export TEST_RUNNER_MH_ACCOUNT_FACEID_DIR="$FACEID_DIR"
fi

if [[ "${MH_SLOW_PROXY:-1}" != "0" && -z "${TEST_RUNNER_MH_HOME_SLOW_API:-}" ]]; then
  PROXY_PORT_FILE="$(mktemp -t mh-slow-proxy)"
  python3 "$HERE/slow-api-proxy.py" 0 120 "$PROXY_PORT_FILE" &
  PROXY_PID=$!
  for _ in $(seq 1 100); do
    [[ -s "$PROXY_PORT_FILE" ]] && break
    sleep 0.1
  done
  if [[ -s "$PROXY_PORT_FILE" ]]; then
    export TEST_RUNNER_MH_HOME_SLOW_API="http://127.0.0.1:$(cat "$PROXY_PORT_FILE")/api"
  else
    echo "slow-api-proxy did not start; the slow-server test will skip" >&2
  fi
fi

if [[ "${MH_FAULT_PROXY:-1}" != "0" && -z "${TEST_RUNNER_MH_QA_FAULT_API:-}" ]]; then
  mkdir -p "$DERIVED"
  FAULT_PORT_FILE="$(mktemp -t mh-fault-proxy)"
  FAULT_MODE_FILE="$(cd "$DERIVED" && pwd)/fault-proxy.mode"
  printf 'pass' > "$FAULT_MODE_FILE"
  python3 "$HERE/fault-api-proxy.py" "$FAULT_PORT_FILE" "$FAULT_MODE_FILE" &
  FAULT_PID=$!
  for _ in $(seq 1 100); do
    [[ -s "$FAULT_PORT_FILE" ]] && break
    sleep 0.1
  done
  if [[ -s "$FAULT_PORT_FILE" ]]; then
    export TEST_RUNNER_MH_QA_FAULT_API="http://127.0.0.1:$(cat "$FAULT_PORT_FILE")/api"
    export TEST_RUNNER_MH_QA_FAULT_MODE_FILE="$FAULT_MODE_FILE"
  else
    echo "fault-api-proxy did not start; the fault tests will skip" >&2
  fi
fi

# XCUITest logs every typeText call ("Type '…' into …"), so passwords would
# appear in this script's output. The output is filtered (the demo password
# is read from the environment, never from the command line): the demo
# password, anything typed into a secure field, and the passwords the tests
# generate for throwaway accounts (Qa<Name>-<12 hex>, typed into plain fields
# during sign-up) all become [redacted]. The test result bundle's own
# attachments are not filtered.
TEST_RUNNER_MH_DEMO_PASSWORD="$PASSWORD" xcodebuild \
  -project "$REPO/apps/ios/Moolahub.xcodeproj" -scheme Moolahub \
  -destination "platform=iOS Simulator,name=$SIMULATOR" \
  -derivedDataPath "$DERIVED" \
  test "$@" 2>&1 \
  | MH_REDACT="$PASSWORD" perl -pe 'BEGIN { $| = 1; $secret = $ENV{MH_REDACT}; }
      s/\Q$secret\E/[redacted]/g if length $secret;
      s/Type \x27.*?\x27 into ("[^"]*" SecureTextField)/Type \x27[redacted]\x27 into $1/g;
      s/Qa[A-Za-z]+-[0-9A-Fa-f]{12}/[redacted]/g;'
