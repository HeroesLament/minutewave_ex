defmodule Minutewave do
  @moduledoc """
  BEAM-side protocol stack for MIL-STD HF radio.

  Minutewave is brand-agnostic and hardware-agnostic. It contains the
  protocol layer (TX/RX FSMs, ALE, 188-110D framing, KISS/MIL-110D
  interfaces, NIF facade for DSP) but does not own any audio device
  or rig control implementation directly. Consumers wire in concrete
  backends via two behaviours:

    * `Minutewave.Audio.Backend` — radio-side audio I/O
    * `Minutewave.Rig.Control` — frequency, mode, PTT, TX arbitration

  See `README.md` for the full architecture diagram and the rationale
  for splitting this out of `minutemodem_core`.
  """
end
