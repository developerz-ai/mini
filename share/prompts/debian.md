# Debian family

apt + systemd. Applies to Debian, Ubuntu, Zorin, Mint, Pop!_OS, Raspberry Pi OS.

## No systemd on this host

If the host memory says `Init: not systemd`, PID 1 is not systemd: `systemctl`
and `journalctl` fail with "System has not been booted with systemd as init
system", so the systemd half of this playbook does not apply — skip
`systemctl`, `journalctl` and every unit edit. Use this host's own init
instead (`rc-service`/`rc-status` on OpenRC, `service` on SysVinit, `sv status`
on runit) and read logs from `/var/log/` or `dmesg`. Never install systemd, and
never install the `systemctl` package to "fix" this: the package is not the
problem, and installing it changes nothing.

## Diagnose in this order

It finds the cause faster than guessing:

```bash
systemctl --failed --no-pager          # broken now
journalctl -p err -b --no-pager | tail -50
df -h; df -i                           # full disk AND full inodes
free -h                                # memory, swap
uptime                                 # load vs nproc
sudo -n dmesg -T --level=err,warn       # OOM, disk, hardware
ss -tulpn                              # what listens
```

If kernel reads fail, try `journalctl -k -b --no-pager -p warning` (use
`sudo -n` if restricted). Keep access errors visible; never infer read success
from `tail`'s exit status. Denied/unavailable logs mean unknown evidence, not
"no kernel errors".

Usual causes, in the order they actually occur: disk full → inodes full → OOM
kill → config typo → permission denial → DNS → firewall.

## Packages

```bash
apt-cache policy <pkg>                 # installed? candidate? which repo?
sudo -n apt-get update -qq
sudo -n DEBIAN_FRONTEND=noninteractive apt-get install -y <pkg>
dpkg -S /path/to/file                  # who owns this file
sudo -n apt --fix-broken install
```

`DEBIAN_FRONTEND=noninteractive` on every install — an interactive prompt hangs
you forever. Third-party repos: a file in `/etc/apt/sources.list.d/`, key in
`/etc/apt/keyrings/`, `signed-by=` in the source line. `apt-key` is dead. Never
`apt upgrade` mid-debug; it changes too much to reason about.

## Services

```bash
systemctl status <unit> --no-pager -l
journalctl -u <unit> -n 200 --no-pager
journalctl -u <unit> --since "10 min ago" -p err --no-pager
systemctl cat <unit>                   # real unit + drop-ins
sudo -n systemctl daemon-reload        # after ANY unit edit
```

Override with `systemctl edit <unit>`, never by editing `/lib/systemd/system/`.
Try `reload` before `restart`. Always `--no-pager`, or you hang on a pager.

## Firewall — the lockout rule

```bash
sudo -n ufw allow OpenSSH              # ALWAYS before enabling
sudo -n ufw enable
sudo -n ufw status numbered
```

If nftables/iptables rules already exist, read them first. Two firewalls
disagreeing is its own outage.

## Disk pressure

```bash
du -xh --max-depth=1 / 2>/dev/null | sort -rh | head -20
journalctl --disk-usage; sudo -n journalctl --vacuum-size=200M
sudo -n apt-get clean
docker system df
dpkg -l 'linux-image-*' | grep ^ii     # old kernels
```

`uname -r` is the running kernel. Never remove it.

## Users

```bash
id <user>
sudo -n usermod -aG <group> <user>     # -a, or you wipe their other groups
```

Group changes need a fresh login. Say so, or it looks like it failed.

## Before you break something

Validate first: `nginx -t`, `sshd -t`, `visudo -c`, `systemd-analyze verify`.
Back up first: `sudo -n cp /etc/x.conf /etc/x.conf.bak.$(date +%s)`.
Long jobs: `nohup … &` — a dying shell takes its children with it.
