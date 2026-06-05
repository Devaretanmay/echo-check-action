# echo-check GitHub Action

Scan a pull request diff for [missing tests](../echo-check) and [risky assumptions](../echo-check), then post the findings as a PR comment.

## What it does

For each pull request, echo-check:

1. Downloads the prebuilt `echo-check` binary from the [`Devaretanmay/echo-check`](https://github.com/Devaretanmay/echo-check) releases.
2. Fetches the PR diff via the GitHub API.
3. Runs the binary in JSON mode to count findings, then markdown mode to render a report.
4. Posts the markdown report as a PR comment (if `comment_on_pr: true`).
5. Optionally fails the workflow if findings exist (if `fail_on_findings: true`).

## Usage

```yaml
name: echo-check
on:
  pull_request:
    types: [opened, synchronize, reopened]

permissions:
  contents: read
  pull-requests: write

jobs:
  echo-check:
    runs-on: ubuntu-latest
    steps:
      - uses: Devaretanmay/echo-check-action@v1
        with:
          github_token: ${{ secrets.GITHUB_TOKEN }}
          echo_check_version: v0.1.0-beta.2
          fail_on_findings: false
          comment_on_pr: false
          max_findings: 20

# Or pin a specific version:
      - uses: Devaretanmay/echo-check-action@v1.0.0
        with:
          github_token: ${{ secrets.GITHUB_TOKEN }}
          fail_on_findings: true
          max_findings: 20
```

### Inputs

| Input | Description | Default |
|---|---|---|
| `pr_number` | PR number to scan. Inferred from event if omitted. | (event) |
| `base_ref` | Base ref for diff. | (PR base) |
| `head_ref` | Head ref for diff. | (PR head) |
| `fail_on_findings` | Exit non-zero if findings exist. | `true` |
| `max_findings` | Max findings per category. | `20` |
| `echo_check_version` | Release tag (`v0.1.0-beta.1` or `latest`). | `latest` |
| `github_token` | Token for posting comments. | (required) |
| `comment_on_pr` | Post findings as a PR comment. | `true` |

### Outputs

| Output | Description |
|---|---|
| `findings_count` | Total findings (MT + RA). |
| `report_path` | Path to the saved markdown report. |

### Permissions

The action needs:

- `contents: read` — to download the binary from releases.
- `pull-requests: write` — to post PR comments.

## Platform support

| Runner | Target |
|---|---|
| `ubuntu-latest` | `x86_64-unknown-linux-gnu` |
| `macos-latest` | `aarch64-apple-darwin` |
| `macos-13` | `x86_64-apple-darwin` |
| `windows-latest` | `x86_64-pc-windows-msvc` |

## Example output

When the action runs on a PR with findings, the bot posts a comment like:

> ## echo-check: 4 findings
>
> ### Missing Tests (2)
> - `src/auth/login.py:42` — `validate_token()` — no test for null token
> - `src/auth/login.py:58` — `validate_token()` — no test for empty token
>
> ### Risky Assumptions (2)
> - `src/api/client.py:113` — `requests.get` — no error handling
> - `src/api/client.py:120` — `response.json` — chained dict access without `.get()`

## Local testing

```bash
# Build echo-check
cargo build --release --manifest-path ../Echo/Cargo.toml

# Run on a diff file
../Echo/target/release/echo-check path/to/file.diff --format markdown
```

## License

MIT
