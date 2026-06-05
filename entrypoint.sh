#!/usr/bin/env bash
set -euo pipefail

ACTION_DIR="${GITHUB_ACTION_PATH:-$(dirname "$0")/..}"
BIN_DIR="${RUNNER_TEMP:-/tmp}/echo-check-bin"
BIN_PATH="${BIN_DIR}/echo-check"
VERSION="${ECHO_CHECK_VERSION:-latest}"
OS_NAME="${ECHO_CHECK_OS:-linux}"
ARCH_NAME="${ECHO_CHECK_ARCH:-x86_64}"

case "${OS_NAME}-${ARCH_NAME}" in
  linux-x86_64)   TARGET="x86_64-unknown-linux-gnu" ;;
  linux-aarch64) TARGET="aarch64-unknown-linux-gnu" ;;
  darwin-x86_64) TARGET="x86_64-apple-darwin" ;;
  darwin-aarch64)TARGET="aarch64-apple-darwin" ;;
  windows-x86_64)TARGET="x86_64-pc-windows-msvc" ;;
  *) echo "::error::Unsupported platform: ${OS_NAME}-${ARCH_NAME}" >&2; exit 1 ;;
esac

EXT="tar.gz"
[[ "${OS_NAME}" == "windows" ]] && EXT="zip"

