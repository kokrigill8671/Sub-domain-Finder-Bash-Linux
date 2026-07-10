# subdomain_finder_notimeout.sh

A bash port of `subdomain_finder_notimeout.py`. It does two things:

1. **Passive discovery** — queries [crt.sh](https://crt.sh) (Certificate
   Transparency logs) for every certificate ever issued for `*.yourdomain.com`
   and extracts the hostnames.
2. **Active liveness check** — tries `https://` then `http://` against every
   discovered subdomain to see which ones actually respond.

Timeouts are intentionally **disabled** — requests wait indefinitely instead
of erroring out after N seconds. This is more patient on slow/flaky networks,
but a genuinely dead host can hang until you `Ctrl+C`.

> ⚠️ **Only run this against domains you own or are explicitly authorized to
> test.** Passive lookups (crt.sh) are on public data, but the active
> liveness check sends real HTTP requests to those hosts.

---

## 1. Requirements

| Tool | Purpose |
|------|---------|
| `bash` (4+) | the script itself |
| `curl` | HTTP requests to crt.sh and target subdomains |
| `jq` | parsing crt.sh's JSON response |

### Install on Debian/Ubuntu
```bash
sudo apt update
sudo apt install -y curl jq
```

### Install on macOS (Homebrew)
```bash
brew install curl jq
```

### Install on Fedora/RHEL/CentOS
```bash
sudo dnf install -y curl jq
```

Check both are available:
```bash
curl --version
jq --version
```

---

## 2. Setup

1. Save `subdomain_finder_notimeout.sh` somewhere convenient, e.g. `~/tools/`.
2. Make it executable:
   ```bash
   chmod +x subdomain_finder_notimeout.sh
   ```

---

## 3. Usage

Basic run:
```bash
./subdomain_finder_notimeout.sh example.com
```

With options:
```bash
./subdomain_finder_notimeout.sh example.com --threads 30 --retries 8 --alive-retries 2
```

### Options

| Flag | Default | Meaning |
|------|---------|---------|
| `--threads N` | 20 | Number of parallel liveness-check jobs (via `xargs -P`) |
| `--alive-retries N` | 2 | Retry attempts per scheme (`https`/`http`) on connection errors during liveness checks |
| `--retries N` | 8 | Max retry attempts for crt.sh on `429/500/502/503/504` responses or on suspiciously empty (`0` record) results |

Run `./subdomain_finder_notimeout.sh --help` any time for a quick reminder.

---

## 4. What it does, step by step

1. **Query crt.sh** for `%.example.com` in JSON form.
   - crt.sh sometimes rate-limits by returning HTTP `200` with an **empty
     array**, which looks identical to "this domain really has zero certs."
     The script treats an empty result as *possibly* a rate-limit and retries
     with backoff before accepting it as genuine.
   - On `429/500/502/503/504` or a connection error, it also retries, with
     a backoff delay of `5s × attempt`, capped at `60s`.
2. **Parse and normalize** every `name_value` field from the returned
   certificates: lowercases them, strips a leading `*.` wildcard prefix,
   discards anything still containing a `*`, and keeps only names ending in
   your target domain.
3. **Save the raw list** to `subdomains_raw_<domain>.txt` (deduplicated,
   sorted).
4. **Check liveness** for each subdomain: try `https://`, then `http://`, in
   parallel across `--threads` jobs. Connection errors are retried per
   `--alive-retries`; other errors (e.g. SSL failures) skip straight to the
   next scheme.
5. **Save alive hosts** to `subdomains_alive_<domain>.txt` in the form:
   ```
   https://sub.example.com [200]
   ```
6. **Print a summary** of total found vs. alive.

---

## 5. Output files

Both files are written to the current working directory:

- `subdomains_raw_<domain>.txt` — every unique subdomain discovered via crt.sh
- `subdomains_alive_<domain>.txt` — subset that responded to an HTTP(S) request,
  with status code and scheme

---

## 6. Notes & caveats

- **No timeouts, by design.** If a host is a black hole (firewall silently
  drops packets rather than refusing the connection), that request can hang
  indefinitely. Use `Ctrl+C` to abort if a run seems stuck.
- **Concurrency.** `--threads` controls how many liveness checks run at once
  via `xargs -P`. Raise it for speed on a large subdomain list, lower it if
  you're worried about hammering a target.
- **crt.sh availability.** crt.sh is a free community resource and can be
  slow or unavailable at times — that's what the retry/backoff logic is for.
- **Legal/ethical use.** Passive CT-log lookups are public data, but actively
  probing hosts you don't have permission to test may violate acceptable-use
  policies or law depending on your jurisdiction. Get authorization first.
