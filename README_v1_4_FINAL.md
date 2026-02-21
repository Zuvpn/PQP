# PQP v1.4 FINAL (Stable Installer + Wizard)

Date: 2026-02-21

## What's fixed
- Installer waits for apt/dpkg locks (no more 'Could not get lock')
- Installer validates downloaded pqp.sh contains required functions (prevents partial/old GitHub file issues)
- Wizard Option 2 always shows:
  1) Iran (Client)
  2) Kharej (Server)

## How to publish to GitHub (recommended)
Upload these two files to your repo root:
- pqp.sh
- install.sh

Then install on servers:
```bash
wget https://raw.githubusercontent.com/Zuvpn/PQP/main/install.sh
chmod +x install.sh
sudo bash install.sh
sudo pqp
```
