defmodule Minutewave.Dsp.PhyModem do
  @moduledoc """
  Facade over a consumer-supplied NIF module implementing the milwave-rs
  surface (UnifiedModulator, UnifiedDemodulator with optional DFE,
  per-symbol telemetry, and Walsh-Hadamard correlator).

  Each consumer of `minutewave` provides its own NIF crate (linking
  against `milwave-rs`) and a matching Elixir module that uses Rustler.
  The consumer registers that module with minutewave via Application
  config:

      # In the consumer's config/config.exs:
      config :minutewave, phy_modem_nif: MyApp.Nifs.PhyModem

  All of minutewave's protocol code calls into this facade. The actual
  NIF dispatch happens through the configured module.

  ## Why a facade instead of `use Rustler` directly?

  Each consumer's NIF module is bound to its own `otp_app` and ships
  its own `.so` in its `priv/native/`. minutewave can't own the NIF
  because:

    1. NIF .so files are per-`otp_app`. minutewave's protocol code is
       shared, but the underlying NIF is consumer-specific.
    2. Consumers may have different NIF surfaces (additional functions
       for product features beyond what minutewave needs).
    3. Tests in minutewave run without any NIF loaded.

  ## Surface

  The facade exposes only the unified API: `unified_mod_*` and
  `unified_demod_*` (with DFE + telemetry variants), and the Walsh
  correlator. Legacy `mod_*` / `demod_*` / bare `new` paths are not
  exposed — minutewave protocol code uses the unified modulator
  exclusively for HF-grade equalization, training-symbol support, and
  runtime constellation switching.

  ## Wideband support

  Constructors take optional `symbol_rate` (u32) and `carrier_freq`
  (f64) arguments. Pass `nil` for both to use the 188-110D Annex C
  defaults (2400 baud, 1800 Hz). Pass explicit values for Annex F
  wideband modes.
  """

  # ──────────────────────────────────────────────────────────────────────
  # UnifiedModulator
  # ──────────────────────────────────────────────────────────────────────

  def unified_mod_new(constellation, sample_rate, symbol_rate \\ nil, carrier_freq \\ nil),
    do: impl().unified_mod_new(constellation, sample_rate, symbol_rate, carrier_freq)

  def unified_mod_modulate(modulator, symbols),
    do: impl().unified_mod_modulate(modulator, symbols)

  def unified_mod_modulate_mixed(modulator, tagged_symbols),
    do: impl().unified_mod_modulate_mixed(modulator, tagged_symbols)

  def unified_mod_set_constellation(modulator, constellation),
    do: impl().unified_mod_set_constellation(modulator, constellation)

  def unified_mod_get_constellation(modulator),
    do: impl().unified_mod_get_constellation(modulator)

  def unified_mod_flush(modulator),
    do: impl().unified_mod_flush(modulator)

  def unified_mod_reset(modulator),
    do: impl().unified_mod_reset(modulator)

  # ──────────────────────────────────────────────────────────────────────
  # UnifiedDemodulator
  # ──────────────────────────────────────────────────────────────────────

  def unified_demod_new(constellation, sample_rate, symbol_rate \\ nil, carrier_freq \\ nil),
    do: impl().unified_demod_new(constellation, sample_rate, symbol_rate, carrier_freq)

  def unified_demod_iq(demodulator, samples),
    do: impl().unified_demod_iq(demodulator, samples)

  def unified_demod_symbols(demodulator, samples),
    do: impl().unified_demod_symbols(demodulator, samples)

  def unified_demod_eq_iq(demodulator, samples),
    do: impl().unified_demod_eq_iq(demodulator, samples)

  def unified_demod_set_constellation(demodulator, constellation),
    do: impl().unified_demod_set_constellation(demodulator, constellation)

  def unified_demod_reset(demodulator),
    do: impl().unified_demod_reset(demodulator)

  # ──────────────────────────────────────────────────────────────────────
  # DFE (Decision Feedback Equalizer)
  # ──────────────────────────────────────────────────────────────────────

  def unified_demod_new_with_eq(
        constellation,
        sample_rate,
        ff_taps,
        fb_taps,
        mu,
        symbol_rate \\ nil,
        carrier_freq \\ nil
      ),
      do:
        impl().unified_demod_new_with_eq(
          constellation,
          sample_rate,
          ff_taps,
          fb_taps,
          mu,
          symbol_rate,
          carrier_freq
        )

  def unified_demod_new_hf(constellation, sample_rate, symbol_rate \\ nil, carrier_freq \\ nil),
    do: impl().unified_demod_new_hf(constellation, sample_rate, symbol_rate, carrier_freq)

  def unified_demod_set_training(demodulator, symbols),
    do: impl().unified_demod_set_training(demodulator, symbols)

  def unified_demod_reset_eq(demodulator),
    do: impl().unified_demod_reset_eq(demodulator)

  def unified_demod_mse(demodulator),
    do: impl().unified_demod_mse(demodulator)

  def unified_demod_has_eq(demodulator),
    do: impl().unified_demod_has_eq(demodulator)

  def unified_demod_enable_eq(demodulator, ff_taps, fb_taps, mu),
    do: impl().unified_demod_enable_eq(demodulator, ff_taps, fb_taps, mu)

  def unified_demod_disable_eq(demodulator),
    do: impl().unified_demod_disable_eq(demodulator)

  def unified_demod_eq_mode(demodulator),
    do: impl().unified_demod_eq_mode(demodulator)

  # ──────────────────────────────────────────────────────────────────────
  # Telemetry (PLL + DFE)
  # ──────────────────────────────────────────────────────────────────────

  def unified_demod_enable_telemetry(demodulator),
    do: impl().unified_demod_enable_telemetry(demodulator)

  def unified_demod_take_telemetry(demodulator),
    do: impl().unified_demod_take_telemetry(demodulator)

  def unified_demod_lock_detect(demodulator),
    do: impl().unified_demod_lock_detect(demodulator)

  def unified_demod_set_block_size(demodulator, size),
    do: impl().unified_demod_set_block_size(demodulator, size)

  def unified_demod_get_block_size(demodulator),
    do: impl().unified_demod_get_block_size(demodulator)

  def unified_demod_enable_dfe_telemetry(demodulator),
    do: impl().unified_demod_enable_dfe_telemetry(demodulator)

  def unified_demod_take_dfe_telemetry(demodulator),
    do: impl().unified_demod_take_dfe_telemetry(demodulator)

  # ──────────────────────────────────────────────────────────────────────
  # Walsh-Hadamard correlator
  # ──────────────────────────────────────────────────────────────────────

  def walsh_correlator_new(n_phases, n_passes),
    do: impl().walsh_correlator_new(n_phases, n_passes)

  def walsh_correlator_decode(correlator, descrambled_iq, raw_iq, scramble_offsets),
    do: impl().walsh_correlator_decode(correlator, descrambled_iq, raw_iq, scramble_offsets)

  def walsh_correlator_decode_soft(correlator, descrambled_iq, raw_iq, scramble_offsets),
    do: impl().walsh_correlator_decode_soft(correlator, descrambled_iq, raw_iq, scramble_offsets)

  def walsh_correlator_decode_diagnostic(correlator, descrambled_iq, raw_iq, scramble_offsets),
    do:
      impl().walsh_correlator_decode_diagnostic(
        correlator,
        descrambled_iq,
        raw_iq,
        scramble_offsets
      )

  def walsh_correlator_enable_telemetry(correlator),
    do: impl().walsh_correlator_enable_telemetry(correlator)

  def walsh_correlator_take_telemetry(correlator),
    do: impl().walsh_correlator_take_telemetry(correlator)

  def walsh_turbo_decode(correlator, descrambled_iq, raw_iq, scramble_offsets, n_iterations),
    do:
      impl().walsh_turbo_decode(
        correlator,
        descrambled_iq,
        raw_iq,
        scramble_offsets,
        n_iterations
      )

  # ──────────────────────────────────────────────────────────────────────
  # Internal
  # ──────────────────────────────────────────────────────────────────────

  defp impl do
    Application.get_env(:minutewave, :phy_modem_nif) ||
      raise """
      Minutewave.Dsp.PhyModem: no NIF module configured.

      Add to your application's config:

          config :minutewave, phy_modem_nif: MyApp.Nifs.PhyModem

      where MyApp.Nifs.PhyModem is your `use Rustler` module that binds
      the milwave-rs NIF surface for your target platform.
      """
  end
end
