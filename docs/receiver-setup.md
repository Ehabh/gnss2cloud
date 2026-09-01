# Receiver setup

gnss2cloud's capture and conversion pipeline (`str2str` and `convbin`,
both from [RTKLIB](https://github.com/tomojitakasu/RTKLIB)) natively
supports multiple receiver manufacturers, not just u-blox. This guide
covers what any receiver needs to provide, then gives manufacturer-
specific configuration notes.

**Tested status:** this project has been validated end-to-end against
**u-blox** (SimpleRTK2B) and **Septentrio** (SimpleRTK3B Pro) receivers, across
Ubuntu, AlmaLinux, Debian, and Arch Linux hosts — see
[docs/tested-status.md](tested-status.md) for the full breakdown.
**NovAtel** support is implemented at the code level (RTKLIB supports
the format, and gnss2cloud's `GNSS_FORMAT` variable threads the
correct format token through `str2str` and `convbin`), but has
**not** been tested against real NovAtel hardware. **If you use
gnss2cloud with NovAtel, feedback on what did or didn't work is
welcome.**

## What any receiver needs to provide

Regardless of manufacturer, gnss2cloud needs the receiver to output,
over a serial/USB connection:

1. **Raw pseudorange/carrier-phase measurements** — the core
   observable data that becomes the RINEX `.obs` file.
2. **Raw navigation/ephemeris data** — becomes the RINEX `.nav` file.
   Without this, `.obs` will still be produced but `.nav` will be
   missing or empty.
3. A **known, fixed baud rate** high enough to carry that data without
   overflowing the receiver's or host's serial buffer. Multi-
   constellation tracking at a high output rate needs more bandwidth
   than single-constellation GPS-only. A baud rate of 460800 is a reasonable
   starting point for a fully multi-constellation configuration, but
   check your receiver's own buffer/overflow warnings if you push
   beyond that.

Two things are receiver-specific and must be set correctly in `.env`
before starting the container:

- **`GNSS_BAUD`** — must match whatever baud rate you configure on the
  receiver.
- **`GNSS_FORMAT`** — tells `str2str`/`convbin` which binary format to
  expect. Leave unset for u-blox (auto-detected). Set to `nov` for
  NovAtel, `sbf` for Septentrio. See `.env.example` for the full list
  of currently supported values.

The **udev rule** on the host (see the main `README.md`'s
[Host setup](../README.md#host-setup) section) also needs the correct
USB vendor/product ID for your specific receiver (u-blox's IDs won't
match a NovAtel or Septentrio unit).

## Optional: NMEA output for the web dashboard

The [web dashboard](../README.md#web-dashboard-optional-monitoring-only)
needs the receiver to also emit three specific NMEA sentences —
**GSV** (satellite CN0), **VTG** (speed/course), **GSA** (fix
quality/DOP). This is entirely separate from, and additional to, the
raw binary capture covered above; skip this section if you're not
using the dashboard.

**By design, this project's own dashboard code does not enable or
rely on GGA or RMC (the sentences that carry position) — GSV, VTG,
and GSA carry everything it needs.** This is a privacy-oriented design
choice for the dashboard specifically, not a restriction on your
receiver or your fork: nothing stops you from enabling GGA/RMC on the
same or a different port for your own purposes (logging, a different
tool, your own extension of this project). The guidance below is
about what the *dashboard* is built to expect, so that its "position
never appears in the dashboard" property holds by construction rather
than by convention. If you do enable GGA/RMC elsewhere, just be aware
that's outside what this project's dashboard code filters for or was
tested against.

### General requirements, any receiver

1. **Enable GSV, VTG, and GSA output**, at a reasonable rate (1 Hz is
   plenty for a monitoring dashboard).
2. **Recommended: disable GGA, RMC, GLL, and ZDA** on the port you use
   for this, if position privacy matters for your deployment. Many
   receivers ship with several NMEA sentences on by default per port,
   so this is worth checking even if you never intentionally enabled
   them. This isn't required for the dashboard to function (it only
   ever reads GSV/VTG/GSA and ignores everything else on the stream —
   see the [Security model](../README.md#security-model) section),
   but disabling them at the source is a stronger guarantee than
   relying on downstream filtering alone, if that's a property you
   want.
3. **Save the configuration to non-volatile memory**, not just the
   live session, the same requirement as the raw-capture setup
   above, and just as easy to forget for this second, separate set of
   messages.
4. Decide which **`NMEA_SOURCE_MODE`** fits your setup (see
   `.env.example` and the main README's
   [Web dashboard](../README.md#web-dashboard-optional-monitoring-only)
   section):
   - **`shared`** — NMEA comes out on the *same* port as the raw
     binary capture (the common case for a single-USB-port receiver).
     gnss2cloud handles keeping the two streams separated downstream;
     you don't need to do anything extra on the receiver side beyond
     steps 1–3 above.
   - **`dedicated`** — NMEA comes out on a genuinely separate
     port/virtual port (`NMEA_DEVICE_PATH`), e.g. a UART-to-USB
     adapter, or a receiver whose USB interface exposes multiple
     independent virtual ports. If your receiver supports this, it's
     the cleaner option, as the NMEA stream never touches the raw
     capture path at all, not even before filtering.

### A gotcha worth knowing about before you debug it yourself

Some receivers suppress **VTG's course-over-ground field — or the
entire VTG sentence, depending on firmware — whenever the antenna is
stationary** (Doppler-derived heading is meaningless at zero speed, so
some firmware "freezes" it, and some go further and stop emitting the
sentence at all unless told otherwise). If GSV and GSA are flowing
correctly but VTG never appears, this is the first thing to check,
not a wiring or filtering problem. On u-blox, look for a "permit COG
output even if COG is frozen"-style option (see the u-blox section
below for exactly where). Confirm the fix worked by checking the raw
capture file directly rather than a live packet capture — VTG's
low frequency relative to GSV/GSA means a short live test can miss it
even when it's genuinely present:

```bash
grep -ao '\$G.VTG,[^$]*' /data/raw/<latest-file>.ubx | head -5
```

### Verifying the NMEA output specifically

```bash
# From inside the main container, confirms what's actually reaching
# the filtered internal port the dashboard's bridge connects to:
docker compose exec gnss2cloud socat - TCP:localhost:5015
```

You should see only `$G?GSV`, `$G?VTG`, `$G?GSA` lines by default
(talker prefix varies — GP/GL/GA/GB/GN/etc. depending on constellation
and whether your receiver combines them). If you see raw binary data
here, that indicates the filtering relay isn't working as intended, 
worth investigating before relying on this port, since that's a bug
rather than a configuration choice (see the
[Security model](../README.md#security-model) section of the main
README). If you see GGA/RMC/GLL/ZDA here, that just reflects whatever
you've chosen to enable at the receiver, not an error, just worth
knowing it's present on this stream if privacy was a goal.

## u-blox

Configuration is done via [u-center](https://www.u-blox.com/en/product/u-center)
connected directly to the receiver, before it's handed off to the
gnss2cloud host. At a high level, you need to:

1. Set the serial baud rate to match `GNSS_BAUD` in `.env`.
2. Enable **UBX-RXM-RAWX** (raw measurements) and **UBX-RXM-SFRBX**
   (raw navigation data) output on the port you will actually use.
   UBX-NAV-PVT and UBX-MON-RF are optional but useful for diagnostics.
3. Enable the constellations you want tracked (GPS/GLONASS/Galileo/
   BeiDou/QZSS/SBAS, subject to your receiver's licensing).
4. Save the configuration to non-volatile memory (BBR/Flash) so it
   survives a power cycle, settings sent via u-center are RAM-only
   otherwise.
5. Fully disconnect u-center before connecting the receiver to the
   gnss2cloud host — `str2str` and u-center cannot both hold the
   serial port open.

Exact menu paths vary between u-center 1 and u-center 2 and across
firmware versions; consult u-blox's own u-center documentation for the
click-by-click steps for your specific receiver and u-center version.

`GNSS_FORMAT` should be left unset for u-blox — `str2str`/`convbin`
auto-detect the UBX format, and the raw file extension defaults to
`.ubx`.

### u-blox: NMEA output for the web dashboard (tested)

**This exact configuration has been validated end-to-end** against a
u-blox SimpleRTK2B (ZED-F9P) — see
[docs/tested-status.md](tested-status.md).

1. In u-center, **Configuration View → MSG**, on the port you're
   actually using (check U-center's own port selector matches the
   physical connection — a config change on the wrong port's
   checkbox is an easy, silent mistake):
   - Enable `NMEA-GxGSV`, `NMEA-GxVTG`, `NMEA-GxGSA` at 1 Hz.
   - Recommended: disable `NMEA-GxGGA`, `NMEA-GxRMC`, `NMEA-GxGLL`,
     `NMEA-GxZDA` on the same port, if position privacy matters for
     your deployment — see the note on this above.
2. If VTG appears empty (all fields blank, mode flag `N`) or absent
   entirely: **Configuration View → ODO** (Odometer and low-speed
   course-over-ground filter) — enable "permit COG output even if COG
   is frozen." This is a genuinely separate setting from the MSG
   enable/rate above, and was the actual fix needed during testing —
   confirmed via the raw-file `grep` method above, since a live
   packet capture can miss VTG's low frequency by chance.
3. **Save to flash**: `CFG-CFG` → save current configuration. Needed
   twice over — once for the raw-capture messages, once for these —
   easy to do one and forget the other since they're on different
   config screens.
4. If using `NMEA_SOURCE_MODE=shared` (the common case for u-blox
   over USB, since it presents as a single logical port): no further
   receiver-side action needed. gnss2cloud's filtering happens
   downstream — confirmed via testing that interleaving GSV/VTG/GSA
   into the same stream as raw UBX binary capture does not affect
   RINEX conversion quality (`.crx`/`.nav` output diffed clean against
   a pre-change baseline).

## NovAtel (OEM4/OEM6/OEM7/OEMStar)

**Not yet tested against this container** — the following is based on
RTKLIB's documented format support and NovAtel's own command
reference, not hands-on validation.

Set `GNSS_FORMAT=nov` in `.env`. RTKLIB's `nov` format token covers
NovAtel's OEMV/OEM4/OEM6/OEMStar log set; OEM7 receivers use a
backward-compatible command and log set, so `nov` should apply there
too.

On the receiver, using NovAtel's command interface:

1. Set the serial port baud rate to match `GNSS_BAUD` in `.env`.
2. Log the raw observation and navigation messages RTKLIB's `nov`
   decoder expects: `RANGECMPB` (or `RANGEB`), `RAWEPHEMB`, `IONUTCB` 
   on the port you will connect to gnss2cloud, at whatever rate matches
   your observation interval (commonly 1 Hz).
3. Save the configuration if your receiver supports persisting logged
   message settings across power cycles (`SAVECONFIG` on most NovAtel
   receivers) — otherwise these logs need to be re-requested on every
   power-up, which gnss2cloud's unattended capture won't do for you.

Check your specific NovAtel receiver's command reference (OEM6
Firmware Reference Manual, OEM7 Commands and Logs Reference Manual, or
equivalent) for exact command syntax.

### NovAtel: NMEA output for the web dashboard (untested)

**Not tested against the dashboard at all** — the following is based
on NovAtel's standard NMEA log support, not hands-on validation.

NovAtel receivers can typically log standard NMEA sentences directly
via commands like `log gpgsv ontime 1`, `log gpvtg ontime 1`,
`log gpgsa ontime 1` on the port in use, alongside the raw binary logs
from the section above. GGA and RMC would similarly be logged via
`log gpgga`/`log gprmc`, consider leaving these off for the
dashboard port if position privacy matters for your deployment, per
the general guidance above. Given NovAtel's dual-antenna/
multi-port capabilities, `NMEA_SOURCE_MODE=dedicated` may be a more
natural fit than `shared` if a separate port is available, worth
checking before assuming `shared` mode's filtering relay is needed at
all.

## Septentrio (SBF)

**Validated end-to-end against real Septentrio hardware** — see
[docs/tested-status.md](tested-status.md).

Set `GNSS_FORMAT=sbf` in `.env`. RTKLIB's `sbf` format token covers
Septentrio's native Septentrio Binary Format (SBF).

Septentrio's USB interface typically exposes **two independent CDC-ACM
virtual serial ports over one physical connection** — e.g. `ttyACM0`
and `ttyACM1` — rather than a single multiplexed port like u-blox.
Both carry the receiver's interactive command shell (prompt `USBn>`)
until you configure output streams on them.

For the udev rule to get a stable device path for both ports, see "Septentrio" under
[Receiver-specific notes](host-setup.md#receiver-specific-notes) in
docs/host-setup.md.

Connect with a serial terminal (`picocom`/`minicom`) at any baud —
USB CDC connections don't actually enforce the baud number, it's a
formality:

```bash
sudo picocom -b 460800 --echo /dev/gnss0
```

At the `USBn>` prompt:

1. **Check current SBF output config** (confirmed working; note this
   is the `sso`/`gso` short-mnemonic pair, not a "list" command —
   there is no separate `lstOutStreams`):

   ```
   gso, all
   ```

2. **Set the raw measurement + navigation stream**, at minimum the
   measurement block (`MeasEpoch`, plus `MeasExtra` for extended
   observables) and the navigation/ephemeris blocks for each
   constellation you use:

   ```
   sso, Stream1, USB1, MeasEpoch+MeasExtra+GPSNav+GPSIon+GPSUtc+GLONav+GLOTime+GALNav+GALIon+GALUtc, sec1
   ```

   This immediately starts binary output on the port. Your terminal
   will show unreadable binary data from this point on, which is
   expected, not an error. You can disconnect using (`Ctrl-A` `Ctrl-X` in picocom).

3. **Save to boot** so it persists across power cycles:

   ```
   eccf, Current, Boot
   ```

Check your specific Septentrio receiver's Firmware Reference Guide for
additional block names (e.g. BeiDou/QZSS) or constellation-specific
options — command names/mnemonics are stable across the SBF firmware
family, but full command names (e.g. `setSBFOutput`, `setNMEAOutput`)
are safer to use than guessed abbreviations if a mnemonic gives
`Invalid command!`.

### Septentrio: NMEA output for the web dashboard (tested)

**This exact configuration has been validated end-to-end**, using
`NMEA_SOURCE_MODE=dedicated` on Septentrio's second USB virtual port
— see [docs/tested-status.md](tested-status.md).

1. Connect to the **second** virtual port (e.g. `USB2`/`ttyACM1` —
   confirm which is which with `gdio, USBn` on each; both default to
   `SBF+NMEA` output enabled, so either works, but keep raw capture
   and NMEA on physically separate ports to avoid needing the
   `shared`-mode filtering relay at all):

   ```
   setNMEAOutput, Stream1, USB2, GSV+VTG+GSA, sec1
   ```

   (Use the full command name, the abbreviated form isn't valid.)

2. Save to boot from either port's command shell (this saves the
   whole receiver config, both ports' streams together):

   ```
   eccf, Current, Boot
   ```

3. Set `NMEA_SOURCE_MODE=dedicated` and `NMEA_DEVICE_PATH` to this
   second port's stable device path in `.env` — see
   [Host setup](host-setup.md) for the udev rule needed to get a
   stable symlink for a second interface on the same USB device (a
   single-rule vendor/product-ID match isn't enough to disambiguate
   Septentrio's two ports from each other).

**A note on device mapping**: `NMEA_SOURCE_MODE=dedicated` requires
`docker-compose.yml` to pass the second device through to the
container (`devices:`), in addition to the primary `/dev/gnss0`, this
is templated in the current `docker-compose.yml` via
`${NMEA_DEVICE_PATH:-/dev/null}`, no manual edit needed as long as
`NMEA_DEVICE_PATH` is set in `.env`.

## Verifying any receiver's configuration

Once the receiver is connected to the gnss2cloud host and the
container is running, regardless of manufacturer:

```bash
# Raw file should be growing, with the extension matching GNSS_FORMAT
# (.ubx, .gps, or .sbf)
ls -la ./data/raw/

# After the file closes and converts, both .obs and .nav should exist
ls -la ./data/rinex/<year>/<day-of-year>/
```

If `.nav` is missing or empty after conversion, the receiver's raw
navigation/ephemeris output likely isn't enabled — revisit the
manufacturer-specific steps above.

## Known quirks

- u-blox: on some receivers/firmware, enabling SFRBX for all supported
  constellations at once can produce a very high message rate. If you
  observe dropped RAWX epochs, try enabling constellations
  incrementally and re-testing at each step.
- NovAtel: since this path isn't yet validated end-to-end against
  this container, treat the steps above as a starting point.
  You may need to adjust exact log names for your specific receiver model and
  firmware version.
- Multi-port USB receivers (e.g. Septentrio): a udev rule matching
  only `idVendor`/`idProduct` will symlink to whichever interface udev
  processes last, non-deterministically, since both interfaces share
  the same IDs. See [Host setup](host-setup.md) for disambiguating
  with `ENV{ID_USB_INTERFACE_NUM}`.
