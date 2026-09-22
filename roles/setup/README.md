# Setup Role

Prepares Raspberry Pi instances for k3s by optimizing for minimal resource usage and installing essential packages.

## What It Does

- Disables unnecessary hardware (Bluetooth, WiFi, audio, camera, HAT interfaces)
- Reduces GPU memory allocation to 16MB
- Enables kernel cgroups for Kubernetes
- Disables unnecessary services and daemons
- Installs essential packages for system administration
- Configures locale, timezone, and keyboard layout

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

## Usage

```bash
# Run all setup tasks
make deploy-system

# Or via Ansible directly
ansible-playbook site.yml -i inventory.dist --ask-vault-pass --tags setup
```

## Notes

- Idempotent - safe to run multiple times
- No data loss - only disables hardware and services
- Requires reboot for some changes to take effect (device tree parameters)
- The ansible user is NOT managed by this role
