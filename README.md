# it-support-triage

**One command that turns "my computer is being weird" into a ticket you can actually work.**

Tier 1 help desk starts the same way every time: you get a vague report, then spend
five minutes on the phone asking the user to read out their IP address, check whether
they're on Wi-Fi, and guess how much disk space they have left. Half the answers are
wrong, and you still haven't started troubleshooting.

`triage.sh` collects all of it in one pass and prints a Markdown report you paste
straight into the ticket.

```bash
./triage.sh                 # print the report
./triage.sh -o report.md    # save it to a file
./triage.sh --offline       # skip connectivity tests
```

## What it collects

| Section | What you get |
|---|---|
| **System** | hostname, OS and build, model, serial number, kernel, uptime |
| **Hardware** | CPU, RAM, and every real disk with a **LOW SPACE** flag past 85% |
| **Network** | active interface, IPv4, default gateway, DNS servers |
| **Connectivity** | gateway reachable, DNS resolving, internet reachable, average latency |
| **VPN & printing** | tunnel interfaces, configured printers, queued jobs |
| **Load** | top six processes by CPU |
| **Errors** | recent system-log errors |

## Why the connectivity tests are three separate checks

This is the part that saves real time. "No internet" has at least three different
causes, and the three tests separate them before you touch anything:

- **Gateway fails** → the problem is local. Cable, Wi-Fi association, or the router.
- **Gateway passes, DNS fails** → the network is fine, name resolution is broken.
  Wrong DNS server, VPN split-tunnel, or a bad `resolv.conf`.
- **Gateway and DNS pass, internet fails** → the problem is upstream of the user.
  Escalate to the ISP or network team instead of rebuilding their profile.

That single distinction is the difference between a five-minute ticket and an hour
of guessing.

## Sample output

```markdown
## Network

| Field | Value |
|---|---|
| Active interface | en0 |
| IPv4 address | 198.51.100.24 |
| Default gateway | 198.51.100.1 |
| DNS servers | 198.51.100.1, 198.51.100.2 |

**Connectivity**

| Test | Result |
|---|---|
| Gateway reachable | PASS (198.51.100.1) |
| DNS resolution | **FAIL** — DNS not resolving |
| Internet (1.1.1.1) | PASS — 18 ms avg |
```

Gateway up, internet up, DNS down — the network is fine and the fault is name
resolution. Full example: [`sample-report.md`](sample-report.md) (synthetic data).

## Safety

- **Read-only.** It runs diagnostic commands and changes nothing on the machine.
- **No data leaves the machine.** The only outbound traffic is the connectivity
  tests — a ping to the gateway, a DNS lookup, and a ping to `1.1.1.1`. Pass
  `--offline` and there is none at all.
- **No dependencies.** Plain bash and standard system tools.
- The report contains the hostname, local IP, and serial number, so treat it the
  same way you would treat any ticket attachment.

## Platform support

| Platform | Status |
|---|---|
| macOS | Tested on macOS 26 (Apple Silicon) |
| Linux | Supported — uses `ip`, `/proc`, `journalctl`, `/etc/os-release` |
| Windows | Not yet. A PowerShell port is the obvious next step. |

Linux support is written against the standard tooling but has not been tested on
every distribution; issues and fixes are welcome.

## Notes from building it

A few things that were not obvious:

- On macOS, `ioreg | awk '…{exit}'` makes `ioreg` exit on `SIGPIPE`, so the
  pipeline returns non-zero even when the value was found. A naive
  `$(… || fallback)` prints the serial number *and* the fallback. Capture the
  value first, then test whether it is empty.
- `paste -sd', '` does not join with `", "`. It alternates the delimiters,
  producing `a,b c,d`. Join with a single character and space it out afterwards.
- `df` on macOS lists firmware volumes and any mounted disk image. A simulator
  runtime sitting at 98% full will trigger a low-disk alarm that means nothing to
  the user, so those mounts are filtered out.

## License

MIT — see [LICENSE](LICENSE).
