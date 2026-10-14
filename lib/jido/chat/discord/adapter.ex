defmodule Jido.Chat.Discord.Adapter do
  @moduledoc "Discord `Jido.Chat.Adapter` implementation using Nostrum.\n"
  use Jido.Chat.Adapter

  alias Jido.Chat.{
    ChannelInfo,
    FileUpload,
    Media,
    MessagePage,
    ThreadPage,
    WebhookRequest,
    WebhookResponse
  }

  alias Jido.Chat.Discord.{
    DeleteOptions,
    EditOptions,
    FetchOptions,
    GatewayWorker,
    NostrumGatewayBuffer,
    NostrumGatewayListener,
    MetadataOptions,
    ReactionOptions,
    SendOptions,
    TypingOptions
  }

  alias Jido.Chat.Discord.Transport.NostrumClient
  @media_type_pattern ~r/^[a-z0-9!#$&^_.+-]+\/[a-z0-9!#$&^_.+-]+$/
  @media_kind_extensions %{
    ".aac" => :audio,
    ".avi" => :video,
    ".avif" => :image,
    ".bmp" => :image,
    ".flac" => :audio,
    ".gif" => :image,
    ".heic" => :image,
    ".heif" => :image,
    ".jpeg" => :image,
    ".jpg" => :image,
    ".m4a" => :audio,
    ".m4v" => :video,
    ".mkv" => :video,
    ".mov" => :video,
    ".mp3" => :audio,
    ".mp4" => :video,
    ".ogg" => :audio,
    ".png" => :image,
    ".svg" => :image,
    ".tif" => :image,
    ".tiff" => :image,
    ".wav" => :audio,
    ".webm" => :video,
    ".webp" => :image
  }
  @impl true
  def channel_type do
    :discord
  end

  @impl true
  def signal_protocol, do: 1

  @impl true
  def configure_binding(opts) do
    {:ok,
     opts
     |> Keyword.put_new(:transport, NostrumClient)
     |> Keyword.put_new(:public_key, Application.get_env(:jido_chat_discord, :discord_public_key))}
  end

  @impl true
  def normalize_event(binding, %WebhookRequest{} = request) do
    with :ok <- verify_webhook(request, binding.options),
         {:ok, payload} <- verified_payload(request, binding.options),
         do: normalize_event(binding, payload)
  end

  def normalize_event(binding, input) do
    tracker = {__MODULE__, make_ref()}
    Process.put(tracker, [])

    result =
      try do
        events = if is_list(input), do: input, else: [input]
        items = Enum.map(events, &native_input/1)
        delivery = "discord:" <> native_digest({binding.id, native_canonical(items)})
        context = %{binding: binding, delivery: delivery, tracker: tracker}
        with {:ok, facts} <- native_items(context, items), do: Jido.Chat.Delivery.new(binding, delivery, facts)
      rescue
        _ -> Jido.Chat.Signal.Policy.error(:invalid_delivery)
      catch
        _, _ -> Jido.Chat.Signal.Policy.error(:invalid_delivery)
      end

    if match?({:error, _}, result), do: Enum.each(Process.get(tracker, []), &Jido.Chat.cancel_resource(binding, &1))
    Process.delete(tracker)
    result
  end

  defp native_input({event, payload}), do: {event |> to_string() |> String.upcase(), payload, nil}

  defp native_input(%{} = input) do
    payload = native_get(input, "d") || native_get(input, "payload") || input
    kind = native_get(input, "t") || native_get(input, "event")
    kind = kind || if(native_get(payload, "type") in [1, 2, 3, 5], do: "INTERACTION_CREATE", else: "MESSAGE_CREATE")
    {kind |> to_string() |> String.upcase(), payload, native_get(input, "s")}
  end

  defp native_input(_), do: {"invalid", nil, nil}

  defp native_items(context, items) do
    items
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {{kind, payload, sequence}, index}, {:ok, acc} ->
      identity =
        native_id(payload, "id") || native_id(payload, "message_id") || native_digest(native_canonical(payload))

      context = Map.merge(context, %{item: "discord:#{kind}:#{sequence || identity}:0", index: index})
      previous = Process.get(context.tracker)

      result =
        try do
          native_map(context, kind, payload)
        rescue
          _ -> {:error, :invalid_item}
        catch
          _, _ -> {:error, :invalid_item}
        end

      case result do
        {:ok, facts} ->
          if Enum.all?(List.wrap(facts), &(&1.type == "jido.chat.normalization.failed")) do
            Enum.each(Process.get(context.tracker) -- previous, &Jido.Chat.cancel_resource(context.binding, &1))
          end

          {:cont, {:ok, acc ++ List.wrap(facts)}}

        {:error, %Jido.Chat.Errors.Contract{code: code}} = error
        when code in [:signal_too_large, :delivery_too_large, :too_many_signals, :too_many_failures] ->
          {:halt, error}

        _ ->
          Enum.each(Process.get(context.tracker) -- previous, &Jido.Chat.cancel_resource(context.binding, &1))

          case native_failure(context, "invalid_item", kind, nil) do
            {:ok, fact} -> {:cont, {:ok, acc ++ [fact]}}
            error -> {:halt, error}
          end
      end
    end)
  end

  defp native_map(context, kind, payload) when is_map(payload) do
    room = native_id(payload, "channel_id")
    id = native_id(payload, "id") || native_id(payload, "message_id")

    case kind do
      "MESSAGE_CREATE" ->
        with {:ok, message} <- provider_message(payload), {:ok, media} <- native_media(context, message.media) do
          native_fact(context, Jido.Chat.Signal.MessageReceived, %{
            "room_id" => message.external_room_id,
            "message_id" => id,
            "sender" => native_actor(native_get(payload, "author") || %{}, context.binding),
            "text" => message.text || "",
            "thread_id" => message.external_thread_id,
            "media" => media,
            "timestamp" => native_time(native_get(payload, "timestamp")),
            "conversation_kind" => if(message.chat_type == :dm, do: "direct", else: "channel"),
            "mentions" => Enum.map(native_get(payload, "mentions") || [], &native_id(&1, "id")),
            "mentioned" =>
              Enum.any?(
                native_get(payload, "mentions") || [],
                &(native_id(&1, "id") == to_string(context.binding.options[:bot_id] || ""))
              ),
            "reply_to_id" => native_id(native_get(payload, "message_reference"), "message_id")
          })
        end

      "MESSAGE_UPDATE" ->
        with {:ok, media} <- native_media(context, extract_media(payload)) do
          native_fact(context, Jido.Chat.Signal.MessageUpdated, %{
            "room_id" => room,
            "message_id" => id,
            "text" => native_get(payload, "content"),
            "media" => media,
            "sender" =>
              if(native_get(payload, "author"), do: native_actor(native_get(payload, "author"), context.binding)),
            "timestamp" => native_time(native_get(payload, "edited_timestamp") || native_get(payload, "timestamp"))
          })
        end

      "MESSAGE_DELETE" ->
        native_fact(context, Jido.Chat.Signal.MessageDeleted, %{"room_id" => room, "message_id" => id})

      "MESSAGE_REACTION_ADD" ->
        native_reaction(context, payload, Jido.Chat.Signal.ReactionAdded)

      "MESSAGE_REACTION_REMOVE" ->
        native_reaction(context, payload, Jido.Chat.Signal.ReactionRemoved)

      "THREAD_CREATE" ->
        native_fact(context, Jido.Chat.Signal.ThreadStarted, %{
          "room_id" => native_id(payload, "parent_id"),
          "thread_id" => id,
          "name" => native_get(payload, "name"),
          "actor_id" => native_id(payload, "owner_id")
        })

      "INTERACTION_CREATE" ->
        native_interaction(context, payload)

      _ ->
        native_failure(context, "unsupported_item", kind, room)
    end
  end

  defp native_map(context, kind, _), do: native_failure(context, "invalid_item", kind, nil)

  defp native_reaction(context, payload, definition) do
    emoji = native_get(payload, "emoji") || %{}
    reaction = native_get(emoji, "name") || native_id(emoji, "id")

    native_fact(context, definition, %{
      "room_id" => native_id(payload, "channel_id"),
      "message_id" => native_id(payload, "message_id"),
      "actor_id" => native_id(payload, "user_id"),
      "reaction" => reaction
    })
  end

  defp native_interaction(context, payload) do
    type = native_get(payload, "type")

    if type == 1 do
      {:ok, []}
    else
      room = native_id(payload, "channel_id")
      interaction = native_id(payload, "id")
      data = native_get(payload, "data") || %{}
      user = native_get(payload, "user") || native_get(native_get(payload, "member"), "user") || %{}
      private = %{interaction_id: interaction, interaction_token: native_get(payload, "token"), room_id: room}

      with {:ok, ref} <- Jido.Chat.put_resource(context.binding, "result", private) do
        Process.put(context.tracker, [ref | Process.get(context.tracker)])
        :ets.insert(context.binding.resources, {{:discord_interaction, interaction}, ref})
        base = %{"room_id" => room, "interaction_id" => interaction, "actor_id" => native_id(user, "id")}

        case type do
          2 ->
            native_fact(
              context,
              Jido.Chat.Signal.SlashCommandReceived,
              Map.merge(base, %{
                "command" => "/" <> to_string(native_get(data, "name")),
                "text" => Enum.map_join(native_get(data, "options") || [], " ", &to_string(native_get(&1, "value")))
              })
            )

          3 ->
            values = native_get(data, "values") || []

            native_fact(
              context,
              Jido.Chat.Signal.ActionReceived,
              Map.merge(base, %{
                "action_id" => native_get(data, "custom_id"),
                "value" => List.first(values),
                "values" => %{to_string(native_get(data, "custom_id")) => values},
                "message_id" => native_id(native_get(payload, "message"), "id")
              })
            )

          5 ->
            values =
              Enum.reduce(native_get(data, "components") || [], %{}, fn row, acc ->
                Enum.reduce(native_get(row, "components") || [], acc, fn field, a ->
                  Map.put(a, native_get(field, "custom_id"), native_get(field, "value"))
                end)
              end)

            native_fact(
              context,
              Jido.Chat.Signal.ModalSubmitted,
              Map.merge(base, %{
                "view_id" => interaction,
                "callback_id" => native_get(data, "custom_id"),
                "values" => values
              })
            )

          _ ->
            native_failure(context, "unsupported_item", "interaction", room)
        end
      end
    end
  end

  @doc false
  def prepare_modal(%Jido.Chat.Binding{} = binding, interaction_id, modal) do
    with [{_, ref}] <- :ets.lookup(binding.resources, {:discord_interaction, interaction_id}),
         {:ok, controls} <- Jido.Chat.resolve_resource(binding, ref) do
      modal = Jido.Chat.Modal.new(modal)
      metadata = Map.merge(modal.metadata, controls)
      Jido.Chat.put_resource(binding, "modal", %{modal | metadata: metadata})
    else
      {:error, _} = error -> error
      _ -> Jido.Chat.Signal.Policy.error(:invalid_resource)
    end
  end

  defp native_media(context, media) do
    Enum.reduce_while(media, {:ok, []}, fn item, {:ok, acc} ->
      with {:ok, ref} <- Jido.Chat.put_resource(context.binding, "media", item) do
        Process.put(context.tracker, [ref | Process.get(context.tracker)])

        value =
          %{"kind" => to_string(item.kind), "resource_ref" => ref}
          |> native_optional("name", item.metadata[:filename])
          |> native_optional("media_type", item.media_type)

        {:cont, {:ok, acc ++ [value]}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp native_fact(context, definition, data) do
    room = data["room_id"]
    data = Map.merge(data, %{"item_id" => context.item, "delivery_id" => context.delivery})
    data = Map.reject(data, fn {key, value} -> is_nil(value) and key != "text" end)

    subject =
      if is_binary(room) and room != "", do: Jido.Chat.Signal.Identity.conversation_subject(context.binding.id, room)

    definition.new(data, source: context.binding.source, subject: subject)
  end

  defp native_failure(context, code, kind, room),
    do:
      native_fact(context, Jido.Chat.Signal.NormalizationFailed, %{
        "code" => code,
        "provider_kind" => kind,
        "item_index" => context.index,
        "room_id" => room
      })

  defp native_actor(user, binding),
    do:
      %{
        "id" => native_id(user, "id"),
        "username" => native_get(user, "username"),
        "display_name" => native_get(user, "global_name") || native_get(user, "username"),
        "is_bot" => native_get(user, "bot") == true,
        "is_self" => native_id(user, "id") == to_string(binding.options[:bot_id] || "")
      }
      |> Map.reject(fn {_, v} -> is_nil(v) end)

  defp native_get(map, key) when is_map(map) do
    atom =
      try do
        String.to_existing_atom(key)
      rescue
        ArgumentError -> nil
      end

    if Map.has_key?(map, key), do: Map.get(map, key), else: Map.get(map, atom)
  end

  defp native_get(_, _), do: nil

  defp native_id(map, key) do
    case native_get(map, key) do
      v when is_binary(v) and v != "" -> v
      v when is_integer(v) -> to_string(v)
      _ -> nil
    end
  end

  defp native_time(%DateTime{} = t), do: DateTime.to_iso8601(t)
  defp native_time(t) when is_binary(t), do: t
  defp native_time(_), do: nil
  defp native_optional(map, _, nil), do: map
  defp native_optional(map, k, v), do: Map.put(map, k, v)
  defp native_canonical(%_{} = data), do: data |> Map.from_struct() |> native_canonical()

  defp native_canonical(data) when is_map(data),
    do: data |> Enum.map(fn {k, v} -> {to_string(k), native_canonical(v)} end) |> Enum.sort()

  defp native_canonical(data) when is_list(data), do: Enum.map(data, &native_canonical/1)
  defp native_canonical({kind, payload, sequence}), do: {kind, native_canonical(payload), sequence}
  defp native_canonical(data), do: data
  defp native_digest(data), do: :crypto.hash(:sha256, :erlang.term_to_binary(data)) |> Base.url_encode64(padding: false)

  defp portable_message(incoming) do
    %{
      id: incoming.external_message_id,
      room_id: incoming.external_room_id,
      text: incoming.text || "",
      thread_id: incoming.external_thread_id,
      sender: %{
        id: to_string(incoming.external_user_id),
        username: incoming.username,
        display_name: incoming.display_name
      },
      timestamp: incoming.timestamp,
      attachments: incoming.media,
      raw: incoming.raw
    }
  end

  @impl true
  @spec capabilities() :: map()
  def capabilities do
    %{
      initialize: :fallback,
      shutdown: :fallback,
      send_message: :native,
      send_file: :native,
      edit_message: :native,
      delete_message: :native,
      start_typing: :native,
      fetch_metadata: :native,
      fetch_thread: :native,
      fetch_message: :native,
      fetch_media: :native,
      add_reaction: :native,
      remove_reaction: :native,
      post_ephemeral: :native,
      open_dm: :native,
      fetch_messages: :native,
      fetch_channel_messages: :native,
      list_threads: :native,
      open_thread: :native,
      post_channel_message: :fallback,
      stream: :fallback,
      open_modal: :native,
      webhook: :native,
      verify_webhook: :native,
      parse_event: :native,
      format_webhook_response: :native
    }
  end

  @impl true
  def listener_child_specs(bridge_id, opts \\ []) when is_binary(bridge_id) and is_list(opts) do
    ingress = normalize_ingress_opts(opts)

    case ingress_mode(ingress) do
      :webhook ->
        {:ok, []}

      :gateway ->
        with {:ok, sink_mfa} <- validate_sink_mfa(Keyword.get(opts, :sink_mfa)),
             %Jido.Chat.Binding{} = binding <- Keyword.get(opts, :binding) do
          gateway_listener_specs(bridge_id, binding, ingress, sink_mfa)
        else
          nil -> {:error, :invalid_binding}
          {:error, _} = error -> error
        end

      :invalid ->
        {:error, :invalid_ingress_mode}
    end
  end

  defp provider_message(%Nostrum.Struct.Message{} = msg) do
    do_transform_incoming(Map.from_struct(msg))
  end

  defp provider_message(%{channel_id: channel_id} = msg) when is_map(msg) do
    _ = channel_id
    do_transform_incoming(msg)
  end

  defp provider_message(%{"channel_id" => channel_id} = msg) when is_map(msg) do
    _ = channel_id
    do_transform_incoming(msg)
  end

  defp provider_message(_) do
    {:error, :unsupported_message_type}
  end

  @impl true
  def send_message(channel_id, text, opts \\ []) do
    opts = SendOptions.new(opts)

    with {:ok, result} <-
           transport(opts).send_message(channel_id, text, SendOptions.transport_opts(opts)) do
      {:ok,
       %{
         message_id: map_get(result, [:message_id, "message_id"]),
         channel_id: map_get(result, [:channel_id, "channel_id"]),
         timestamp: map_get(result, [:timestamp, "timestamp"]),
         channel_type: :discord,
         status: :sent,
         raw: result
       }}
    end
  end

  @impl true
  def send_file(channel_id, file, opts \\ []) do
    upload = FileUpload.normalize(file)

    with {:ok, file_opt} <- upload_input(upload),
         {:ok, result} <-
           transport(opts).send_message(
             channel_id,
             upload_caption(upload),
             upload_transport_opts(opts, file_opt)
           ) do
      {:ok, upload_response(upload, result, channel_id)}
    end
  end

  @impl true
  def edit_message(channel_id, message_id, text, opts \\ []) do
    opts = EditOptions.new(opts)

    with {:ok, result} <-
           transport(opts).edit_message(
             channel_id,
             message_id,
             text,
             EditOptions.transport_opts(opts)
           ) do
      {:ok,
       %{
         message_id: map_get(result, [:message_id, "message_id"]) || message_id,
         channel_id: map_get(result, [:channel_id, "channel_id"]) || channel_id,
         timestamp: map_get(result, [:timestamp, "timestamp"]),
         channel_type: :discord,
         status: :edited,
         raw: result
       }}
    end
  end

  @impl true
  def delete_message(channel_id, message_id, opts \\ []) do
    opts = opts |> pick_opts([:transport, :nostrum_message_api]) |> DeleteOptions.new()

    with {:ok, _result} <-
           transport(opts).delete_message(
             channel_id,
             message_id,
             DeleteOptions.transport_opts(opts)
           ) do
      :ok
    end
  end

  @impl true
  def start_typing(channel_id, opts \\ []) do
    opts = opts |> pick_opts([:transport, :status, :nostrum_channel_api]) |> TypingOptions.new()

    with {:ok, _result} <-
           transport(opts).start_typing(channel_id, TypingOptions.transport_opts(opts)) do
      :ok
    end
  end

  @impl true
  def fetch_metadata(channel_id, opts \\ []) do
    opts = opts |> pick_opts([:transport, :nostrum_channel_api]) |> MetadataOptions.new()

    with {:ok, result} <-
           transport(opts).fetch_metadata(channel_id, MetadataOptions.transport_opts(opts)) do
      {:ok, normalize_channel_info(result, channel_id)}
    end
  end

  @impl true
  def fetch_thread(channel_id, opts \\ []) do
    with {:ok, info} <- fetch_metadata(channel_id, opts) do
      {:ok,
       %{
         id: to_string(channel_id),
         adapter_name: :discord,
         external_room_id: channel_id,
         metadata: info.metadata,
         channel_id: "discord:#{channel_id}"
       }}
    end
  end

  @impl true
  def fetch_message(channel_id, message_id, opts \\ []) do
    opts = pick_opts(opts, [:transport, :nostrum_message_api])

    with {:ok, raw_message} <- transport(opts).fetch_message(channel_id, message_id, opts),
         {:ok, incoming} <- provider_message(raw_message) do
      {:ok, portable_message(incoming)}
    end
  end

  @impl true
  def fetch_media(reference, opts \\ []) do
    opts = pick_opts(opts, [:transport, :req, :nostrum_message_api])

    with {:ok, url, context} <- media_reference(reference) do
      case transport(opts).download_file(url, opts) do
        {:error, {:http_error, status, _body}} = error when status in [403, 404] ->
          retry_media_download(context, opts, error)

        result ->
          result
      end
    end
  end

  @impl true
  def open_dm(user_id, opts \\ []) do
    opts = pick_opts(opts, [:transport, :nostrum_user_api])
    transport(opts).open_dm(user_id, opts)
  end

  @impl true
  def open_thread(channel_id, message_id, opts \\ []) do
    with {:ok, result} <- transport(opts).open_thread(channel_id, message_id, opts) do
      {:ok,
       %{
         external_thread_id: stringify(result[:external_thread_id] || result["external_thread_id"]),
         delivery_external_room_id:
           stringify(result[:delivery_external_room_id] || result["delivery_external_room_id"]),
         parent_id: stringify(result[:parent_id] || result["parent_id"])
       }}
    end
  end

  @impl true
  def post_ephemeral(_channel_id, user_id, text, opts \\ []) do
    interaction_id = opts[:interaction_id]
    interaction_token = opts[:interaction_token]

    cond do
      interaction_id && is_binary(interaction_token) ->
        interaction_opts = pick_opts(opts, [:transport, :nostrum_interaction_api])
        payload = %{type: 4, data: %{content: text, flags: 64}}

        with {:ok, _response} <-
               transport(interaction_opts).create_interaction_response(
                 interaction_id,
                 interaction_token,
                 payload,
                 interaction_opts
               ) do
          {:ok,
           %{
             id: "discord:interaction:#{interaction_id}",
             thread_id: "discord:interaction:#{interaction_id}",
             used_fallback: false,
             raw: payload,
             metadata: %{interaction_id: to_string(interaction_id)}
           }}
        end

      Keyword.get(opts, :fallback_to_dm, false) ->
        send_opts = Keyword.drop(opts, [:fallback_to_dm])

        with {:ok, dm_room_id} <- open_dm(user_id, send_opts),
             {:ok, %{} = response} <- send_message(dm_room_id, text, send_opts) do
          {:ok,
           %{
             id: response.message_id || Jido.Chat.ID.generate!(),
             thread_id: "discord:#{dm_room_id}",
             used_fallback: true,
             raw: response.raw,
             metadata: %{channel_id: dm_room_id}
           }}
        end

      true ->
        {:error, :unsupported}
    end
  end

  @impl true
  def open_modal(channel_id, payload, opts \\ []) when is_map(payload) do
    interaction_id = opts[:interaction_id] || Map.get(Map.get(payload, :metadata, %{}), :interaction_id)
    interaction_token = opts[:interaction_token] || Map.get(Map.get(payload, :metadata, %{}), :interaction_token)

    cond do
      is_nil(interaction_id) or not is_binary(interaction_token) ->
        {:error, :missing_interaction_context}

      Map.get(Map.get(payload, :metadata, %{}), :room_id, channel_id) != channel_id ->
        {:error, :interaction_room_mismatch}

      true ->
        interaction_opts = pick_opts(opts, [:transport, :nostrum_interaction_api])
        request_payload = %{type: 9, data: normalize_modal_payload(modal_payload(payload))}

        with {:ok, _response} <-
               transport(interaction_opts).create_interaction_response(
                 interaction_id,
                 interaction_token,
                 request_payload,
                 interaction_opts
               ) do
          {:ok,
           %{
             id: "discord:modal:#{interaction_id}",
             status: :opened,
             external_room_id: channel_id,
             raw: request_payload,
             metadata: %{interaction_id: to_string(interaction_id)}
           }}
        end
    end
  end

  @impl true
  def add_reaction(channel_id, message_id, emoji, opts \\ []) do
    opts = opts |> pick_opts([:transport, :nostrum_message_api]) |> ReactionOptions.new()

    with {:ok, _result} <-
           transport(opts).add_reaction(
             channel_id,
             message_id,
             emoji,
             ReactionOptions.transport_opts(opts)
           ) do
      :ok
    end
  end

  @impl true
  def remove_reaction(channel_id, message_id, emoji, opts \\ []) do
    opts = opts |> pick_opts([:transport, :nostrum_message_api]) |> ReactionOptions.new()

    with {:ok, _result} <-
           transport(opts).remove_reaction(
             channel_id,
             message_id,
             emoji,
             ReactionOptions.transport_opts(opts)
           ) do
      :ok
    end
  end

  @impl true
  def fetch_messages(channel_id, opts \\ []) do
    opts =
      opts
      |> pick_opts([:transport, :cursor, :limit, :direction, :nostrum_channel_api])
      |> FetchOptions.new()

    with {:ok, result} <-
           transport(opts).fetch_messages(channel_id, FetchOptions.transport_opts(opts)) do
      {:ok,
       MessagePage.new(%{
         messages: normalize_messages(map_get(result, [:messages, "messages"]) || []),
         next_cursor: map_get(result, [:next_cursor, "next_cursor"]),
         direction: opts.direction,
         metadata: %{raw: result}
       })}
    end
  end

  @impl true
  def fetch_channel_messages(channel_id, opts \\ []) do
    fetch_messages(channel_id, opts)
  end

  @impl true
  def list_threads(channel_id, opts \\ []) do
    opts = pick_opts(opts, [:transport, :nostrum_channel_api])

    with {:ok, result} <- transport(opts).list_threads(channel_id, opts) do
      threads = map_get(result, [:threads, "threads"]) || []
      next_cursor = map_get(result, [:next_cursor, "next_cursor"])

      {:ok,
       ThreadPage.new(%{
         threads: Enum.map(threads, &normalize_thread_summary(channel_id, &1)),
         next_cursor: stringify(next_cursor),
         metadata: %{raw: result}
       })}
    end
  end

  @impl true
  def verify_webhook(%WebhookRequest{} = request, opts \\ []) do
    public_key =
      if Keyword.has_key?(opts, :public_key),
        do: opts[:public_key],
        else: opts[:discord_public_key] || Application.get_env(:jido_chat_discord, :discord_public_key)

    if is_nil(public_key) do
      {:error, :missing_public_key}
    else
      verify_discord_signature(request, public_key, opts)
    end
  end

  @impl true
  def format_webhook_response(result, opts \\ [])

  def format_webhook_response({:ok, %Jido.Chat.Delivery{}}, opts) do
    if ping_request?(opts),
      do: WebhookResponse.new(%{status: 200, body: %{type: 1}}),
      else: WebhookResponse.accepted(%{ok: true})
  end

  def format_webhook_response({:error, %Jido.Chat.Errors.Contract{code: code}}, _opts),
    do: WebhookResponse.error(400, %{error: Atom.to_string(code)})

  def format_webhook_response({:ok, _chat, :noop}, opts) do
    if ping_request?(opts) do
      WebhookResponse.new(%{status: 200, body: %{type: 1}})
    else
      WebhookResponse.accepted(%{ok: true})
    end
  end

  def format_webhook_response({:ok, _chat, _event}, _opts) do
    WebhookResponse.accepted(%{ok: true})
  end

  def format_webhook_response({:error, :invalid_signature}, _opts) do
    WebhookResponse.error(401, %{error: "invalid_signature"})
  end

  def format_webhook_response({:error, reason}, _opts) do
    _ = reason
    WebhookResponse.error(400, %{error: "rejected"})
  end

  defp upload_transport_opts(opts, file_opt) do
    opts
    |> pick_opts([
      :transport,
      :embeds,
      :components,
      :tts,
      :allowed_mentions,
      :message_reference,
      :reply_to_id,
      :nostrum_message_api
    ])
    |> Keyword.put(:file, file_opt)
  end

  defp upload_response(%FileUpload{} = upload, result, channel_id) do
    attachment =
      (result[:attachments] || result["attachments"] || []) |> List.first() |> normalize_map()

    delivered_kind =
      case attachment[:content_type] || attachment["content_type"] do
        <<"image/", _::binary>> -> :image
        _ -> upload.kind
      end

    %{
      message_id: stringify(result[:message_id] || result["message_id"]),
      channel_id: stringify(result[:channel_id] || result["channel_id"] || channel_id),
      timestamp: result[:timestamp] || result["timestamp"],
      channel_type: :discord,
      status: :sent,
      raw: result[:raw] || result["raw"] || result,
      metadata:
        %{
          attachment_id: attachment[:id] || attachment["id"],
          filename: attachment[:filename] || attachment["filename"],
          size: attachment[:size] || attachment["size"],
          url: attachment[:url] || attachment["url"],
          content_type: attachment[:content_type] || attachment["content_type"],
          upload_kind: upload.kind,
          delivered_kind: delivered_kind
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()
    }
  end

  defp upload_input(%FileUpload{path: path}) when is_binary(path) and path != "" do
    {:ok, path}
  end

  defp upload_input(%FileUpload{data: data, filename: filename})
       when is_binary(data) and data != "" and is_binary(filename) and filename != "" do
    {:ok, %{body: data, name: filename}}
  end

  defp upload_input(%FileUpload{data: data}) when is_binary(data) and data != "" do
    {:error, :missing_filename}
  end

  defp upload_input(%FileUpload{url: url}) when is_binary(url) and url != "" do
    {:error, :unsupported_remote_url}
  end

  defp upload_input(_upload) do
    {:error, :missing_file_source}
  end

  defp upload_caption(%FileUpload{} = upload) do
    metadata = upload.metadata

    metadata[:caption] || metadata["caption"] || metadata[:alt_text] || metadata["alt_text"] ||
      metadata[:transcript] || metadata["transcript"]
  end

  defp normalize_map(%_{} = struct) do
    Map.from_struct(struct)
  end

  defp normalize_map(map) when is_map(map) do
    map
  end

  defp normalize_map(_) do
    %{}
  end

  defp interaction_ping_payload?(payload) when is_map(payload) do
    map_get(payload, [:type, "type"]) == 1
  end

  defp verify_discord_signature(%WebhookRequest{} = request, public_key, opts) do
    signature = request.headers["x-signature-ed25519"] || request.headers["X-Signature-Ed25519"]

    timestamp =
      request.headers["x-signature-timestamp"] || request.headers["X-Signature-Timestamp"]

    raw_body =
      opts[:raw_body] || request.metadata[:raw_body] || request.metadata["raw_body"] ||
        request.raw

    with true <- is_binary(signature),
         true <- is_binary(timestamp),
         true <- is_binary(raw_body),
         {:ok, signature_bytes} <- decode_hex(signature),
         {:ok, public_key_bytes} <- decode_hex(public_key),
         true <-
           :crypto.verify(:eddsa, :none, timestamp <> raw_body, signature_bytes, [
             public_key_bytes,
             :ed25519
           ]) do
      :ok
    else
      _ -> {:error, :invalid_signature}
    end
  end

  defp decode_hex(hex) when is_binary(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :invalid_hex}
    end
  end

  defp transport(%{transport: transport}) when not is_nil(transport) do
    transport
  end

  defp transport(opts) when is_list(opts) do
    Keyword.get(opts, :transport, NostrumClient)
  end

  defp transport(_opts) do
    NostrumClient
  end

  defp get_map_value(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key -> Map.get(map, key) end)
  end

  defp get_nested_id(nil) do
    nil
  end

  defp get_nested_id(author) when is_map(author) do
    get_map_value(author, [:id, "id"])
  end

  defp get_nested_username(nil) do
    nil
  end

  defp get_nested_username(author) when is_map(author) do
    get_map_value(author, [:username, "username"])
  end

  defp get_nested_display_name(nil) do
    nil
  end

  defp get_nested_display_name(author) when is_map(author) do
    get_map_value(author, [:global_name, "global_name"]) ||
      get_map_value(author, [:username, "username"])
  end

  defp parse_chat_type(msg) when is_map(msg) do
    channel_type = get_map_value(msg, [:type, "type"])
    guild_id = get_map_value(msg, [:guild_id, "guild_id"])

    cond do
      thread_channel_type?(channel_type) -> :thread
      is_nil(guild_id) -> :dm
      true -> :guild
    end
  end

  defp do_transform_incoming(msg) when is_map(msg) do
    route = thread_route(msg)
    chat_type = parse_chat_type(msg)

    {:ok,
     %{
       external_room_id: route.external_room_id,
       external_user_id: get_map_value(msg, [:author, "author"]) |> get_nested_id(),
       text: get_map_value(msg, [:content, "content"]),
       media: extract_media(msg),
       username: get_map_value(msg, [:author, "author"]) |> get_nested_username(),
       display_name: get_map_value(msg, [:author, "author"]) |> get_nested_display_name(),
       external_message_id: get_map_value(msg, [:id, "id"]),
       timestamp: get_map_value(msg, [:timestamp, "timestamp"]),
       chat_type: chat_type,
       chat_title: nil,
       external_thread_id: route.external_thread_id,
       delivery_external_room_id: route.delivery_external_room_id,
       channel_meta: %{
         adapter_name: :discord,
         external_room_id: route.external_room_id,
         external_thread_id: route.external_thread_id,
         delivery_external_room_id: route.delivery_external_room_id,
         chat_type: chat_type,
         chat_title: nil,
         is_dm: chat_type == :dm,
         metadata: %{parent_id: route.parent_id, channel_id: route.channel_id}
       },
       raw: msg
     }}
  end

  defp thread_route(msg) when is_map(msg) do
    channel_id = stringify(get_map_value(msg, [:channel_id, "channel_id"]))

    nested_parent_id =
      case get_map_value(msg, [:thread, "thread"]) do
        thread when is_map(thread) -> get_map_value(thread, [:parent_id, "parent_id"])
        _ -> nil
      end

    parent_id = stringify(get_map_value(msg, [:parent_id, "parent_id"]) || nested_parent_id)
    channel_type = get_map_value(msg, [:type, "type"])

    if thread_channel_type?(channel_type) or not is_nil(parent_id) do
      %{
        channel_id: channel_id,
        parent_id: parent_id || channel_id,
        external_room_id: parent_id || channel_id,
        external_thread_id: channel_id,
        delivery_external_room_id: channel_id
      }
    else
      %{
        channel_id: channel_id,
        parent_id: nil,
        external_room_id: channel_id,
        external_thread_id: nil,
        delivery_external_room_id: channel_id
      }
    end
  end

  defp thread_channel_type?(type) do
    type in [10, 11, 12, :thread, "thread"]
  end

  defp extract_media(msg) when is_map(msg) do
    context = %{
      channel_id: stringify(get_map_value(msg, [:channel_id, "channel_id"])),
      message_id: stringify(get_map_value(msg, [:id, "id"]))
    }

    msg |> get_map_value([:attachments, "attachments"]) |> normalize_attachments(context)
  end

  defp normalize_attachments(attachments, context) when is_list(attachments) do
    attachments |> Enum.map(&normalize_attachment(&1, context)) |> Enum.reject(&is_nil/1)
  end

  defp normalize_attachments(_, _context) do
    []
  end

  defp normalize_attachment(%_{} = attachment, context) do
    attachment |> Map.from_struct() |> normalize_attachment(context)
  end

  defp normalize_attachment(attachment, context) when is_map(attachment) do
    media_type =
      attachment
      |> get_non_blank_map_value([:content_type, "content_type"])
      |> normalize_media_type()

    filename = get_non_blank_map_value(attachment, [:filename, "filename", :name, "name"])
    url = get_non_blank_map_value(attachment, [:url, "url", :proxy_url, "proxy_url"])

    metadata =
      context
      |> Map.put(:attachment_id, stringify(get_map_value(attachment, [:id, "id"])))
      |> Map.put(:filename, filename)
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    Media.new(%{
      kind: attachment_kind(media_type, filename, url),
      url: url,
      media_type: media_type,
      filename: filename,
      size_bytes: get_map_value(attachment, [:size, "size"]),
      width: get_map_value(attachment, [:width, "width"]),
      height: get_map_value(attachment, [:height, "height"]),
      metadata: metadata
    })
  end

  defp normalize_attachment(_, _context) do
    nil
  end

  defp media_reference(url) when is_binary(url) and url != "" do
    {:ok, url, nil}
  end

  defp media_reference(%Media{url: url, metadata: metadata}) when is_binary(url) and url != "" do
    {:ok, url, metadata}
  end

  defp media_reference(_reference) do
    {:error, :invalid_media_reference}
  end

  defp retry_media_download(context, opts, original_error) when is_map(context) do
    channel_id = get_map_value(context, [:channel_id, "channel_id"])
    message_id = get_map_value(context, [:message_id, "message_id"])

    with true <- not is_nil(channel_id) and not is_nil(message_id),
         {:ok, message} <- transport(opts).fetch_message(channel_id, message_id, opts),
         {:ok, refreshed_url} <- refreshed_attachment_url(message, context),
         result <- transport(opts).download_file(refreshed_url, opts) do
      result
    else
      false -> original_error
      {:error, reason} -> {:error, reason}
    end
  end

  defp retry_media_download(_context, _opts, original_error) do
    original_error
  end

  defp refreshed_attachment_url(message, context) when is_map(message) do
    attachment_id = stringify(get_map_value(context, [:attachment_id, "attachment_id"]))
    filename = get_map_value(context, [:filename, "filename"])
    attachments = get_map_value(message, [:attachments, "attachments"]) || []

    attachment =
      Enum.find(attachments, fn item ->
        not is_nil(attachment_id) and stringify(get_map_value(item, [:id, "id"])) == attachment_id
      end) ||
        Enum.find(attachments, fn item ->
          not is_nil(filename) and
            get_map_value(item, [:filename, "filename", :name, "name"]) == filename
        end)

    case attachment && get_map_value(attachment, [:url, "url", :proxy_url, "proxy_url"]) do
      url when is_binary(url) and url != "" -> {:ok, url}
      _ -> {:error, :refreshed_attachment_not_found}
    end
  end

  defp refreshed_attachment_url(_message, _context) do
    {:error, :refreshed_attachment_not_found}
  end

  defp attachment_kind(media_type, filename, url) do
    media_kind_from_type(media_type) || media_kind_from_reference(filename) ||
      media_kind_from_reference(url) || :file
  end

  defp media_kind_from_type(media_type) when is_binary(media_type) do
    case canonical_media_type(media_type) do
      "image/" <> _rest -> :image
      "audio/" <> _rest -> :audio
      "video/" <> _rest -> :video
      _other -> :file
    end
  end

  defp media_kind_from_type(_media_type) do
    nil
  end

  defp media_kind_from_reference(reference) when is_binary(reference) do
    reference
    |> URI.parse()
    |> Map.get(:path)
    |> case do
      path when is_binary(path) -> path |> Path.extname() |> String.downcase()
      _other -> ""
    end
    |> then(&Map.get(@media_kind_extensions, &1))
  end

  defp media_kind_from_reference(_reference) do
    nil
  end

  defp normalize_media_type(value) when is_binary(value) do
    trimmed = String.trim(value)

    if Regex.match?(@media_type_pattern, canonical_media_type(trimmed)) do
      trimmed
    else
      nil
    end
  end

  defp normalize_media_type(_value) do
    nil
  end

  defp canonical_media_type(value) do
    value |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase()
  end

  defp get_non_blank_map_value(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        value when is_binary(value) ->
          if String.trim(value) == "" do
            nil
          else
            value
          end

        _other ->
          nil
      end
    end)
  end

  defp normalize_channel_info(%ChannelInfo{} = info, _channel_id) do
    info
  end

  defp normalize_channel_info(%{} = info, channel_id) do
    type = map_get(info, [:type, "type"])

    ChannelInfo.new(%{
      id: to_string(map_get(info, [:id, "id"]) || channel_id),
      name: map_get(info, [:name, "name"]),
      is_dm: type in [1, :dm, "dm"],
      member_count: map_get(info, [:member_count, "member_count"]),
      metadata: info
    })
  end

  defp normalize_channel_info(_other, channel_id) do
    ChannelInfo.new(%{id: to_string(channel_id)})
  end

  defp normalize_messages(messages) when is_list(messages) do
    Enum.map(messages, fn raw_message ->
      case provider_message(raw_message) do
        {:ok, incoming} -> portable_message(incoming)
        _ -> raise ArgumentError, "invalid query item"
      end
    end)
  end

  defp normalize_thread_summary(_channel_id, raw_thread) when is_map(raw_thread) do
    thread_id = map_get(raw_thread, [:id, "id"])

    %{
      id: to_string(thread_id),
      reply_count:
        map_get(raw_thread, [:message_count, "message_count"]) ||
          map_get(raw_thread, [:member_count, "member_count"]),
      metadata: raw_thread
    }
  end

  defp modal_payload(%Jido.Chat.Modal{} = modal) do
    %{
      custom_id: modal.callback_id,
      title: modal.title,
      components:
        Enum.map(modal.elements, fn element ->
          %{
            type: 1,
            components: [%{type: 4, custom_id: element.id, label: element.label, style: 1, required: element.required}]
          }
        end)
    }
  end

  defp modal_payload(payload), do: payload

  defp normalize_modal_payload(payload) when is_map(payload) do
    %{
      custom_id: stringify(map_get(payload, [:custom_id, "custom_id"]) || "modal"),
      title: to_string(map_get(payload, [:title, "title"]) || "Modal"),
      components: map_get(payload, [:components, "components"]) || []
    }
  end

  defp ping_request?(opts) when is_list(opts) do
    request = Keyword.get(opts, :request)

    case request do
      %WebhookRequest{} -> interaction_ping_payload?(request.payload)
      map when is_map(map) -> interaction_ping_payload?(map[:payload] || map["payload"] || map)
      _ -> false
    end
  end

  defp map_get(nil, _keys) do
    nil
  end

  defp map_get(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key -> Map.get(map, key) end)
  end

  defp map_get(_other, _keys) do
    nil
  end

  defp stringify(nil) do
    nil
  end

  defp stringify(value) when is_binary(value) do
    value
  end

  defp stringify(value) do
    to_string(value)
  end

  defp pick_opts(opts, allowed_keys) when is_list(opts) do
    Keyword.take(opts, allowed_keys)
  end

  defp normalize_ingress_opts(opts) do
    ingress = Keyword.get(opts, :ingress, %{}) |> ensure_map()
    settings_ingress = settings_ingress(opts)
    Map.merge(settings_ingress, ingress)
  end

  defp settings_ingress(opts) do
    opts
    |> Keyword.get(:settings, %{})
    |> ensure_map()
    |> get_map_value([:ingress, "ingress"])
    |> ensure_map()
  end

  defp ensure_map(%{} = map) do
    map
  end

  defp ensure_map(_) do
    %{}
  end

  defp ingress_mode(ingress) do
    case get_map_value(ingress, [:mode, "mode"]) do
      nil -> :webhook
      :webhook -> :webhook
      :gateway -> :gateway
      "webhook" -> :webhook
      "gateway" -> :gateway
      _ -> :invalid
    end
  end

  defp validate_sink_mfa({module, function, args})
       when is_atom(module) and is_atom(function) and is_list(args) do
    {:ok, {module, function, args}}
  end

  defp validate_sink_mfa(_) do
    {:error, :invalid_sink_mfa}
  end

  defp gateway_worker_opts(bridge_id, binding, ingress, sink_mfa) do
    [
      bridge_id: bridge_id,
      binding: binding,
      sink_mfa: sink_mfa,
      sink_opts: [bridge_id: bridge_id],
      event_source_mfa: get_map_value(ingress, [:event_source_mfa, "event_source_mfa"]),
      poll_interval_ms: get_map_value(ingress, [:poll_interval_ms, "poll_interval_ms"]) || 250,
      max_backoff_ms: get_map_value(ingress, [:max_backoff_ms, "max_backoff_ms"]) || 5000
    ]
  end

  defp gateway_listener_specs(bridge_id, binding, ingress, sink_mfa) do
    case ingress_source(ingress) do
      :nostrum ->
        {:ok,
         [
           Supervisor.child_spec(
             {NostrumGatewayBuffer, nostrum_gateway_buffer_opts(bridge_id, ingress)},
             id: {:discord_gateway_buffer, bridge_id}
           ),
           Supervisor.child_spec(
             {NostrumGatewayListener, nostrum_gateway_listener_opts(bridge_id, ingress)},
             id: {:discord_gateway_listener, bridge_id}
           ),
           Supervisor.child_spec(
             {GatewayWorker,
              gateway_worker_opts(
                bridge_id,
                binding,
                Map.put(
                  ingress,
                  :event_source_mfa,
                  {NostrumGatewayBuffer, :pop_events, [bridge_id]}
                ),
                sink_mfa
              )},
             id: {:discord_gateway_worker, bridge_id}
           )
         ]}

      :mfa ->
        case get_map_value(ingress, [:event_source_mfa, "event_source_mfa"]) do
          {module, function, args} when is_atom(module) and is_atom(function) and is_list(args) ->
            {:ok,
             [
               Supervisor.child_spec(
                 {GatewayWorker, gateway_worker_opts(bridge_id, binding, ingress, sink_mfa)},
                 id: {:discord_gateway_worker, bridge_id}
               )
             ]}

          _other ->
            {:error, :invalid_event_source_mfa}
        end

      :invalid ->
        {:error, :invalid_ingress_source}
    end
  end

  defp ingress_source(ingress) do
    source = get_map_value(ingress, [:source, "source"])
    event_source_mfa = get_map_value(ingress, [:event_source_mfa, "event_source_mfa"])

    cond do
      source in [:nostrum, "nostrum"] -> :nostrum
      source in [:mfa, "mfa"] -> :mfa
      source in [nil, ""] and is_tuple(event_source_mfa) -> :mfa
      source in [nil, ""] -> :nostrum
      true -> :invalid
    end
  end

  defp nostrum_gateway_buffer_opts(bridge_id, ingress) do
    [
      bridge_id: bridge_id,
      max_events: get_map_value(ingress, [:max_events, "max_events"]) || 1000
    ]
  end

  defp nostrum_gateway_listener_opts(bridge_id, ingress) do
    [bridge_id: bridge_id, event_names: get_map_value(ingress, [:event_names, "event_names"])]
  end

  defp verified_payload(request, opts) do
    body = opts[:raw_body] || request.metadata[:raw_body] || request.metadata["raw_body"] || request.raw

    case Jason.decode(body) do
      {:ok, %{} = payload} -> {:ok, payload}
      _ -> Jido.Chat.Signal.Policy.error(:invalid_delivery)
    end
  end
end
