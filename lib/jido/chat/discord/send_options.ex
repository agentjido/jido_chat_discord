defmodule Jido.Chat.Discord.SendOptions do
  @moduledoc """
  Typed options for Discord `send_message/3`.
  """

  alias Jido.Chat.Discord.Transport.NostrumClient

  @schema Zoi.struct(
            __MODULE__,
            %{
              transport: Zoi.any() |> Zoi.default(NostrumClient),
              embeds: Zoi.any() |> Zoi.nullish(),
              components: Zoi.any() |> Zoi.nullish(),
              tts: Zoi.boolean() |> Zoi.nullish(),
              allowed_mentions: Zoi.any() |> Zoi.nullish(),
              message_reference: Zoi.any() |> Zoi.nullish(),
              nostrum_message_api: Zoi.any() |> Zoi.nullish()
            },
            coerce: true
          )

  @type t :: unquote(Zoi.type_spec(@schema))

  @enforce_keys Zoi.Struct.enforce_keys(@schema)
  defstruct Zoi.Struct.struct_fields(@schema)

  @doc "Returns the Zoi schema for send options."
  def schema, do: @schema

  @doc "Builds typed send options from keyword, map, or struct input."
  def new(%__MODULE__{} = opts), do: opts
  def new(opts) when is_list(opts), do: opts |> Map.new() |> new()

  def new(opts) when is_map(opts) do
    opts
    |> normalize_generic_reply_reference()
    |> then(&Jido.Chat.Schema.parse!(__MODULE__, @schema, &1))
  end

  @doc "Builds transport-level options consumed by Discord transport clients."
  @spec transport_opts(t()) :: keyword()
  def transport_opts(%__MODULE__{} = opts) do
    []
    |> maybe_kw(:embeds, opts.embeds)
    |> maybe_kw(:components, opts.components)
    |> maybe_kw(:tts, opts.tts)
    |> maybe_kw(:allowed_mentions, opts.allowed_mentions)
    |> maybe_kw(:message_reference, opts.message_reference)
    |> maybe_kw(:nostrum_message_api, opts.nostrum_message_api)
  end

  defp maybe_kw(keyword, _key, nil), do: keyword
  defp maybe_kw(keyword, key, value), do: Keyword.put(keyword, key, value)

  defp normalize_generic_reply_reference(opts) do
    reply_to_id =
      Map.get(opts, :reply_to_id) ||
        Map.get(opts, "reply_to_id")

    message_reference =
      Map.get(opts, :message_reference) ||
        Map.get(opts, "message_reference")

    case {message_reference, reply_to_id} do
      {nil, nil} ->
        opts

      {nil, value} ->
        Map.put(opts, :message_reference, %{message_id: to_string(value)})

      _ ->
        opts
    end
  end
end
