defmodule Minutewave.ALE.LQA.Store do
  @moduledoc """
  Behaviour for LQA observation persistence and retrieval.

  `Minutewave.ALE.LQA` owns the scoring and ranking math but not storage.
  A consumer implements this behaviour and registers it:

      config :minutewave, lqa_store: MyApp.ALE.LqaStore

  Observations arrive at the consumer via `{:ale, {:lqa_observation, map}}`
  events (see `Minutewave.ALE.LQA.record_observation/5`); the consumer
  persists them and answers the queries below for ranking.
  """

  @typedoc "A stored observation reduced to what ranking needs."
  @type observation :: %{
          freq_hz: integer(),
          timestamp: DateTime.t(),
          lqa_score: float() | nil
        }

  @doc """
  Return recent observations for `dest_addr` on `freq_list`, scoped to `rig_id`.

  Only observations within the `:hours` lookback window need be returned.
  Order is not significant; ranking groups by frequency itself.
  """
  @callback recent_observations(
              rig_id :: term(),
              dest_addr :: integer(),
              freq_list :: [integer()],
              opts :: keyword()
            ) :: [observation()]

  @doc """
  Return a map of `freq_hz => latest_timestamp` for `freq_list`, scoped to
  `rig_id`, within the `:hours` lookback window. Frequencies with no data
  may be omitted.
  """
  @callback last_heard_per_freq(
              rig_id :: term(),
              freq_list :: [integer()],
              opts :: keyword()
            ) :: %{optional(integer()) => DateTime.t()}
end
