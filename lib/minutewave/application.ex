defmodule Minutewave.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Per-rig event buses and (later) FSM processes register themselves
      # under this registry, addressed by {rig_id, role}.
      {Registry, keys: :unique, name: Minutewave.Modem.Registry}
    ]

    opts = [strategy: :one_for_one, name: Minutewave.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