RELEASE_TAG="${VERSION}"
if [[ "${VERSION}" == "latest" ]]; then
  RELEASE_TAG=$(curl -fsSL "https://api.github.com/repos/Devaretanmay/echo-check/releases/latest" | \
    grep -E '"tag_name"' | head -1 | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
  if [[ -z "${RELEASE_TAG}" ]]; then
    echo "::error::Could not determine latest release tag" >&2
    exit 1
  fi
fi

ASSET_NAME="echo-check-${TARGET}.${EXT}"
URL="https://github.com/Devaretanmay/echo-check/releases/download/${RELEASE_TAG}/${ASSET_NAME}"

cmd_download() {
  mkdir -p "${BIN_DIR}"
  echo "Downloading ${URL}"
  TMP="$(mktemp -d)"
  curl -fsSL -o "${TMP}/asset.${EXT}" "${URL}"
  if [[ "${EXT}" == "tar.gz" ]]; then
    tar -xzf "${TMP}/asset.${EXT}" -C "${TMP}"
  else
    unzip -o "${TMP}/asset.${EXT}" -d "${TMP}"
  fi
  if [[ -f "${TMP}/echo-check" ]]; then
    mv "${TMP}/echo-check" "${BIN_PATH}"
  elif [[ -f "${TMP}/echo-check.exe" ]]; then
    mv "${TMP}/echo-check.exe" "${BIN_PATH}.exe"
    BIN_PATH="${BIN_PATH}.exe"
  else
    echo "::error::Asset did not contain echo-check binary" >&2
    ls -la "${TMP}" >&2
    exit 1
  fi
  chmod +x "${BIN_PATH}"
  rm -rf "${TMP}"
  echo "::notice::echo-check ${RELEASE_TAG} installed at ${BIN_PATH}"
  "${BIN_PATH}" --version || true
}

cmd_run() {
  if [[ ! -x "${BIN_PATH}" ]]; then
    echo "::error::echo-check binary not found at ${BIN_PATH}; download step must run first" >&2
    exit 1
  fi

  REPORT_DIR="${RUNNER_TEMP:-/tmp}/echo-check-report"
  mkdir -p "${REPORT_DIR}"
  REPORT_PATH="${REPORT_DIR}/echo-check-report.md"
  RAW_JSON="${REPORT_DIR}/echo-check.json"

  PR_NUMBER="${PR_NUMBER:-}"
  if [[ -z "${PR_NUMBER}" && -f "${GITHUB_EVENT_PATH:-}" ]]; then
    if command -v jq >/dev/null 2>&1; then
      PR_NUMBER=$(jq -r '.pull_request.number // empty' "${GITHUB_EVENT_PATH}" 2>/dev/null || true)
    fi
  fi

  if [[ -z "${PR_NUMBER}" ]]; then
    echo "::error::pr_number input is required and could not be inferred from event" >&2
    exit 1
  fi

  REPO="${GITHUB_REPOSITORY:-}"
  if [[ -z "${REPO}" ]]; then
    echo "::error::GITHUB_REPOSITORY is empty" >&2
    exit 1
  fi

  DIFF_URL="https://patch-diff.githubusercontent.com/raw/${REPO}/pull/${PR_NUMBER}.diff"
  echo "Fetching diff: ${DIFF_URL}"
  DIFF_FILE="${REPORT_DIR}/pr.diff"
  if ! curl -fsSL -H "Authorization: token ${GITHUB_TOKEN}" -o "${DIFF_FILE}" "${DIFF_URL}"; then
    echo "::error::Failed to fetch PR diff from ${DIFF_URL}" >&2
    exit 1
  fi

  echo "Running echo-check on PR #${PR_NUMBER}"
  EXIT_CODE=0
  "${BIN_PATH}" \
    --diff "${DIFF_FILE}" \
    --format json \
    --max-findings "${MAX_FINDINGS:-20}" \
    --output "${RAW_JSON}" \
    --repo-root "${RUNNER_TEMP:-/tmp}" \
    --pr-url "https://github.com/${REPO}/pull/${PR_NUMBER}" \
    || EXIT_CODE=$?

  FINDINGS_COUNT=0
  if [[ -f "${RAW_JSON}" ]] && command -v jq >/dev/null 2>&1; then
    FINDINGS_COUNT=$(jq -r '((.findings["Missing Tests"] | length) + (.findings["Risky Assumptions"] | length))' "${RAW_JSON}" 2>/dev/null || echo 0)
  fi

  "${BIN_PATH}" \
    --diff "${DIFF_FILE}" \
    --format markdown \
    --max-findings "${MAX_FINDINGS:-20}" \
    --output "${REPORT_PATH}" \
    --repo-root "${RUNNER_TEMP:-/tmp}" \
    --pr-url "https://github.com/${REPO}/pull/${PR_NUMBER}" \
    --pr-number "${PR_NUMBER}" \
    || true

  echo "findings_count=${FINDINGS_COUNT}" >> "${GITHUB_OUTPUT:-/dev/null}"
  echo "report_path=${REPORT_PATH}" >> "${GITHUB_OUTPUT:-/dev/null}"

  if [[ "${COMMENT_ON_PR:-true}" == "true" && -f "${REPORT_PATH}" && "${FINDINGS_COUNT}" -gt 0 ]]; then
    echo "Posting PR comment"
    post_comment "${REPORT_PATH}" "${PR_NUMBER}" "${REPO}" "${GITHUB_TOKEN}" "${FINDINGS_COUNT}"
  fi

  if [[ "${FAIL_ON_FINDINGS:-true}" == "true" && "${FINDINGS_COUNT}" -gt 0 ]]; then
    echo "::notice::echo-check found ${FINDINGS_COUNT} finding(s)"
    if [[ "${EXIT_CODE}" -eq 0 ]]; then
      EXIT_CODE=1
    fi
  fi

  exit "${EXIT_CODE}"
}

post_comment() {
  local report_path="$1"
  local pr_number="$2"
  local repo="$3"
  local token="$4"
  local count="$5"

  if ! command -v jq >/dev/null 2>&1; then
    echo "::warning::jq not installed; cannot post comment"
    return 0
  fi

  local body
  body=$(jq -Rs '.' < "${report_path}")

  local payload
  payload=$(jq -n --arg body "$(cat "${report_path}")" '{body: $body}')

  if curl -fsSL -X POST \
    -H "Authorization: token ${token}" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: application/json" \
    -d "${payload}" \
    "https://api.github.com/repos/${repo}/issues/${pr_number}/comments" >/dev/null; then
    echo "::notice::Posted comment to PR #${pr_number} (${count} finding(s))"
  else
    echo "::warning::Failed to post comment to PR #${pr_number}"
  fi
}

case "${1:-}" in
  download) cmd_download ;;
  run) cmd_run ;;
  *) echo "Usage: $0 {download|run}" >&2; exit 2 ;;
esac
