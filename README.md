# home-pi-infrastructure

This is the primary repo that configures a cluster of Raspberry PI Zero Ws, 3B+, and 4Bs for various tasks.
A basic Hashi suite is setup leveraging Consul, Nomad, and Vault. Ansible is used to configure the instances. 

The inventory consists of a few PI 4s, a PI 3, and 3 PI Zero Ws The PI Zero Ws are primarily used for camera input
throughout the house and for at home / away object detection based on the proximity to blue tooth devices (household members phones).

Unbound runs DNS on all the instances allowing any instance on the network to reach or resolve services within the network. Anything else is
TLS upstream'ed to Cloudflare. Two instances run separate, external facing (via their `eth0` address) Unbound instances that are more or less
the same with an additional zone for traefik. Traefik runs in the Nomad cluster and fronts / proxies traffic to the web-related apps like: pihole, grafana, elastic search, etc...

A set of services collect and do object detection and alert when a human figure is detected when people are not present. Again,
this particular service is made possible just by polling for the existence of our mobile devices.

The PI 3 also has a HAT/DAC that's connected to the audio system for Airplay streaming from our iOS/MacOS devices. File sharing is
made possible on a set of the machines over Samba with dedicated volume mounts (platter-based) while the PI 4 main system drives
are 128 GB SSDs interfaced via USB3 w/ UASP.

# Related Repos

