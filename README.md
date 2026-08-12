# linux-helper

A collection of small, dependency-light POSIX `sh` scripts for everyday Linux maintenance

## Install

**Locally** (clone the repo, then install a script into `/usr/local/bin`, stripped of its `.sh` extension):

```sh
./install.sh durank.sh
```

**Online** (no clone needed — downloads `install.sh` from the `latest` tag and runs it, which in turn fetches the requested script from GitHub):

```sh
curl -fsSL https://raw.githubusercontent.com/zharfanug/linux-helper/latest/install.sh | sh -s -- durank.sh
```

Requires `sudo`, and `curl` or `wget` for the online install.

## Scripts

- **durank.sh** — show disk usage under a directory, sorted largest to smallest.
- **rotateit.sh** — create/manage a `/etc/logrotate.d` config that rotates a log daily and archives each rotated copy as a dated gzip file, relying on logrotate's own daily cron trigger.
- **git-update.sh** — commit and push the working tree, moving a `latest` tag to the new commit, without touching history.
- **git-merge.sh** — squash the entire repo history into a single commit and force-push it.
- **git-tag-update.sh** — create or move a tag to the current commit and push it.

Run any script with `-h` / `--help` for full usage and options.

## Conventions

Every script is standalone POSIX `sh` (no bashisms) and shares the same boilerplate: `log`/`log_warn`/`log_error` helpers, colorized output when attached to a TTY, and `require_cmd`/`require_cmd_list` guards for external dependencies. `zn-shlib.sh` holds the reference copy of this boilerplate — copy from it when adding a new script rather than sourcing it at runtime.
