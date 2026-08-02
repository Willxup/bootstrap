# Bootstrap

**English** | [简体中文](README.zh.md)

A single-file server bootstrap script for Debian/Ubuntu. Supports configuration files, selective steps, dry runs, stopping on failure, and resuming from checkpoints.

## Quick start

Log in to Debian/Ubuntu as `root` and run:

```bash
curl -fsSL https://raw.githubusercontent.com/Willxup/bootstrap/main/bootstrap.sh -o bootstrap.sh && bash bootstrap.sh
```

To download the script without running it:

```bash
curl -fLO https://raw.githubusercontent.com/Willxup/bootstrap/main/bootstrap.sh || wget -O bootstrap.sh https://raw.githubusercontent.com/Willxup/bootstrap/main/bootstrap.sh
```

As a regular user, run `sudo bash bootstrap.sh`. The script asks for confirmation at each step by default. Use `bash bootstrap.sh --dry-run` to preview the changes first.

## Configuration file

```bash
curl -fLO https://raw.githubusercontent.com/Willxup/bootstrap/main/bootstrap.sh
curl -fLO https://raw.githubusercontent.com/Willxup/bootstrap/main/bootstrap.conf.example
cp bootstrap.conf.example bootstrap.conf
chmod 600 bootstrap.conf
vim bootstrap.conf

sudo bash bootstrap.sh --dry-run --config bootstrap.conf --yes
sudo bash bootstrap.sh --config bootstrap.conf --yes
```

Git ignores `bootstrap.conf`. The example contains public placeholders only; keep your hostnames, ports, public keys, monitoring addresses, and secrets in your local configuration.

## Resume after a failure

The script stops immediately when a step fails. Completed steps are skipped when resuming:

```bash
sudo ./bootstrap.sh --status
sudo ./bootstrap.sh --config bootstrap.conf --yes --resume
```

The default checkpoint is `/var/lib/bootstrap/state`, and full command output is saved to `/var/log/bootstrap/bootstrap.log`. You can correct the configuration before resuming: new values affect only failed and pending steps, while completed steps are skipped. Use `--reset-state` to discard the previous progress and start a new run.

Checkpoints from v3.0.x are automatically migrated to the current step numbering. NodeQuality now runs last, as step 17, after all configuration steps.

## Common commands

```bash
./bootstrap.sh --list-steps
sudo ./bootstrap.sh --only 05,06
sudo ./bootstrap.sh --skip 11,17
sudo ./bootstrap.sh --hostname server-02 --ssh-port 2222 --only 04,05,06
sudo ./bootstrap.sh --network-profile standard --only 10
sudo ./bootstrap.sh --swap-size 4G --zram-percent 20 --only 12
```

Command-line values override the configuration file. See `./bootstrap.sh --help` for all options and [`bootstrap.conf.example`](bootstrap.conf.example) for configuration settings.

## Network and memory profiles

- `minimal`: enables BBR + FQ only; the conservative default.
- `standard`: also uses 32 MiB TCP buffers, for long-distance direct connections on servers with sufficient memory.
- `low-memory`: uses 8 MiB buffers, for small servers with around 1 GiB of memory.

Swap/ZRam sizes, percentages, priorities, and swappiness can be changed in the configuration file. `swap-size=none` or `zram-percent=0` skips configuring the corresponding component. On Debian 13, the script safely deactivates and resets the old ZRam device before starting it with the new configuration, avoiding an incorrect capacity retained by a plain `restart`.

## Safety considerations

- Before changing SSH settings, confirm that console, VNC, or rescue access is available. Keep the old port temporarily when switching ports for the first time.
- SSH configuration is checked with `sshd -t` after writing; the backup is restored if validation fails.
- Step 11 also sets UFW's `IPV6=no` and reloads UFW when disabling IPv6, preventing further `(v6)` rules.
- Terminal colors written by step 08 apply automatically to new shells. To apply them in the current shell, run `source /etc/profile.d/99-bootstrap.sh`.
- Important configuration files are backed up to `/var/backups/bootstrap/`. Configuration contents and secrets are not stored in checkpoints.
- Nezha and NodeQuality download external scripts. Docker may bypass ordinary UFW rules; review the effective rules for your environment.

## Tests

```bash
bash tests/run.sh
```

License: MIT
