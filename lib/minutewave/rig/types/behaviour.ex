defmodule Minutewave.Rig.Types.Behaviour do
  @moduledoc """
  Behaviour implemented by per-rig-type modules.

  Each rig type (`HF`, `HfRx`, `VHF`, `Test`, etc.) describes its
  capabilities, supported backends, audio constraints, and validation
  rules. The type modules are pure metadata — they return data, never
  perform I/O.

  Consumer products call `Minutewave.Rig.Types.module_for/1` with a
  string type identifier (typically loaded from configuration) and get
  back the matching module, then call functions defined here to learn
  what the rig can do.

  Note: this behaviour was implicit in `MinuteModemCore.Rig.Types.*`
  — referenced by `@behaviour` declarations but never actually defined
  as a module. Minutewave defines it explicitly.
  """

  @typedoc "Compact atom identifier for the rig type, e.g. :hf, :vhf, :hf_rx, :test"
  @type type_id :: atom()

  @typedoc "Audio configuration map. Keys are backend-defined; commonly :sample_rate, :channels, :buffer_size."
  @type audio_config :: map()

  @typedoc "Frequency range as `{min_hz, max_hz}` tuple, or `:any` for type modules with no constraint (test rigs)."
  @type frequency_range :: {pos_integer(), pos_integer()} | :any

  @typedoc "Faceplate UI configuration. Keys are product-defined; included in the contract because the type module is the source of truth for what UI a rig of this type should present."
  @type faceplate_config :: map()

  @typedoc "Default control-backend configuration for this rig type. The consumer customizes this further before instantiating a rig."
  @type control_config :: map()

  @typedoc "Validation result for a control config."
  @type validation :: :ok | {:error, term()}

  @doc "Atom identifier for this type (e.g. :hf)."
  @callback type_id() :: type_id

  @doc "Human-readable name for UI display."
  @callback display_name() :: String.t()

  @doc "Longer human-readable description."
  @callback description() :: String.t()

  @doc "List of control backend atoms supported by this rig type, e.g. `[:rigctld, :flrig]`."
  @callback supported_control_backends() :: [atom()]

  @doc "List of protocol atoms supported, e.g. `[:cw, :ssb, :data, :ale]`."
  @callback supported_protocols() :: [atom()]

  @doc "Audio configuration this rig type expects."
  @callback audio_config() :: audio_config

  @doc "Operating frequency range for this rig type."
  @callback frequency_range() :: frequency_range

  @doc "Whether this rig type can transmit. False for receive-only types (HfRx, Test)."
  @callback can_transmit?() :: boolean()

  @doc "Faceplate UI configuration for products that render rig UIs."
  @callback faceplate_config() :: faceplate_config

  @doc "Default control-backend configuration. The consumer customizes before instantiating."
  @callback default_control_config() :: control_config

  @doc "Validate a control config against this rig type's constraints."
  @callback validate_control_config(control_config) :: validation
end
