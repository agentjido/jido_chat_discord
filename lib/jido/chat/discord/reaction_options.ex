defmodule Jido.Chat.Discord.ReactionOptions do
  @moduledoc """
  Typed options for Discord reaction operations.
  """

  alias Jido.Chat.Discord.Transport.NostrumClient

  @schema Zoi.struct(
            __MODULE__,
            %{
              transport: Zoi.any() |> Zoi.default(NostrumClient),
              nostrum_message_api: Zoi.any() |> Zoi.nullish()
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for reaction options."
  def schema, do: @schema

  @doc "Builds typed reaction options from keyword, map, or struct input."
  def new(%__MODULE__{} = opts), do: opts
  def new(opts) when is_list(opts), do: opts |> Map.new() |> new()
  def new(opts) when is_map(opts), do: Jido.Chat.Schema.parse!(__MODULE__, @schema, opts)

  @doc "Builds transport-level options consumed by Discord transport clients."
  @spec transport_opts(t()) :: keyword()
  def transport_opts(%__MODULE__{} = opts) do
    []
    |> maybe_kw(:nostrum_message_api, opts.nostrum_message_api)
  end

  defp maybe_kw(keyword, _key, nil), do: keyword
  defp maybe_kw(keyword, key, value), do: Keyword.put(keyword, key, value)
end
