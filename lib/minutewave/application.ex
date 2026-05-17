defmodule Minutewave.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Per-rig event buses and FSM processes register themselves under
      # this registry, addressed by {rig_id, role}.
      {Registry, keys: :unique, name: Minutewave.Modem.Registry},

      # Per-rig control / hardware-side processes (Rig.Control implementations,
      # audio backends) register here. Separate from Modem.Registry so the
      # protocol and hardware sides have independent supervision lifecycles.
      {Registry, keys: :unique, name: Minutewave.Rig.InstanceRegistry},

      # Per-rig wire-protocol interface processes (KISS, MIL-110D-A) register
      # here, addressed by {rig_id, :kiss | :mil110d | :mil110d_listener}.
      {Registry, keys: :unique, name: Minutewave.Interface.Registry}
    ]

    opts = [strategy: :one_for_one, name: Minutewave.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
