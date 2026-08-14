# Receiver setup

gnss2cloud's capture and conversion pipeline (`str2str` and `convbin`,
both from [RTKLIB](https://github.com/tomojitakasu/RTKLIB)) natively
supports multiple receiver manufacturers, not just u-blox. This guide
covers what any receiver needs to provide, then gives manufacturer-
specific configuration notes.

**Tested status:** this project has been built and validated
end-to-end against a **u-blox SimpleRTK2B**, across multiple Linux
distributions (Ubuntu Server, AlmaLinux). NovAtel and Septentrio
support is implemented at the code level (RTKLIB supports both
formats, and gnss2cloud's `GNSS_FORMAT` variable threads the correct
format token through `str2str` and `convbin`), but has **not** been
tested against real NovAtel or Septentrio hardware. **If you use
gnss2cloud with one of these receivers, feedback on what did or didn't
work is welcome.**

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
   than single-constellation GPS-only — 460800 baud is a reasonable
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
USB vendor/product ID for your specific receiver — u-blox's IDs won't
match a NovAtel or Septentrio unit.

## u-blox

Configuration is done via [u-center](https://www.u-blox.com/en/product/u-center)
connected directly to the receiver, before it's handed off to the
gnss2cloud host. At a high level, you need to:

1. Set the serial baud rate to match `GNSS_BAUD` in `.env`.
2. Enable **UBX-RXM-RAWX** (raw measurements) and **UBX-RXM-SFRBX**
   (raw navigation data) output on the port you'll actually use.
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

## Septentrio (SBF)

**Not yet tested against this container** — the following is based on
RTKLIB's documented format support and Septentrio's own SBF
documentation, not hands-on validation.

Set `GNSS_FORMAT=sbf` in `.env`. RTKLIB's `sbf` format token covers
Septentrio's native Septentrio Binary Format (SBF).

On the receiver, using Septentrio's web interface, RxTools, or command
interface:

1. Set the serial port baud rate to match `GNSS_BAUD` in `.env`.
2. Configure SBF output streams to include the raw measurement and
   navigation blocks RTKLIB's `sbf` decoder expects, at minimum the
   measurement block (`MeasEpoch`) and the navigation/ephemeris blocks
   for each constellation in use, on the port you'll connect to
   gnss2cloud.
3. Save the configuration to boot so it persists across power cycles.

Check your specific Septentrio receiver's Firmware User Manual for
exact SBF block names and configuration commands, as these vary
somewhat by receiver family and firmware version.

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
- NovAtel and Septentrio: since these paths aren't yet validated
  end-to-end against this container, treat the steps above as a
  starting point, you may need to adjust exact log/block names for
  your specific receiver model and firmware version.
