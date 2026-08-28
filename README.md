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

## Language

English is the default. Pass `--lang zh` to run in Simplified Chinese, or `--lang en` to explicitly select English:

```bash
sudo bash bootstrap.sh --lang zh
bash bootstrap.sh --lang zh --help
bash bootstrap.sh --lang zh --dry-run
```

The language option applies to help, prompts, step names, errors, checkpoint status, and the script's own log messages. It works before or after other options, including `--help`, `--status`, and `--resume`.

You can also set the `BOOTSTRAP_LANG` environment variable to `en` or `zh`; `--lang` takes precedence. This is an environment variable, not a configuration-file setting. With `sudo`, pass it explicitly using `sudo env BOOTSTRAP_LANG=zh bash bootstrap.sh`. System locale variables such as `LANG` do not select the script language, and the script does not change the system locale. Output from system commands and external installers remains unchanged. Switching languages does not reset checkpoints or rerun completed steps.

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
sudo bash bootstrap.sh --status
sudo bash bootstrap.sh --config bootstrap.conf --yes --resume
```

The default checkpoint is `/var/lib/bootstrap/state`, and full command output is saved to `/var/log/bootstrap/bootstrap.log`. You can correct the configuration before resuming: new values affect only failed and pending steps, while completed steps are skipped. Use `--reset-state` to discard the previous progress and start a new run.

Checkpoints from v3.0.x are automatically migrated to the current step numbering. NodeQuality now runs last, as step 17, after all configuration steps.

NodeQuality is an optional external test. Bootstrap displays its output and reports when it ends, without interpreting its results or treating its exit code as an initialization failure. Once it ends, resuming does not run it again; use `sudo bash bootstrap.sh --only 17` to run it separately. Download or launch errors are reported, and interrupting bootstrap still stops the run.

## Common commands

```bash
bash bootstrap.sh --list-steps
sudo bash bootstrap.sh --only 05,06
sudo bash bootstrap.sh --skip 11,17
sudo bash bootstrap.sh --hostname server-02 --ssh-port 2222 --only 04,05,06
sudo bash bootstrap.sh --network-profile standard --only 10
sudo bash bootstrap.sh --swap-size 4G --zram-percent 20 --only 12
```

Command-line values override the configuration file. See `bash bootstrap.sh --help` for all options and [`bootstrap.conf.example`](bootstrap.conf.example) for configuration settings.

Step numbers accept one or two digits (`5` or `05`); longer forms such as `005` are rejected.

## Network and memory profiles

- `minimal`: enables BBR + FQ only; the conservative default.
- `standard`: also uses 32 MiB TCP buffers, for long-distance direct connections on servers with sufficient memory.
- `low-memory`: uses 8 MiB buffers, for small servers with around 1 GiB of memory.

Swap/ZRam sizes, percentages, priorities, and swappiness can be changed in the configuration file. `swap-size=none` or `zram-percent=0` skips configuring the corresponding component. On Debian 13, the script safely deactivates and resets the old ZRam device before starting it with the new configuration, avoiding an incorrect capacity retained by a plain `restart`.

## Safety considerations

- If `/etc/docker/daemon.json` already exists, step 14 asks whether to keep it (`1`, the default) or overwrite it with the script's defaults (`2`). `--yes` and `--dry-run` keep existing configuration. Overwriting creates a backup first; a failed Docker restart restores it. Keeping the file also skips the script's configuration restart, although package installation or upgrades may still affect the service.
- Before changing SSH settings, confirm that console, VNC, or rescue access is available, and allow the new port in your provider's firewall. `BOOTSTRAP_KEEP_OLD_SSH_PORT=true` retains only the old port's UFW rule; it does not keep SSH listening on the old port.
- SSH configuration is checked with `sshd -t` after writing; the backup is restored if validation fails.
- UFW automatically uses the SSH port applied in this run, or reads the existing SSH configuration when no change was made. It confirms the SSH ports, 80/tcp, and 443/tcp before enabling the firewall, without asking you to enter a port. If the SSH ports cannot be read, it stops before enabling UFW.
- Step 11 also sets UFW's `IPV6=no` and reloads UFW when disabling IPv6, preventing further `(v6)` rules.
- Terminal colors written by step 08 apply automatically to new shells. To apply them in the current shell, run `source /etc/profile.d/99-bootstrap.sh`.
- Important configuration files are backed up to `/var/backups/bootstrap/`. Configuration contents and secrets are not stored in checkpoints.
- Nezha and NodeQuality download external scripts. Docker may bypass ordinary UFW rules; review the effective rules for your environment.

## Tests

```bash
bash tests/run.sh
```

License: MIT
