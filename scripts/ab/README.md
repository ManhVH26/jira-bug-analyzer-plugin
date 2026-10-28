# A/B harness — run real tickets on two skill versions, score against the merged fix

Each run is a sandbox: its own `HOME` (skill copy, shared memory rewound to when the ticket was picked up,
`.gitconfig` sending GitHub URLs to local bare repos), a Jira stand-in serving the ticket as it was before
anyone touched it, a `gh` shim, no claude.ai connectors. The project repo stops at the fix's parent commit,
so the real fix is the answer key. The device is real (phone or emulator), shared one run at a time.

```bash
cp cases.example.json cases.json            # ticket -> repo, fix commit, base branch, pick-up time (git-ignored)
python3 snapshot.py tickets AIP396-461 …    # read-only snapshot from real Jira (git-ignored: ticket content)
bash setup_run.sh new AIP396-461            # this repo's skill
bash setup_run.sh old AIP396-461 --skill ~/old-copy/jira-bug-analyzer
echo "/jira-bug-analyzer AIP396-461 --auto" > runs/AIP396-461-new/prompt   # optional; this is the default
bash run.sh --queue runs/AIP396-461-old runs/AIP396-461-new                # one at a time (one device)
python3 ab_report.py runs --json report.json
```

`ab_report.py` scores each run: minutes, cost, tool calls, verifier commands, screenshots read, claim,
ledger rows, PR, Jira (embedded evidence / Resolved / worklog), adb through the lock vs bare, code review,
file overlap with the real fix, deferral, and `leaks` — any access to the real shared memory or transcripts
outside the sandbox (also denied in the sandbox settings). Tool calls are counted once per id: transcripts
log the same call more than once.

Never commit `cases.json`, `tickets/` or `runs/`: they hold internal ticket content and local paths.
