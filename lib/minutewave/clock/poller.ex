defmodule Minutewave.Clock.Poller do
  @moduledoc """
  Drives a **pull-shaped** `Minutewave.Clock.Source` into the clock.

  On a timer it calls the source's `read_fix/0`, and forwards each `{:ok, fix}`
  to `Minutewave.Clock.discipline_gnss/1`. `:no_fix` results are dropped (the
  clock simply coasts in holdover until a fix returns).

  This exists so integrators with a USB GPS / serial NMEA receiver get a
  turnkey path: implement the `Source` behaviour, start a Poller with the
  module, done. Push sources (Android `GnssMeasurements`) bypass this entirely
  and call `discipline_gnss/1` from their own callback.

  ## Usage

      children = [
        Minutewave.Clock,
        {Minutewave.Clock.Poller, source: FixedStation.GNSS.USB}
      ]

  Options:

    * `:source` (required) - module implementing `Minutewave.Clock.Source`.
    * `:interval_ms` - poll cadence. Defaults to the source's
      `suggested_interval_ms/0` if exported, else `@default_interval_ms`.
    * `:clock` - the clock server to discipline. Defaults to
      `Minutewave.Clock` (the registered name).
    * `:name` - the Poller's own registered name. Defaults to this module.
  """

  use GenServer
  require Logger

  @default_interval_ms 1_000

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    source = Keyword.fetch!(opts, :source)

    interval =
      Keyword.get_lazy(opts, :interval_ms, fn ->
        if function_exported?(source, :suggested_interval_ms, 0) do
          source.suggested_interval_ms()
        else
          @default_interval_ms
        end
      end)

    clock = Keyword.get(opts, :clock, Minutewave.Clock)

    state = %{source: source, interval: interval, clock: clock}

    Logger.info(
      "Clock.Poller: driving #{source_name(source)} every #{interval}ms -> #{inspect(clock)}"
    )

    {:ok, state, {:continue, :poll}}
  end

  @impl true
  def handle_continue(:poll, state) do
    do_poll(state)
    schedule(state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(:poll, state) do
    do_poll(state)
    schedule(state.interval)
    {:noreply, state}
  end

  defp do_poll(state) do
    case state.source.read_fix() do
      {:ok, fix} ->
        Minutewave.Clock.discipline_gnss(fix, state.clock)

      :no_fix ->
        :ok
    end
  rescue
    e ->
      # A misbehaving source must not crash the poll loop; log and keep going.
      Logger.warning("Clock.Poller: #{source_name(state.source)} read_fix raised: #{inspect(e)}")
      :ok
  end

  defp schedule(interval), do: Process.send_after(self(), :poll, interval)

  defp source_name(source) do
    if function_exported?(source, :name, 0), do: source.name(), else: inspect(source)
  end
end
