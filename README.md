# SpinDoctor – Fan & Temperature Control via Linux hwmon

SpinDoctor is a lightweight Python tool that dynamically controls system fans based on temperature readings exposed through Linux hwmon.
It is designed for servers, NAS systems, and custom hardware setups where fan curves must be controlled manually.

The tool reads temperature sensors (CPU, NVMe, HDD via drivetemp, board sensors, etc.) and adjusts PWM fan speeds accordingly.

---------------------------------------------------------------------

## Features

- Reads temperature values from Linux sysfs (`/sys/class/hwmon/…`)
- Supports:
  - Named hwmon devices (matched via their `name` file)
  - Disk-based sensors (via `drivetemp`)
  - Explicit hwmon paths
  - Multiple sensors per fan
- Calculates dynamic PWM values based on min/max temperature thresholds
- Adjustable sleep interval depending on temperature slope (faster polling near the max threshold)
- Safety fallback: if no configured temperature sensor can be found or read, all fans are forced to maximum speed
- Robust error handling and logging (missing/unreadable sensors and fans only produce warnings, they don't stop the daemon)
- Fully configurable via JSON
- A companion load-test tool (`spindoctor-loadtest`) to verify the fan control actually reacts to CPU load

---------------------------------------------------------------------

## Requirements

- Linux system with hwmon support
- Python 3.8+
- Fan controllers and sensors exposed under `/sys/class/hwmon`
- Root privileges (or matching udev rules) to write PWM values
- Optional: `drivetemp` kernel module for HDD/SSD temperature sensors

Load `drivetemp` if needed:

```bash
sudo modprobe drivetemp
```

To load it automatically on boot, add it to `/etc/modules-load.d/`:

```bash
echo drivetemp | sudo tee /etc/modules-load.d/drivetemp.conf
```

---------------------------------------------------------------------

## Installation

### Option A: via Makefile (recommended)

From the repository root:

```bash
sudo make install
```

This installs:

- `spindoctor` → `/usr/local/sbin/spindoctor`
- `config/qnap-ts-453d.json` → `/etc/spindoctor.json` (edit this for your hardware, see below)
- `systemd/spindoctor.service` → `/etc/systemd/system/spindoctor.service`
- `udev/99-spindoctor-pwm.rules` → `/etc/udev/rules.d/99-spindoctor-pwm.rules`

…and enables the systemd service.

### Option B: manual copy

```bash
sudo cp spindoctor /usr/local/sbin/spindoctor
sudo chmod +x /usr/local/sbin/spindoctor
sudo cp config/qnap-ts-453d.json /etc/spindoctor.json
```

Then edit `/etc/spindoctor.json` for your own sensors and fans (see "Configuration File" below).

---------------------------------------------------------------------

## Running SpinDoctor

Start manually (must run as root to write PWM values):

```bash
sudo /usr/local/sbin/spindoctor
```

Or run it as a systemd service:

```bash
sudo systemctl enable spindoctor.service
sudo systemctl start spindoctor.service
```

SpinDoctor always reads its configuration from `/etc/spindoctor.json` — there is no command-line flag to point it elsewhere.

---------------------------------------------------------------------

## Logging

SpinDoctor logs to stderr using Python's `logging` module.

Log levels:

- **INFO** – normal operation
- **WARNING** – a configured temperature sensor or fan could not be found, read, or written; individual relations referencing an unknown sensor/fan
- **ERROR** – invalid config (e.g. an inverted min/max range), a relation referencing a fan/sensor that failed to initialize, or *all* configured fans being unusable (none could be found or written to)
- **CRITICAL** – configuration file cannot be loaded at startup
- **EXCEPTION** – unexpected runtime errors in the control loop

Safety behavior worth knowing:

- If a single sensor or fan is missing or fails to read/write, only that device is skipped (with a warning) — the rest keep working.
- If **none** of the configured temperature sensors can be found or read (e.g. all drives spun down/removed, a driver not loaded), every configured fan is set to its maximum PWM value as a safety fallback, and polling speeds up until a sensor becomes available again.
- If **none** of the configured fans can be found or written to, an error is logged every cycle since fan control is effectively inactive.

View logs (when running via systemd):

```bash
journalctl -u spindoctor -f
```

---------------------------------------------------------------------

## Configuration File (`/etc/spindoctor.json`)

The configuration file defines:

1. Temperature sensors
2. Fans
3. Relations (which sensors control which fans)

All three top-level keys (`temperature_sensors`, `fans`, `relations`) are required, though their contents may be empty.

## Configuration Structure

```json
{
  "temperature_sensors": {
    "<sensor-name>": {
      "name": "<hwmon-name>",
      "temp_id": 1,
      "min": "40000",
      "max": "80000",
      "crit": "90000"
    }
  },
  "fans": {
    "<fan-name>": {
      "name": "<hwmon-name>",
      "fan_id": 1,
      "pwm_id": 1,
      "lowest": 0,
      "highest": 255
    }
  },
  "relations": {
    "<fan-name>": ["<sensor-name>", "<sensor-name>"]
  }
}
```

---------------------------------------------------------------------

## Field Explanation

### temperature_sensors

Each entry defines a temperature source. Exactly one of `name`, `disk`, or `hwmon` is used to locate the device:

- `name` – matches a hwmon device by its `name` file (e.g. `k10temp`, `acpitz_0`, `nvme`)
- `disk` – resolves the hwmon device attached to a block device via `drivetemp`, e.g. `/dev/sda` or a stable path such as `/dev/disk/by-bay/1`
- `hwmon` – an explicit hwmon path, e.g. `/sys/class/hwmon/hwmon3`

Other fields:

- `temp_id` – selects which `tempX_input` file to read (default: `1`)
- `min` / `max` – temperature thresholds in millidegrees Celsius (e.g. `"40000"` = 40 °C). If given here, these override values are used instead of reading `tempX_min`/`tempX_max` from sysfs — most consumer sensors don't expose those files, so setting them explicitly is the normal case.
- `crit` – optional critical temperature threshold, for reference/future use

### fans

Each entry defines a controllable fan. Exactly one of `name` or `hwmon` is used to locate the device (same semantics as above; disk-based fans are not supported).

- `name` / `hwmon` – locates the hwmon device
- `fan_id` – selects `fanX_input` for RPM readback (default: `1`)
- `pwm_id` – selects `pwmX` for speed control (default: `1`)
- `lowest` – PWM value written when temperature is at or below `min` (typically `0`)
- `highest` – PWM value written when temperature is at or above `max` (typically `255`, full speed)

`lowest`/`highest` are required config values, not sysfs files — a plain PWM device has no such attributes.

### relations

Defines which sensors influence which fan. A fan is driven by the **highest** PWM value required by any of its sensors.

```json
"relations": {
  "case_fan": ["cpu_temp", "nvme_temp"]
}
```

---------------------------------------------------------------------

## Example Configuration

```json
{
  "temperature_sensors": {
    "cpu_temp": {
      "name": "k10temp",
      "temp_id": 1,
      "min": "40000",
      "max": "80000"
    },
    "nvme_temp": {
      "disk": "/dev/nvme0n1",
      "temp_id": 1,
      "min": "37000",
      "max": "60000"
    }
  },

  "fans": {
    "case_fan": {
      "name": "pwmfan",
      "fan_id": 1,
      "pwm_id": 1,
      "lowest": 0,
      "highest": 255
    }
  },

  "relations": {
    "case_fan": ["cpu_temp", "nvme_temp"]
  }
}
```

A real-world, multi-sensor example (QNAP TS-453D, board sensors + 4 drive bays + an M.2 add-on card) ships in [`config/qnap-ts-453d.json`](config/qnap-ts-453d.json) and is used as the default config by `make install`.

This example is known to work on a QNAP TS-453D with the following two kernel drivers loaded:

- [`qnap8528`](https://github.com/0xGiddi/qnap8528) – exposes the IT8528 embedded controller (board temperatures, case fans)
- [`qm2mod`](https://github.com/0xGiddi/qnap-qm2) – exposes the fan and temperature sensor of the QM2 M.2 expansion card

---------------------------------------------------------------------

## PWM Calculation

- If `temp <= min` → `lowest` PWM
- If `temp >= max` → `highest` PWM, next poll happens after 1s instead of the default interval
- Otherwise → linear interpolation between `lowest` and `highest`; the polling interval also scales down as the temperature approaches `max`
- A fan driven by multiple sensors receives the **maximum** PWM value required by any of them
- Default polling interval is 10s when temperatures are comfortably below `max`

---------------------------------------------------------------------

## Testing: `spindoctor-loadtest`

`spindoctor-loadtest` is a black-box smoke test: it stresses all CPU cores and checks whether the PWM value of your configured fans actually rises in response. It does **not** control any fan itself — it only observes — so a `spindoctor` daemon (or another controller) must already be running against the same configuration and hardware for the test to be meaningful.

Run it (usually as root, since reading `pwm*` may otherwise be restricted):

```bash
sudo ./spindoctor-loadtest
```

Options:

```
-c, --config PATH     Path to the spindoctor config (default: /etc/spindoctor.json)
-d, --duration SECS   Maximum test duration in seconds (default: 30)
```

Behavior:

1. Reads the baseline PWM value of every configured fan.
2. Spawns one CPU-bound worker process per core, running for up to `--duration` seconds.
3. Samples each fan's PWM value once per second while the load runs.
4. Reports the baseline and peak PWM value per fan, then prints one of:
   - `POSITIV: PWM-Wert(e) gestiegen bei Fan(s): <names>` and exits with code `0` if at least one fan's PWM increased
   - `NEGATIV: Keine Erhoehung der PWM-Werte waehrend der CPU-Last erkannt` and exits with code `1` if none did

A negative result usually means: the daemon isn't running, the poll interval/thresholds haven't had time to react within the test duration, or the fan/PWM file can't be read.

---------------------------------------------------------------------

## Troubleshooting

### No hwmon device found
Check drivetemp:
```bash
lsmod | grep drivetemp
```

### Permission denied
Run as root, or adjust udev rules (see `udev/99-spindoctor-pwm.rules`) to grant write access to the relevant `pwm*` files.

### Temperature always 0
Some sensors require enabling:
```bash
echo 1 | sudo tee /sys/class/hwmon/hwmonX/pwm1_enable
```

### Log full of "could not be found or read" warnings
Check that the referenced hwmon `name`, `disk`, or `hwmon` path in the config actually exists under `/sys/class/hwmon/`, and that any kernel module it depends on (e.g. `drivetemp`) is loaded.

### All fans running at full speed unexpectedly
This is the safety fallback: it means none of the configured temperature sensors could be found or read. Check the WARNING log lines for the underlying cause.

## License

This project is licensed under the GNU General Public License v3 (GPLv3).

Copyright (c) 2024  
Author: Daniel Versick  
Contact: da-ve@gmx.de

You may redistribute and/or modify this software under the terms of the
GNU General Public License as published by the Free Software Foundation,
version 3 of the License.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program. If not, see:
https://www.gnu.org/licenses/gpl-3.0.en.html
