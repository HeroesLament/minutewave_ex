defmodule Minutewave.RigState do
  @moduledoc """
  Read-only outward projection of per-rig ALE runtime state, for observation by
  the rest of the app (UI, dashboard, ACS) without querying the Link FSM.

  ## What this is

  A single ETS table, keyed by `rig_id`, holding a snapshot map of the viewable
  state of each rig's ALE link: channel list, currently selected frequency,
  scan index/mode, link state, and net policy. MinuteModem runs multiple rigs
  at once (typically 2-3 HF radios); each rig occupies one key.

  ## What this is NOT

  * **Not authoritative.** The Link FSM's own `data` is the source of truth.
    This table is a mirror the FSM *publishes* to on change; it may lag by
    microseconds and is rebuilt by the FSM on restart. Never read it back into
    FSM logic.
  * **Not a control surface.** Changing a rig's channels/mode goes through the
    Link FSM (`scan/2`, `call/3` opts), never by writing here.

  ## Concurrency model

  One shared, `:public`, `read_concurrency: true` table owned by this process.
  Reads are direct ETS lookups from any process (no message to this server, no
  message to the FSM). Writes come only from each rig's Link FSM, and the
  invariant is: **a process only ever writes its own `rig_id` key.** With that
  discipline a public table is safe — rigs never clobber each other (distinct
  keys) and there is a single writer per key.
  """

  use GenServer

  @table :minutewave_rig_state

  # ---- lifecycle ----

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  # ---- writes (called by a rig's Link FSM, for its own rig_id only) ----

  @doc """
  Publish the viewable state snapshot for `rig_id`. Overwrites the prior
  snapshot. Called by the Link FSM whenever its viewable state changes.
  """
  @spec publish(term(), map()) :: :ok
  def publish(rig_id, %{} = snapshot) do
    :ets.insert(@table, {rig_id, snapshot})
    :ok
  end

  @doc """
  Merge `fields` into the existing snapshot for `rig_id` (read-modify-write from
  the sole writer; safe because only this rig's FSM writes this key). Use when
  only a couple of fields change (e.g. a dwell hop updating current_freq /
  scan_index) and you don't want to reassemble the whole snapshot.
  """
  @spec update(term(), map()) :: :ok
  def update(rig_id, %{} = fields) do
    current =
      case :ets.lookup(@table, rig_id) do
        [{^rig_id, snap}] -> snap
        [] -> %{}
      end

    :ets.insert(@table, {rig_id, Map.merge(current, fields)})
    :ok
  end

  @doc "Remove a rig's entry. Called on rig teardown so stale rigs don't linger."
  @spec clear(term()) :: :ok
  def clear(rig_id) do
    :ets.delete(@table, rig_id)
    :ok
  end

  # ---- reads (concurrent, direct ETS, any process) ----

  @doc "Full snapshot for one rig, or `nil` if the rig has not published / is gone."
  @spec get(term()) :: map() | nil
  def get(rig_id) do
    case :ets.lookup(@table, rig_id) do
      [{^rig_id, snap}] -> snap
      [] -> nil
    end
  end

  @doc "One field from a rig's snapshot, or `default` if the rig or field is absent."
  @spec field(term(), atom(), any()) :: any()
  def field(rig_id, key, default \\ nil) do
    case get(rig_id) do
      nil -> default
      snap -> Map.get(snap, key, default)
    end
  end

  @doc "Snapshots for all rigs, as `%{rig_id => snapshot}`. The dashboard view."
  @spec all() :: %{optional(term()) => map()}
  def all do
    @table
    |> :ets.tab2list()
    |> Map.new()
  end

  @doc "The rig_ids currently present."
  @spec rigs() :: [term()]
  def rigs, do: :ets.select(@table, [{{:"$1", :_}, [], [:"$1"]}])
end
