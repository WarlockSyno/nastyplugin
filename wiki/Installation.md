# Installation

## Install

```bash
dpkg -i nasty-proxmox-plugin_*.deb
```

If there are missing dependencies:

```bash
apt-get install -f
```

After installation, restart the PVE storage daemon:

```bash
systemctl restart pvedaemon pveproxy
```

## Remove

```bash
dpkg -r nasty-proxmox-plugin
systemctl restart pvedaemon pveproxy
```

## Build from Source

```bash
tools/build-deb.sh
```

The resulting `.deb` is written to the repo root.
