# minutewave

BEAM-side protocol stack for MIL-STD HF radio.

Brand-agnostic, hardware-agnostic library for driving MIL-STD-188-110D
serial-tone modems, MIL-STD-188-141 ALE link establishment, and
MELPe-600 voice over 110D. Intended to be consumed by both desktop
applications (PortAudio / Membrane back-ends) and mobile applications
(USB Audio / Android back-ends) without changing protocol code.

## Status

Early development. The library is being extracted from
[minutemodem](https://github.com/HeroesLament/minutemodem)'s
`minutemodem_core` umbrella application — the protocol layer there is
the reference implementation that has been driving HF traffic in
testbeds; minutewave is a clean re-extraction of that work for shared
use across desktop and mobile.

## Architecture

```
                    ┌────────────────────────┐
                    │   minutewave (this)    │
                    │                        │
                    │  Modem (TX/RX FSM)     │
                    │  ALE                   │
                    │  188-110D framing      │
                    │  KISS / MIL-110D       │
                    │  Audio.Backend         │ ← behaviour spec
                    │  Rig.Control           │ ← behaviour spec
                    │  Dsp.PhyModem          │ ← thin NIF facade
                    └───────────┬────────────┘
                                │
                ┌───────────────┴────────────────┐
                │                                │
        ┌───────▼────────┐               ┌───────▼────────┐
        │   Desktop      │               │    Mobile      │
        │                │               │                │
        │  Membrane      │               │  Mob.VendorUsb │
        │  PortAudio     │               │  AAudio (USB)  │
        │  Hamlib/flrig  │               │  CAT over Mob  │
        └────────────────┘               └────────────────┘
```

The protocol stack is fully decoupled from hardware backends through
two behaviours:

- `Minutewave.Audio.Backend` — TX/RX PCM I/O against the radio audio
  path (DigiRig USB Audio on mobile; sound-card-of-choice on desktop)
- `Minutewave.Rig.Control` — frequency, mode, PTT (Hamlib/rigctld/flrig
  on desktop; CAT-over-VendorUsb on mobile)

DSP is provided through `Minutewave.Dsp.PhyModem`, a thin facade that
delegates to a NIF module configured by the consumer. The actual NIF
implementation lives in the consuming project's `native/` directory
and links against [milwave-rs](https://github.com/HeroesLament/milwave-rs)
and [melpe-rs](https://github.com/HeroesLament/melpe-rs).

## Why split this out?

`minutemodem_core` was originally a single umbrella app that owned the
protocol stack and the desktop audio backend together. Extending to
mobile required either (a) duplicating the protocol code, (b) cluttering
`_core` with `if mobile? ...` branches, or (c) pulling the protocol code
into a brand-agnostic library that both targets depend on.

This is (c).

## License

Dual-licensed under either of

 * Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE) or
   <http://www.apache.org/licenses/LICENSE-2.0>)
 * MIT license ([LICENSE-MIT](LICENSE-MIT) or
   <http://opensource.org/licenses/MIT>)

at your option.
