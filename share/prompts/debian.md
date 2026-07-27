# This box: Debian family

apt, systemd, and the conventions that go with them. Use these patterns; they
are what works on Debian, Ubuntu, Zorin, Mint, Pop!_OS and Raspberry Pi OS.

## Packages

```bash
apt-cache policy <pkg>                  # installed? candidate? which repo?
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y <pkg>
apt list --installed 2>/dev/null | grep -i <name>
dpkg -L <pkg>                           # what did it put where
dpkg -S /path/to/file                   # which package owns this
```

- `DEBIAN_FRONTEND=noninteractive` on every install — an interactive prompt
  will hang you forever.
- Third-party repos go in `/etc/apt/sources.list.d/*.list` with the key in
  `/etc/apt/keyrings/*.gpg` and `signed-by=` in the source line. `apt-key` is
  dead; do not use it.
- Held or broken packages: `apt-mark showhold`, `sudo apt --fix-broken install`.
- Never `apt upgrade` mid-debug unless the fix is a package update. It changes
  too much at once to reason about.

## Services

```bash
systemctl status <unit> --no-pager -l
systemctl is-active <unit>; systemctl is-enabled <unit>
journalctl -u <unit> -n 200 --no-pager
journalctl -u <unit> --since "10 min ago" -p err --no-pager
systemctl cat <unit>                    # the real unit file plus drop-ins
systemctl list-dependencies <unit>
systemctl daemon-reload                 # after ANY unit file edit
```

- Override units with `systemctl edit <unit>` (a drop-in), never by editing the
  vendor file in `/lib/systemd/system/`.
- `systemctl reload` before `restart` when the service supports it.
- Boot-time problems: `systemd-analyze blame`, `systemctl --failed`.

## Diagnosis order

Work down this list — it finds the cause faster than guessing:

```bash
systemctl --failed --no-pager           # what is broken right now
journalctl -p err -b --no-pager | tail -50   # errors this boot
df -h; df -i                            # full disk AND full inodes
free -h                                 # memory and swap
uptime                                  # load vs core count
dmesg -T --level=err,warn | tail -30    # hardware, OOM kills, filesystem
ss -tulpn                               # what is listening
```

Classic causes, in the order they actually happen: disk full → inodes full →
OOM killer → a config typo → a permission or SELinux/AppArmor denial → DNS →
the firewall.

## Network

```bash
ss -tulpn                               # listening sockets + owning process
ss -tn state established                # who is connected
ip -brief addr; ip route
resolvectl status                       # DNS on systemd-resolved boxes
curl -sS -o /dev/null -w '%{http_code} %{time_total}s\n' <url>
```

## Firewall

`ufw` is the Debian-family default. **The rule that saves you:** allow SSH
before enabling the firewall.

```bash
sudo ufw allow OpenSSH        # ALWAYS first
sudo ufw enable
sudo ufw status numbered
```

If `iptables`/`nftables` rules are already in place, read them before adding
ufw on top — two firewalls disagreeing is its own outage.

## Logs

```bash
journalctl -f                           # follow everything
journalctl --since today -p warning --no-pager
journalctl --disk-usage; sudo journalctl --vacuum-size=200M
ls -lt /var/log/ | head                 # apps that do not use journald
```

## Disk pressure

```bash
du -xh --max-depth=1 / 2>/dev/null | sort -rh | head -20
journalctl --disk-usage
sudo apt-get clean                      # /var/cache/apt
docker system df                        # if docker is here
dpkg -l 'linux-image-*' | grep ^ii      # old kernels; keep the running one
```

`uname -r` tells you the running kernel. Never remove it.

## Users and permissions

```bash
id <user>; groups <user>
sudo usermod -aG <group> <user>         # -a or you wipe their other groups
```

Group changes need a new login to take effect. Say so instead of letting the
user think it failed.

## Idioms that keep you out of trouble

- `sudo -n true` tells you whether sudo works without a password prompt.
- Long jobs need `nohup … &` or `systemd-run --user --scope`; a shell that dies
  takes its children with it.
- Back up before editing: `sudo cp /etc/foo.conf /etc/foo.conf.bak.$(date +%s)`
- Validate before reloading: `nginx -t`, `sshd -t`, `visudo -c`.
