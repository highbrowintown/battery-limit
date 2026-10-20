# battery-limit

Dynamic battery charge-threshold manager for ThinkPads on Fedora (including Fedora Atomic), built to extend battery lifespan.

---

## Table of Contents

1. [Project Overview](#1-project-overview)
2. [Prerequisites](#2-prerequisites)
3. [Project Structure](#3-project-structure)
4. [Getting Started](#4-getting-started)
5. [Managing the Daily Profile](#5-managing-the-daily-profile)
6. [Charging to Full Once](#6-charging-to-full-once)
7. [How Evaluation Is Triggered](#7-how-evaluation-is-triggered)
8. [Running and Inspecting](#8-running-and-inspecting)
9. [Targeting Batteries](#9-targeting-batteries)
10. [Environment Overrides](#10-environment-overrides)
11. [Testing Without Hardware](#11-testing-without-hardware)
12. [One-off Operations](#12-one-off-operations)
13. [Quick Reference](#13-quick-reference)

---

## 1. Project Overview

Lithium-ion batteries wear faster when they sit at a high charge level. ThinkPads let the operating system tell the firmware where to start and stop charging, so you can keep the battery in a narrower, gentler range. `battery-limit` manages those two values for you and adjusts them as your situation changes.

The project handles:

- A daily profile that holds the battery between two percentages (75 to 80 by default)
- A one-shot full charge for days when you need maximum runtime
- Automatic return to the daily profile after that full charge
- Re-applying the thresholds at boot, after resume, and on every power event
- Safe write ordering, because the kernel driver requires start to stay below stop

The key design principle is that the thresholds are a policy, not a one-time setting. The script re-evaluates the policy whenever the power state changes, so the correct limit is always in place.

The thresholds live in the kernel's `thinkpad_acpi` driver under `/sys/class/power_supply/BAT*/`. The end threshold accepts values from 1 to 100. The start threshold accepts values from 0 to 99. Charging stops once the battery goes above the end value and resumes once it drops below the start value.

---

## 2. Prerequisites

Before you install anything, confirm the following:

- A ThinkPad (or another laptop) whose driver exposes `charge_control_end_threshold`
- `git` to clone the repository
- `bash`, `systemd`, and `udev`, which Fedora includes by default
- `sudo` access, because writing thresholds requires root
- No other tool managing thresholds (TLP, or a desktop battery-health setting)

Verify that your battery exposes the controls:

```bash
ls /sys/class/power_supply/BAT0/ | grep charge_control
```

A supported battery prints at least these two lines:

```
charge_control_end_threshold
charge_control_start_threshold
```

> **Note:** If only the end threshold appears, the script still works. It skips the start value and writes only the stop value.

> **Warning:** Two tools that write the same value overwrite each other. If you use TLP, either remove its `STOP_CHARGE_THRESH_BAT0` setting or disable TLP. Fedora also has a battery-health setting that works through a upower hwdb file in `/etc/udev/hwdb.d/`. If your thresholds change back after a reboot, check both.

---

## 3. Project Structure

The repository separates the script, its configuration, and the system integration files. Each file is a plain file you can read and edit.

```
battery-limit/
├── bin/
│   └── battery-limit               # The script: evaluates policy and writes thresholds
├── config/
│   └── battery-limit.conf          # Default daily profile, copied to /etc on first install
├── systemd/
│   └── battery-limit.service.in    # One-shot unit template; @BINDIR@ is filled in at install
├── udev/
│   └── 99-battery-limit.rules      # Starts the unit on every power-supply change
├── tests/
│   └── test.sh                     # Test suite against a simulated sysfs tree
├── .github/workflows/
│   └── ci.yml                      # ShellCheck, tests, and an install smoke test
├── install.sh                      # Copies the files into place and starts the service
├── Makefile                        # "make test" and "make lint" for development
├── LICENSE                         # MIT
└── README.md                       # This file
```

`install.sh` places the files on your system like this:

| Repository file | Installed to |
|---|---|
| `bin/battery-limit` | `/usr/local/bin/battery-limit` |
| `config/battery-limit.conf` | `/etc/battery-limit.conf` (only if it does not exist) |
| `systemd/battery-limit.service.in` | `/etc/systemd/system/battery-limit.service` |
| `udev/99-battery-limit.rules` | `/etc/udev/rules.d/99-battery-limit.rules` |
| (created at install) | `/var/lib/battery-limit/` holds the `full-once` flag while a full charge is pending |

The conf file defines the daily limits, the flag file defines the temporary override, and udev and systemd define when the policy runs.

> **Note:** On Fedora Atomic, `/usr/local` is a symlink to `/var/usrlocal`, and `/etc` is writable and preserved across updates. Every destination above is writable, so you do not layer any packages. `install.sh` uses only `install`, `sed`, and `systemctl`, so it does not need `make`.

---

## 4. Getting Started

Clone the repository and run the installer from the clone. The installer copies the files into place, reloads systemd and udev, and starts the service.

```bash
git clone https://github.com/<your-user>/battery-limit.git
cd battery-limit
sudo ./install.sh
```

The installer ends by printing the current state. Run the same check yourself at any time:

```bash
battery-limit status
```

Expected output:

```
BAT0: 63% Charging | start=75 stop=80
AC online: yes
Full-charge-once pending: no
Daily profile: start=75 stop=80
```

The `start=` and `stop=` values must match your daily profile. If they show other numbers, another tool is overwriting them. See the warning in [Prerequisites](#2-prerequisites).

> **Note:** A status of `Not charging` while plugged in is correct when the battery is above the stop value. The firmware is holding the charge where you asked it to.

---

## 5. Managing the Daily Profile

### Understanding the config file

The daily profile lives in `/etc/battery-limit.conf`. The installer creates it once and never overwrites it on re-install.

```bash
DAILY_START=75      # begin charging below this percentage
DAILY_STOP=80       # stop charging above this percentage
FULL_REVERT_AT=95   # after a full charge, revert to daily once unplugged at or above this
```

A narrow window such as 75 to 80 keeps the battery from cycling while you stay plugged in. The battery self-discharges slowly, and charging resumes only when it falls below the start value.

| Goal | `DAILY_START` | `DAILY_STOP` |
|---|---|---|
| Mostly docked, minimum wear (default) | 75 | 80 |
| General longevity with more usable range | 40 | 80 |
| No limit | 0 | 100 |

### Changing the profile

1. Edit the values:

```bash
sudo nano /etc/battery-limit.conf
```

2. Apply them without waiting for the next power event:

```bash
sudo battery-limit auto
```

3. Confirm the new thresholds:

```bash
battery-limit status
```

> **Warning:** `DAILY_START` must be lower than `DAILY_STOP`, and `DAILY_STOP` must be 100 or less. The script validates this on every command and exits with `need DAILY_START < DAILY_STOP <= 100` if the values are wrong. It writes nothing in that case.

---

## 6. Charging to Full Once

Some days you need the full battery, such as before a flight. The `full` command raises the limit to 0 and 100 for one charge cycle, then returns to the daily profile on its own.

Request a full charge:

```bash
sudo battery-limit full
```

The command creates the flag file `/var/lib/battery-limit/full-once` and re-evaluates immediately. Each later evaluation checks the flag and the power state:

| State | Result |
|---|---|
| Flag set, on AC | Thresholds stay at 0 / 100 |
| Flag set, on battery, charge below `FULL_REVERT_AT` | Thresholds stay at 0 / 100 (you unplugged early) |
| Flag set, on battery, charge at or above `FULL_REVERT_AT` | Flag is removed, daily profile returns |
| No flag | Daily profile applies |

Cancel a pending full charge before it completes:

```bash
sudo battery-limit daily
```

> **Note:** After the revert, the battery keeps its current charge. If it sits at 100%, it stays there until it drains below `DAILY_START`. The script does not discharge the battery.

> **Note:** The early-unplug rule protects you from losing a full charge by accident. If you unplug at 60% and plug back in later, the flag is still set and charging continues to 100%.

---

## 7. How Evaluation Is Triggered

The script holds no background process. systemd runs it as a one-shot unit, and three triggers start that unit.

| Trigger | Mechanism |
|---|---|
| Boot | `WantedBy=multi-user.target` |
| Resume from suspend, hibernate, or hybrid sleep | `WantedBy` and `After` on the sleep targets |
| AC plug, unplug, or battery level change | udev rule with `SYSTEMD_WANTS` |

The unit:

```ini
[Unit]
Description=Apply dynamic battery charge thresholds
After=suspend.target hibernate.target hybrid-sleep.target
StartLimitIntervalSec=0

[Service]
Type=oneshot
ExecStart=/usr/local/bin/battery-limit auto

[Install]
WantedBy=multi-user.target suspend.target hibernate.target hybrid-sleep.target
```

The udev rule:

```
SUBSYSTEM=="power_supply", ACTION=="change", TAG+="systemd", ENV{SYSTEMD_WANTS}="battery-limit.service"
```

`StartLimitIntervalSec=0` disables systemd's start-rate limit. Power events can arrive in bursts, and the default limit would otherwise block the unit.

### Write ordering

The driver rejects any write that would leave start at or above stop. The script picks the order for each change:

- If the new start is at or above the current stop, it writes stop first, then start.
- Otherwise it writes start first, then stop.

The script also compares the current values with the target and writes nothing when they already match.

Watch the events that trigger the unit:

```bash
udevadm monitor --subsystem-match=power_supply
```

---

## 8. Running and Inspecting

### Full run

Evaluate the policy and write the thresholds now:

```bash
sudo battery-limit auto
```

### Introspect

```bash
# Current thresholds, charge, AC state, pending full charge
battery-limit status

# Raw values from the driver
cat /sys/class/power_supply/BAT0/charge_control_start_threshold
cat /sys/class/power_supply/BAT0/charge_control_end_threshold
cat /sys/class/power_supply/BAT0/status

# Unit state and logs since boot
systemctl status battery-limit.service
journalctl -u battery-limit.service -b
```

### Dry run

The script has no dry-run flag. To preview behavior safely, use a simulated sysfs tree. See [Testing Without Hardware](#11-testing-without-hardware).

> **Note:** `status` works without root. Every command that writes thresholds needs `sudo`. Without it, the script exits with `no writable charge_control_end_threshold (need root, or unsupported battery)`.

---

## 9. Targeting Batteries

The script applies the same start and stop values to every `BAT*` entry that has a writable `charge_control_end_threshold`. Batteries without that file are skipped.

Most ThinkPads in this class have one battery, `BAT0`. If you have a second battery, both receive the same profile. The script has no per-battery setting.

List the batteries the script sees:

```bash
ls -d /sys/class/power_supply/BAT*
```

> **Note:** If no battery qualifies, the script exits with an error rather than reporting success. This is the signal that your hardware or driver does not expose threshold control.

---

## 10. Environment Overrides

Three environment variables redirect the script. You use them for testing and for non-standard layouts.

| Variable | Default | Purpose |
|---|---|---|
| `PS_ROOT` | `/sys/class/power_supply` | Directory the script scans for `BAT*` and AC entries |
| `BATTERY_LIMIT_CONF` | `/etc/battery-limit.conf` | Config file to read |
| `BATTERY_LIMIT_STATE` | `/var/lib/battery-limit` | Directory that holds the `full-once` flag |

Run the script against alternate paths:

```bash
PS_ROOT=/tmp/fake/ps BATTERY_LIMIT_STATE=/tmp/fake/state battery-limit status
```

---

## 11. Testing Without Hardware

Combine the three overrides to run the whole policy against a fake battery. Nothing touches your real thresholds, and you do not need root.

1. Build a simulated tree that starts in the stuck 63% state:

```bash
T=$(mktemp -d)
mkdir -p "$T/ps/BAT0" "$T/ps/AC" "$T/state"
echo 63 > "$T/ps/BAT0/charge_control_end_threshold"
echo 0  > "$T/ps/BAT0/charge_control_start_threshold"
echo 50 > "$T/ps/BAT0/capacity"
echo "Not charging" > "$T/ps/BAT0/status"
echo Mains > "$T/ps/AC/type"
echo 1 > "$T/ps/AC/online"
```

2. Point the script at the tree and apply the daily profile:

```bash
export PS_ROOT="$T/ps" BATTERY_LIMIT_STATE="$T/state" BATTERY_LIMIT_CONF=/nonexistent
battery-limit auto
battery-limit status
```

Expected output:

```
BAT0: 50% Not charging | start=75 stop=80
AC online: yes
Full-charge-once pending: no
Daily profile: start=75 stop=80
```

3. Walk through a full charge and the automatic revert:

```bash
battery-limit full                                   # thresholds become 0 / 100
echo 0  > "$PS_ROOT/AC/online"                       # unplug
echo 60 > "$PS_ROOT/BAT0/capacity"
battery-limit auto                                   # stays 0 / 100 (unplugged early)
echo 100 > "$PS_ROOT/BAT0/capacity"
battery-limit auto                                   # reverts to 75 / 80
```

> **Note:** This tree simulates the files, not the firmware. It verifies the script's logic and write ordering. It does not verify how your specific ThinkPad firmware or driver responds. Run `battery-limit status` on the real machine after installing.

### Project test suite

The repository includes a test suite that builds simulated trees like the one above and checks the policy: daily profile, full charge and revert, custom and invalid config, write ordering, a missing start file, and a missing battery.

```bash
bash tests/test.sh
```

Expected output ends with:

```
passed: 20  failed: 0
```

Lint the shell files with ShellCheck:

```bash
shellcheck bin/battery-limit install.sh tests/test.sh
```

`make test` and `make lint` run the same two commands. The CI workflow in `.github/workflows/ci.yml` runs both, plus an install and uninstall smoke test into a staging directory, on every push to `main` and every pull request.

### Staging an install

`install.sh` accepts `DESTDIR` and `BINDIR`. With `DESTDIR` set, it writes under that directory and skips the systemd and udev steps. Use it to inspect what the installer produces without touching your system:

```bash
d=$(mktemp -d)
DESTDIR="$d" ./install.sh
find "$d" -type f
```

---

## 12. One-off Operations

### Set a threshold by hand

Write a value straight to the driver:

```bash
echo 100 | sudo tee /sys/class/power_supply/BAT0/charge_control_end_threshold
```

> **Warning:** The next boot, resume, or power event re-applies your policy and overwrites this value. For a temporary full charge, use `battery-limit full` instead.

### Pause the tool

Stop the policy from running:

```bash
sudo systemctl mask --now battery-limit.service
```

Resume it:

```bash
sudo systemctl unmask battery-limit.service
sudo battery-limit auto
```

> **Warning:** `systemctl disable` does not pause the tool. The udev rule starts the unit directly, so only `mask` blocks it.

### Uninstall

Run it from the clone:

```bash
sudo ./install.sh --uninstall
```

The uninstaller removes the script, the unit, and the udev rule. It keeps `/etc/battery-limit.conf` and `/var/lib/battery-limit`.

> **Warning:** The firmware stores the thresholds, and they can survive an OS change. After you uninstall, reset them if you want an unrestricted battery. Write start first, then stop:
>
> ```bash
> echo 0   | sudo tee /sys/class/power_supply/BAT0/charge_control_start_threshold
> echo 100 | sudo tee /sys/class/power_supply/BAT0/charge_control_end_threshold
> ```

---

## 13. Quick Reference

### Commands

| Command | What it does |
|---|---|
| `battery-limit status` | Show thresholds, charge, AC state, and pending full charge |
| `sudo battery-limit auto` | Evaluate the policy and write thresholds now |
| `sudo battery-limit daily` | Cancel any pending full charge and apply the daily profile |
| `sudo battery-limit full` | Charge to 100% once, then revert after unplugging |

### Configuration

| Setting | Default | Meaning |
|---|---|---|
| `DAILY_START` | 75 | Charging begins below this percentage |
| `DAILY_STOP` | 80 | Charging stops above this percentage |
| `FULL_REVERT_AT` | 95 | Minimum charge at unplug to end a full-charge cycle |

### Common command patterns

```bash
# Install
git clone https://github.com/<your-user>/battery-limit.git
cd battery-limit
sudo ./install.sh

# Check current state
battery-limit status

# Change the daily window, then apply it
sudo nano /etc/battery-limit.conf
sudo battery-limit auto

# Charge to 100% before travel
sudo battery-limit full

# Cancel the full charge
sudo battery-limit daily

# Follow the logs
journalctl -u battery-limit.service -b

# Watch the power events that trigger the unit
udevadm monitor --subsystem-match=power_supply

# Pause and resume
sudo systemctl mask --now battery-limit.service
sudo systemctl unmask battery-limit.service

# Run the tests and lint
bash tests/test.sh
shellcheck bin/battery-limit install.sh tests/test.sh

# Uninstall
sudo ./install.sh --uninstall
```
