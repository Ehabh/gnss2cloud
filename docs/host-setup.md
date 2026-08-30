# Host setup

Before running the container, the host needs a stable device path.
This must be done on the **host** — Docker cannot create or manage
udev rules from inside a container.

## 1. Find your receiver's vendor/product ID

```bash
udevadm info -a -n /dev/ttyACM0 | grep -E 'idVendor|idProduct' | head -5
```

(u-blox devices are typically `1546`/`01a9` — confirm yours matches,
or use your own receiver's IDs.)

## 2. Create the udev rule

Create `/etc/udev/rules.d/99-<yourdevice>.rules` (must be a single
line):

```
SUBSYSTEM=="tty", ATTRS{idVendor}=="1546", ATTRS{idProduct}=="01a9", SYMLINK+="gnss0"
```

**Multi-port receivers** (e.g. Septentrio, which exposes two
independent USB CDC-ACM interfaces for logs): a single
vendor/product-ID match will symlink to whichever interface udev
processes last, non-deterministically. Disambiguate with
`ENV{ID_USB_INTERFACE_NUM}` (a udev-computed property, not a raw
device attribute) rather than `ATTRS{bInterfaceNumber}` — `ATTRS{}`
matches must all come from the same level of the device's parent
chain, and `idVendor`/`idProduct` live one level up from
`bInterfaceNumber`, so mixing them in one rule silently never matches:

```
SUBSYSTEM=="tty", ATTRS{idVendor}=="152a", ATTRS{idProduct}=="85c0", ENV{ID_USB_INTERFACE_NUM}=="02", GROUP="dialout", MODE="0660", SYMLINK+="gnss0"
SUBSYSTEM=="tty", ATTRS{idVendor}=="152a", ATTRS{idProduct}=="85c0", ENV{ID_USB_INTERFACE_NUM}=="04", GROUP="dialout", MODE="0660", SYMLINK+="gnss_nmea0"
```

Run `udevadm info -a -n /dev/ttyACM0 | grep -E 'KERNELS==|bInterfaceNumber'`
against each enumerated `tty` device to find its interface number.

## 3. Apply it

```bash
sudo udevadm control --reload-rules
sudo udevadm trigger
```

If the symlink doesn't appear, a synthetic `trigger` doesn't always
force full re-evaluation on every udev version — unplug and physically
replug the device instead.

## 4. Verify

```bash
ls -la /dev/gnss0
```

## Distro-specific notes

### RHEL-family (AlmaLinux, etc.) — SELinux

**SELinux-enforcing hosts**: bind-mounted volumes need the `:z` label
or the container will get silent permission-denied errors despite
correct Unix permissions. Add `:z` to each volume line in
`docker-compose.yml` (e.g. `${DATA_DIR:-./data}/raw:/data/raw:z`).
Not needed on Debian/Ubuntu (AppArmor, no equivalent bind-mount
labeling requirement).

### Ubuntu / Debian

No distro-specific steps beyond the udev rule above — the `dialout`
group already exists by default and serial devices are assigned to it
out of the box.

### Arch Linux

Three things behave differently from Ubuntu/Debian/RHEL and are worth
checking before assuming something's broken:

1. **No `dialout` group by default.** Arch assigns serial ACM/USB
   devices to the `uucp` group, not `dialout`. Since this project's
   `DIALOUT_GID` convention expects a `dialout` group, create one:

   ```bash
   sudo groupadd -r dialout   # -r: system group — see note below
   sudo usermod -aG dialout $USER
   ```

   **Use `-r` (system group).** A plain `groupadd dialout` assigns a
   regular user-range GID (≥1000), which modern `systemd-udevd`
   refuses to use for device-node ownership ("Group dialout
   configured to own a device node is not a system group... support
   ... will be removed"), silently breaking any `GROUP="dialout"`
   udev rule. If you already created it without `-r`, delete and
   recreate it (`sudo groupdel dialout`), then re-add your user —
   `groupdel`/`groupadd` does not preserve membership.

   Group changes only apply to new sessions — log out and back in
   (or `newgrp dialout`) before testing device access.

2. **`cdc_acm` may not be loaded**, and USB CDC-ACM devices (which is
   how most GNSS receivers, including Septentrio and u-blox, present
   over USB) won't create a `/dev/ttyACM*` node without it:

   ```bash
   sudo modprobe cdc_acm
   ```

   If this fails with `Module cdc_acm not found in directory
   /lib/modules/$(uname -r)`, check for a kernel/module version
   mismatch — a pending kernel update that hasn't been rebooted into
   yet is the common cause:

   ```bash
   uname -r          # currently running kernel
   ls /lib/modules/  # installed module sets
   ```

   If these don't match, `sudo reboot` and recheck.

3. **`docker-buildx` isn't installed by default.** The Dockerfile
   relies on Docker's automatic `TARGETARCH` build argument
   (`supercronic-linux-${TARGETARCH}`), which is only populated when
   BuildKit is active. Without `docker-buildx`, `docker compose build`
   silently falls back to the legacy builder, `TARGETARCH` resolves
   empty, and the supercronic download 404s. Fix:

   ```bash
   sudo pacman -S docker-buildx
   ```

Get your final `DIALOUT_GID` for `.env` with `getent group dialout`
after completing step 1 above.