- [home-pi-infrastructure-nomad-jobs](https://github.com/joshdurbin/home-pi-infrastructure-nomad-jobs) contains Nomad jobs for the environment 

# Buy List

## Raspberry PI 3B+

- [PI3B+ 1GB](https://www.amazon.com/ELEMENT-Element14-Raspberry-Pi-Motherboard/dp/B07BDR5PDW/)
- [64 GB SD Card](https://www.amazon.com/SanDisk-Extreme-microSDXC-UHS-I-Adapter/dp/B01HU3Q6S4/)
- [USB Power Supply](https://www.amazon.com/gp/product/B00MARDJZ4/)

## Raspberry PI 4B

- [PI4B 4GB](https://www.amazon.com/gp/product/B07TC2BK1X/)
- [UASP 2.5 Drive USB Adapter](https://www.amazon.com/gp/product/B00HJZJI84/)
- [Passive Heat Sink](https://www.amazon.com/gp/product/B07X5Y81C6/)
- [128GB Kingston SATA3 SSD](https://www.amazon.com/gp/product/B01N6JQS8C/)
- [USB C Power Supply](https://www.amazon.com/gp/product/B07TYQRXTK/)

# Initial setup

## 64 bit ARM

1. Download the lite version of Raspberry PI OS -- `wget https://downloads.raspberrypi.org/raspios_lite_arm64/images/raspios_lite_arm64-2020-08-24/2020-08-20-raspios-buster-arm64-lite.zip ~/Downloads`
2. Determine which drive you're targetting for flash using `diskutil list`
3. Unmount the drive `diskutil unmountDisk /dev/disk2`
4. Unzip and flash the image to the target disk: `sudo sh -c 'unzip -p ~/Downloads/raspios_lite_arm64-2020-08-24/2020-08-20-raspios-buster-arm64-lite.zip | sudo dd of=/dev/rdisk2 bs=32m'` (note that for this operation the device `diskX` is prefaced with an `r`, i.e. `disk2` becomes `rdisk2`)
5. Enable SSH on boot by touching `ssh` in the `boot` volume: `touch /Volumes/boot/ssh`
6. Safely unmount the drive `diskutil unmountDisk /dev/disk2`

## Consul Setup

Run through [these instructions](https://learn.hashicorp.com/tutorials/consul/tls-encryption-secure).

## Nomad TLS Setup

Run through [these instructions](https://learn.hashicorp.com/tutorials/nomad/security-enable-tls) with one adjustment: the client and server key/cert creations should use the `hostname` directive of: `server.pi.nomad,localhost,127.0.0.1`.

```
➜  ~  cfssl print-defaults csr | cfssl gencert -initca - | cfssljson -bare nomad-ca
2020/10/17 15:38:51 [INFO] generating a new CA key and certificate from CSR
2020/10/17 15:38:51 [INFO] generate received request
2020/10/17 15:38:51 [INFO] received CSR
2020/10/17 15:38:51 [INFO] generating key: ecdsa-256
2020/10/17 15:38:51 [INFO] encoded CSR
2020/10/17 15:38:51 [INFO] signed certificate with serial number 608852026734149967881963221848431432634478231216
➜  ~  echo '{}' | cfssl gencert -ca=nomad-ca.pem -ca-key=nomad-ca-key.pem -config=cfssl.json \
    -hostname="client.pi.nomad,localhost,127.0.0.1" - | cfssljson -bare client
2020/10/17 15:39:27 [INFO] generate received request
2020/10/17 15:39:27 [INFO] received CSR
2020/10/17 15:39:27 [INFO] generating key: ecdsa-256
2020/10/17 15:39:27 [INFO] encoded CSR
2020/10/17 15:39:27 [INFO] signed certificate with serial number 700357368103815046329098985198950734373379546529
➜  ~  echo '{}' | cfssl gencert -ca=nomad-ca.pem -ca-key=nomad-ca-key.pem -config=cfssl.json \
    -hostname="server.pi.nomad,localhost,127.0.0.1" - | cfssljson -bare server
2020/10/17 15:39:58 [INFO] generate received request
2020/10/17 15:39:58 [INFO] received CSR
2020/10/17 15:39:58 [INFO] generating key: ecdsa-256
2020/10/17 15:39:58 [INFO] encoded CSR
2020/10/17 15:39:58 [INFO] signed certificate with serial number 659484574897416600125425487281335309811798081172
➜  ~  echo '{}' | cfssl gencert -ca=nomad-ca.pem -ca-key=nomad-ca-key.pem -profile=client \
    - | cfssljson -bare cli
2020/10/17 15:40:19 [INFO] generate received request
2020/10/17 15:40:19 [INFO] received CSR
2020/10/17 15:40:19 [INFO] generating key: ecdsa-256
2020/10/17 15:40:19 [INFO] encoded CSR
2020/10/17 15:40:19 [INFO] signed certificate with serial number 469175300540931032078365291548834935717686252502
2020/10/17 15:40:19 [WARNING] This certificate lacks a "hosts" field. This makes it unsuitable for
websites. For more information see the Baseline Requirements for the Issuance and Management
of Publicly-Trusted Certificates, v.1.1.6, from the CA/Browser Forum (https://cabforum.org);
specifically, section 10.2.3 ("Information Requirements").
```

If the `tls` stanza for the Nomad service has `http` set to the true, all API / HTTP traffic will require the custom CLI certs
that were developed are part of the aforementioned process. This means, without tweaking, that browser traffic will not be able to
reach Nomad -- the web UI will not work. To interact with the APIs using the nomad client you either have to set
environment variables telling the nomad client how to connect or explicitly define them with each call. Ex: 

```
sudo nomad node status -address=https://localhost:4646 -ca-cert=/etc/ssl/certs/nomad-ca.pem -client-cert=/etc/ssl/certs/cli -client-key=/etc/ssl/private/cli-key.pem
```

## Common Commands:

1. A full run of everything: `ansible-playbook complete_playbook.yml -i inventory.dist --ask-vault-pass`
2. Gather facts for a particular hose (example `rpi-4b-1`): `ansible rpi-4b-1 -m setup -i inventory.dist`
3. Target a specific group (example `unbound` (also any `all` groups will exec too)): `ansible-playbook complete_playbook.yml -i inventory.dist --ask-vault-pass --limit unbound`
4. Target a specific host (example `rpi-4b-1` (also any `all` groups will exec too)): `ansible-playbook complete_playbook.yml -i inventory.dist --ask-vault-pass --limit rpi-4b-1`
5. Stop a service out of an apply: `ansible -i inventory.dist cameras -m ansible.builtin.service -a "name=uv4l_raspicam state=stopped" --become`
