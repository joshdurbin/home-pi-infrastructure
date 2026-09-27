# Setup Role

Prepares Raspberry Pi instances for k3s by optimizing for minimal resource usage and installing essential packages.

## What It Does

- Disables unnecessary hardware (Bluetooth, WiFi, audio, camera, HAT interfaces)
- Reduces GPU memory allocation to 16MB
- Enables kernel cgroups for Kubernetes
- Disables unnecessary services and daemons
- Installs essential packages for system administration
- Configures locale, timezone, and keyboard layout
- Applies a per-board-model mild overclock (see below)

## Variables

See `group_vars/all/main.yaml`:
- `timezone` - System timezone (default: America/Los_Angeles)
- `keyboard_layout` - Keyboard layout (default: us)
- `locale` - System locale (default: en_US.UTF-8)

## Tags

- `setup` - Run all setup tasks
- `kill_radios` - Disable Bluetooth/WiFi only
- `kill_audio` - Disable audio only
- `enable_cgroups` - Enable kernel cgroups only
- `k3s_optimization` - GPU/camera/HAT optimizations only
- `blacklist_modules` - Kernel module blacklisting only
- `user_management` - User management only
- `remove_services` - Remove unnecessary services only

## Dependencies

- Raspberry Pi OS (64-bit, Lite)
- Python 3

## Hardware Impact

Frees approximately 200-400MB of RAM per node by disabling:
- On-board Bluetooth
- WiFi
- Audio subsystem (ALSA)
- Camera interface
- I2C, SPI, 1-Wire interfaces
- HDMI output
- GPU memory (reduced from 128MB to 16MB)
- mpris-proxy
- avahi-daemon
- unattended-upgrades

## Overclocking

Applied per `board_model` (set in `group_vars/{pi4,pi5}/main.yaml`, not by inventory group name or
hostname — see `tasks/k3s_hardware_optimization.yml`):

- **Pi 4**: no overclock. `arm_boost=1` was tried (Raspberry Pi's documented zero-voltage turbo step,
  1.5GHz → 1.8GHz on rev 1.4/1.5 boards) but confirmed to have **zero effect** on these boards — they're
  rev 1.1, which lacks the regulator headroom for it. Verified by direct measurement
  (`/sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq`) after a real reboot, not assumed. The line is
  actively removed (`state: absent`) rather than left inert, so it won't reappear from a future OS image.
- **Pi 5**: `arm_freq=2600` (stock 2400MHz), no `over_voltage_delta`. Community-tested stable at this
  frequency without a voltage bump; the Pi 5's own DVFS supplies the needed voltage automatically.
  Confirmed live at 2600MHz on all 3 Pi 5 nodes after reboot.

To check a real board's revision before assuming any documented overclock step applies to it:
`cat /proc/cpuinfo | grep Revision` (cross-reference against the
[official revision codes](https://www.raspberrypi.com/documentation/computers/raspberry-pi.html#raspberry-pi-revision-codes)).

## Automatic Reboot Handling

Every task that writes to `/boot/firmware/config.txt` (including the overclock tasks above) notifies the
`restart pi after config change` handler (`handlers/main.yml`). That handler only *sets a fact*
(`pi_config_reboot_required`) — the actual reboot happens in a **separate, dedicated play** in `site.yml`
("Reboot nodes with pending config.txt changes"), with `serial: 1`. This distinction matters: with the
default `linear` strategy, doing the reboot directly in this role's own play would mean every host gets
*drained* before any of them reboots (since Ansible runs one task across all hosts before the next task),
leaving the whole cluster cordoned at once for a while. The separate `serial: 1` play instead takes one
node fully through drain → reboot → wait-for-Ready → uncordon before starting the next — never more than
one node down at a time, which also protects etcd quorum on the three control-plane nodes.

The drain step excludes Longhorn's `instance-manager` pods (`--pod-selector
'longhorn.io/component!=instance-manager'`) — those have their own permanently-blocking PodDisruptionBudget
by Longhorn's own design (they're pinned to local disk and can't be rescheduled elsewhere anyway; the
reboot kills them regardless of whether they're "evicted" first, and Longhorn respawns a fresh one once
the node is back).

## Notes

- Idempotent - safe to run multiple times
- No data loss - only disables hardware and services
- Config-file changes trigger an automatic, safe, one-at-a-time reboot (see above) - not a manual step
- The ansible user is NOT managed by this role
