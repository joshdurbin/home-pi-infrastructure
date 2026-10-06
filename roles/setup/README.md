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
- `performance_optimization` - boot config (config.txt) rendering only
- `blacklist_modules` - Kernel module blacklisting only
- `remove_services` - Remove unnecessary services only
- `unattended_upgrades` - Automatic package updates only

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

## Automatic Package Updates

`tasks/unattended_upgrades.yml` turns on `unattended-upgrades` on every node (it was previously removed along
with the other stock-image extras). What it does, and doesn't:

- **Updates** Debian (point releases, security, stable-updates) and the Raspberry Pi archive (kernel,
  firmware). Third-party repos (Tailscale, Helm) are not listed, so they are never upgraded unattended.
- **Never reboots.** `Automatic-Reboot` is off: nodes are drained and rebooted by hand, one at a time
  (see "Node Maintenance" in `docs/REFERENCE.md`). A pending reboot (e.g. after a new kernel) is flagged in
  `/var/run/reboot-required`.
- **Holds back** `open-iscsi` and `nfs-common` (`unattended_upgrades_blacklist` in `defaults/main.yml`):
  Longhorn's host dependencies, whose upgrade restarts `iscsid` under live volumes. Upgrade them by hand while
  a node is drained: `sudo apt install --only-upgrade open-iscsi nfs-common`.
- **Staggered.** Each host upgrades at its own time, 30 minutes after the previous host in inventory order
  (02:00 for the first, up to 05:00 for the seventh), so the nodes - and especially the three control-plane
  nodes - never upgrade together. Timing is set by `unattended_upgrades_first_run_minutes` and
  `unattended_upgrades_spacing_minutes`, applied as a systemd drop-in on `apt-daily-upgrade.timer`.

Check on a node: `systemctl list-timers apt-daily-upgrade.timer`, `sudo unattended-upgrade --dry-run -d`,
`journalctl -t unattended-upgrade`, `ls /var/run/reboot-required`, `/var/log/unattended-upgrades/`.

Note: the `setup` role also runs a full `apt dist-upgrade` whenever it is applied (`make deploy-system`),
which is separate from, and not limited by, the blacklist above.

## Boot config (`/boot/firmware/config.txt`)

The whole file is rendered from `templates/config.txt.j2` per `board_model`, so each board only carries
settings that apply to it: no `[pi5]`/`[cm4]`/`[cm5]` filter sections and no per-setting `lineinfile`
appends. The original pre-Ansible file is kept once at `/var/backups/config.txt.pre-ansible` (the boot partition is FAT, so
the template module's own `backup: true` can't be used there).

## Overclocking

Applied per `board_model` (set in `group_vars/{pi4,pi5}/main.yaml`, not by inventory group name or
hostname — see `templates/config.txt.j2`, rendered by `tasks/config_txt.yml`):

- **Pi 4**: `arm_freq=1900` (stock 1500MHz), no `over_voltage_delta`. Note `arm_boost=1` (the documented
  zero-voltage 1.8GHz step) was tried first but has **zero effect** on these boards: they're rev 1.1, which
  lacks the regulator headroom for it (verified via `scaling_max_freq` after a real reboot). The template
  doesn't emit `arm_boost`. Whether 1900 holds without a voltage bump on rev 1.1 is **unverified** - check
  `scaling_max_freq` and `vcgencmd get_throttled` under load after the first node reboots.
- **Pi 5**: `arm_freq=2800` (stock 2400MHz), no `over_voltage_delta`. 2600MHz was confirmed live on all
  Pi 5 nodes; 2800 is **unverified** here and is further past what's commonly stable without a voltage bump
  (the Pi 5's DVFS supplies voltage per its stock curve). Check `scaling_max_freq` and
  `vcgencmd get_throttled` under load after the first node reboots; if unstable, add `over_voltage_delta=`
  (microvolts, e.g. `50000`) or step back to 2600.

- **Pi 5 PCIe**: `dtparam=pciex1_gen=3` (default is Gen 2). Gen 3 is outside the official spec, so check
  `dmesg | grep -i pcie` and `lspci -vv` (LnkSta) after the first node reboots, and watch the NVMe/HAT for errors;
  remove the line if the link is unstable.

To check a real board's revision before assuming any documented overclock step applies to it:
`cat /proc/cpuinfo | grep Revision` (cross-reference against the
[official revision codes](https://www.raspberrypi.com/documentation/computers/raspberry-pi.html#raspberry-pi-revision-codes)).

## USB disk read-ahead

On the Pi 4B nodes (`group_vars/pi4`: `usb_disk_read_ahead_kb: 256`) a udev rule
(`/etc/udev/rules.d/99-usb-read-ahead.rules`, `tasks/usb_read_ahead.yml`) caps read-ahead on USB-attached
disks. The USB-SATA bridge reports a huge optimal I/O size, so the kernel picks `read_ahead_kb=65532`; under
memory pressure each page fault then reads up to 64MB and saturates the SSD. It is applied live
(`udevadm trigger`), but a process that already has a file mapped keeps the old value until it restarts - restart
(e.g. delete the pod of) anything that was thrashing.

## Reboots are manual

Every task that writes to `/boot/firmware/config.txt` notifies the `restart pi after config change` handler
(`handlers/main.yml`), which only prints a notice that the host needs a reboot. **Nothing reboots, drains or
cordons a node automatically.** Reboot by hand, one node at a time, following
[Node Maintenance](../../docs/REFERENCE.md#node-maintenance) (drain with
`--pod-selector 'longhorn.io/component!=instance-manager'`, reboot, wait for Ready, uncordon).

## Notes

- Idempotent - safe to run multiple times
- No data loss - only disables hardware and services
- Config-file changes never reboot a node; the play prints a notice and you reboot by hand (see above)
- The ansible user is NOT managed by this role
