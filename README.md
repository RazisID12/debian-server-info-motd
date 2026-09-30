# Debian Server Info MOTD

Lightweight dynamic system information MOTD for Debian 13 servers.

It displays a compact system summary on SSH and local console logins. The same
information is also available at any time through the `server-info` command.

> **Target platform:** Debian 13 (trixie).

## Features

- Debian version and codename, kernel, and architecture
- Physical machine, virtual machine, or container detection
- Human-readable uptime
- CPU model, topology, and current utilization
- Load average, memory, swap, and root filesystem usage
- Independent IPv4 and IPv6 interface detection
- Multiple global addresses per selected interface
- Process and login session counts
- Graceful fallback when optional system information is unavailable
- Manual output without the welcome message through `server-info`
- Optional management of OpenSSH's native `Last login` notice
- Managed installation, updates, repair, rollback, and uninstallation

## Compatibility

| Area | Target or verified environment |
| --- | --- |
| Target | Debian 13 (trixie) |
| Runtime — KVM | Debian 13 on KVM virtual machines |
| Login surfaces | Interactive OpenSSH and local console sessions using `/etc/update-motd.d` |
| Manual command | On-demand output through `server-info` |
| Installer lifecycle | Install, update, repair, rollback, and uninstall |
| OpenSSH integration | Optional managed `PrintLastLog` drop-in for Debian `ssh.service` |

The core MOTD requires `wget`, `sha256sum`, `run-parts`, `sleep`, and `cmp`.
Network information uses the `ip` command from `iproute2`; the remaining system
summary still renders when it is unavailable.

The installer requires root privileges, directly or through `sudo`. Optional
management of the native `Last login` notice requires `openssh-server` and an
active Debian `ssh.service`; the MOTD itself does not require OpenSSH.

## Example output

```text
Welcome to debian-server running Debian 13 (trixie)

System information as of 02.09.2026 15:11 UTC

  Kernel:                  6.12.105+deb13-amd64, x86_64
  System type:             Virtual machine (KVM)
  Uptime:                  7 days, 12 hours, 36 minutes

  CPU:                     AMD EPYC 9575F 64-Core Processor · 1 vCPU (7%)
  Load average:            0.02 · 0.02 · 0.00 (1m · 5m · 15m)
  Memory:                  0.37 / 1.93 GiB (19%)
  Swap:                    0 / 1.58 GiB (0%)
  Disk (/):                2.31 / 27.8 GiB (9%)

  IPv4 for ens3:           192.0.2.10
  IPv6 for ens3:           2001:db8::10
  Processes:               92
  Login sessions:          2
```

## Install

The recommended installation uses the current verified release,
[`v0.3.1`](https://github.com/RzandAl/debian-server-info-motd/releases/tag/v0.3.1):

```bash
wget --quiet --https-only -O- \
https://raw.githubusercontent.com/RzandAl/debian-server-info-motd/v0.3.1/install.sh |
sudo bash -s -- --source-ref v0.3.1
```

Select **Install** from the interactive menu. When already logged in as root,
omit `sudo`. Open a new SSH or local console session after installation to see
the MOTD.

The installer downloads every managed file from the same Git reference,
verifies its checksum and Bash syntax, and attempts automatic rollback if a
managed operation fails.

## Quick use

Show the same system information without the welcome message:

```bash
server-info
```

Show command help:

```bash
server-info --help
```

Run the installer again to update, repair, configure OpenSSH's native
`Last login` notice, or uninstall the project.

## Documentation

- [Installer, source references, verification, managed paths, and rollback](docs/INSTALLER.md)
- [Continuous integration checks](.github/workflows/ci.yml)

## Tests and validation

The repository CI validates executable modes, project versioning, installer
arguments, Bash syntax, checksum consistency, output formatting, OpenSSH
`Last login` ownership and rollback behavior, and ShellCheck results.

Run the repository-owned checks from the project root:

```bash
bash -n \
    install.sh \
    etc/update-motd.d/10-server-info \
    usr/local/bin/server-info

sha256sum -c SHA256SUMS
sudo tests/test-last-login-management.sh
```

Interactive MOTD and manual-command behavior were also validated on Debian 13
KVM servers.

## Maintainers

Developed and tested together by [AmleyID](https://github.com/AmleyID) and
[RazisID12](https://github.com/RazisID12).

## License

[MIT](LICENSE)
