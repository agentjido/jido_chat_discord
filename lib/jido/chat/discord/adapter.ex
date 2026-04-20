defmodule Jido.Chat.Discord.Adapter do
  @moduledoc """
  Discord `Jido.Chat.Adapter` implementation using Nostrum.
  """

  use Jido.Chat.Adapter

  alias Jido.Chat.{
    ChannelInfo,
    EphemeralMessage,
    EventEnvelope,
    FileUpload,
    Incoming,
    Message,
    MessagePage,
    ModalResult,
    Response,
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

  @impl true
  def channel_type, do: :discord

  @impl true
  @spec capabilities() :: map()
  def capabilities,
    do: %{
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

  @impl true
  def listener_child_specs(bridge_id, opts \\ []) when is_binary(bridge_id) and is_list(opts) do
    ingress = normalize_ingress_opts(opts)

    case ingress_mode(ingress) do
      :webhook ->
        {:ok, []}

      :gateway ->
        with {:ok, sink_mfa} <- validate_sink_mfa(Keyword.get(opts, :sink_mfa)) do
          gateway_listener_specs(bridge_id, ingress, sink_mfa)
        end

      :invalid ->
        {:error, :invalid_ingress_mode}
    end
  end

  @impl true
  def transform_incoming(%Nostrum.Struct.Message{} = msg) do
    do_transform_incoming(Map.from_struct(msg))
  end

  def transform_incoming(%{channel_id: channel_id} = msg) when is_map(msg) do
    _ = channel_id
    do_transform_incoming(msg)
  end

  def transform_incoming(%{"channel_id" => channel_id} = msg) when is_map(msg) do
    _ = channel_id
    do_transform_incoming(msg)
  end

  def transform_incoming(_), do: {:error, :unsupported_message_type}

  @impl true
  def send_message(channel_id, text, opts \\ []) do
    opts = SendOptions.new(opts)

    with {:ok, result} <-
           transport(opts).send_message(channel_id, text, SendOptions.transport_opts(opts)) do
      {:ok,
       Response.new(%{
         message_id: map_get(result, [:message_id, "message_id"]),
         channel_id: map_get(result, [:channel_id, "channel_id"]),
         timestamp: map_get(result, [:timestamp, "timestamp"]),
         channel_type: :discord,
         status: :sent,
         raw: result
       })}
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
       Response.new(%{
         message_id: map_get(result, [:message_id, "message_id"]) || message_id,
         channel_id: map_get(result, [:channel_id, "channel_id"]) || channel_id,
         timestamp: map_get(result, [:timestamp, "timestamp"]),
         channel_type: :discord,
         status: :edited,
         raw: result
       })}
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
         id: "discord:#{channel_id}",
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
         {:ok, incoming} <- transform_incoming(raw_message) do
      {:ok,
       Message.from_incoming(incoming,
         adapter_name: :discord,
         thread_id: "discord:#{incoming.external_room_id}"
       )}
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
         external_thread_id:
           stringify(result[:external_thread_id] || result["external_thread_id"]),
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

        payload = %{
          type: 4,
          data: %{content: text, flags: 64}
        }

        with {:ok, _response} <-
               transport(interaction_opts).create_interaction_response(
                 interaction_id,
                 interaction_token,
                 payload,
                 interaction_opts
               ) do
          {:ok,
           EphemeralMessage.new(%{
             id: "discord:interaction:#{interaction_id}",
             thread_id: "discord:interaction:#{interaction_id}",
             used_fallback: false,
             raw: payload,
             metadata: %{interaction_id: to_string(interaction_id)}
           })}
        end

      Keyword.get(opts, :fallback_to_dm, false) ->
        send_opts = Keyword.drop(opts, [:fallback_to_dm])

        with {:ok, dm_room_id} <- open_dm(user_id, send_opts),
             {:ok, %Response{} = response} <- send_message(dm_room_id, text, send_opts) do
          {:ok,
           EphemeralMessage.new(%{
             id: response.external_message_id || Jido.Chat.ID.generate!(),
             thread_id: "discord:#{dm_room_id}",
             used_fallback: true,
             raw: response.raw,
             metadata: %{channel_id: dm_room_id}
           })}
        end

      true ->
        {:error, :unsupported}
    end
  end

  @impl true
  def open_modal(channel_id, payload, opts \\ []) when is_map(payload) do
    interaction_id = opts[:interaction_id]
    interaction_token = opts[:interaction_token]

    cond do
      is_nil(interaction_id) or not is_binary(interaction_token) ->
        {:error, :missing_interaction_context}

      true ->
        interaction_opts = pick_opts(opts, [:transport, :nostrum_interaction_api])

        request_payload = %{
          type: 9,
          data: normalize_modal_payload(payload)
        }

        with {:ok, _response} <-
               transport(interaction_opts).create_interaction_response(
                 interaction_id,
                 interaction_token,
                 request_payload,
                 interaction_opts
               ) do
          {:ok,
           ModalResult.new(%{
             id: "discord:modal:#{interaction_id}",
             status: :opened,
             external_room_id: channel_id,
             raw: request_payload,
             metadata: %{interaction_id: to_string(interaction_id)}
           })}
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
      opts[:discord_public_key] || opts[:public_key] ||
        Application.get_env(:jido_chat_discord, :discord_public_key)

    if is_nil(public_key) do
      :ok
    else
      verify_discord_signature(request, public_key, opts)
    end
  end

  @impl true
  def parse_event(%WebhookRequest{} = request, _opts \\ []) do
    parse_payload_event(request.payload, request.path)
  end

  @impl true
  def format_webhook_response(result, opts \\ [])

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
    WebhookResponse.error(400, %{error: to_string(reason)})
  end

  @impl true
  def handle_webhook(%Jido.Chat{} = chat, payload, opts \\ []) when is_map(payload) do
    request =
      WebhookRequest.new(%{
        adapter_name: :discord,
        headers: opts[:headers] || %{},
        payload: payload,
        raw: opts[:raw_body] || payload,
        metadata: %{raw_body: opts[:raw_body]}
      })

    with :ok <- verify_webhook(request, opts) do
      with {:ok, parsed_event} <- parse_event(request, opts),
           {:ok, updated_chat, incoming} <- route_parsed_event(chat, parsed_event, opts, request) do
        {:ok, updated_chat, incoming}
      end
    end
  end

  @doc "Gateway helper for non-webhook event families routed into `Jido.Chat.process_*`."
  @spec handle_gateway_event(Jido.Chat.t(), map() | {atom() | String.t(), map()}, keyword()) ::
          {:ok, Jido.Chat.t(), term()} | {:error, term()}
  def handle_gateway_event(chat, event, opts \\ [])

  def handle_gateway_event(%Jido.Chat{} = chat, {event_name, payload}, opts)
      when is_map(payload) do
    handle_gateway_event(chat, %{event: event_name, payload: payload}, opts)
  end

  def handle_gateway_event(%Jido.Chat{} = chat, %{} = event, opts) do
    event_name =
      event[:event] || event["event"] || event[:type] || event["type"] ||
        event[:t] || event["t"]

    payload = event[:payload] || event["payload"] || event

    case normalize_event_name(event_name) do
      "MESSAGE_REACTION_ADD" -> process_gateway_reaction(chat, payload, true, opts)
      "MESSAGE_REACTION_REMOVE" -> process_gateway_reaction(chat, payload, false, opts)
      "MESSAGE_CREATE" -> handle_webhook(chat, payload, opts)
      "INTERACTION_CREATE" -> handle_webhook(chat, payload, opts)
      "MODAL_CLOSE" -> process_gateway_modal_close(chat, payload, opts)
      _ -> {:error, :unsupported_gateway_event}
    end
  end

  defp route_parsed_event(chat, :noop, _opts, %WebhookRequest{} = request) do
    payload = request.payload

    if interaction_ping_payload?(payload) do
      {:ok, chat, synthetic_incoming("interaction", "discord", "ping", payload, :ping)}
    else
      {:error, :unsupported_message_type}
    end
  end

  defp route_parsed_event(chat, %EventEnvelope{} = envelope, opts, _request) do
    with {:ok, updated_chat, routed_envelope} <-
           Jido.Chat.process_event(chat, :discord, envelope, opts),
         {:ok, incoming} <- incoming_from_event(routed_envelope) do
      {:ok, updated_chat, incoming}
    end
  end

  defp route_parsed_event(_chat, _other, _opts, _request), do: {:error, :unsupported_message_type}

  defp incoming_from_event(%EventEnvelope{event_type: :message, payload: %Incoming{} = incoming}),
    do: {:ok, incoming}

  defp incoming_from_event(%EventEnvelope{event_type: event_type, raw: raw})
       when event_type in [:slash_command, :action, :modal_submit] do
    channel_id = map_get(raw, [:channel_id, "channel_id"])
    user = interaction_user(raw)
    message_id = map_get(raw, [:id, "id"])

    {:ok,
     synthetic_incoming(
       channel_id,
       user.user_id,
       message_id,
       raw,
       event_type
     )}
  end

  defp incoming_from_event(_), do: {:error, :unsupported_message_type}

  defp parse_payload_event(payload, path) when is_map(payload) do
    cond do
      interaction_ping_payload?(payload) ->
        {:ok, :noop}

      interaction_payload?(payload) ->
        interaction_event_envelope(payload)

      true ->
        with {:ok, incoming} <- transform_incoming(payload) do
          {:ok,
           EventEnvelope.new(%{
             adapter_name: :discord,
             event_type: :message,
             thread_id: thread_id(incoming),
             channel_id: stringify(incoming.external_room_id),
             message_id: stringify(incoming.external_message_id),
             payload: incoming,
             raw: payload,
             metadata: %{path: path}
           })}
        end
    end
  end

  defp parse_payload_event(_payload, _path), do: {:error, :unsupported_message_type}

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
      (result[:attachments] || result["attachments"] || [])
      |> List.first()
      |> normalize_map()

    delivered_kind =
      case attachment[:content_type] || attachment["content_type"] do
        <<"image/", _::binary>> -> :image
        _ -> upload.kind
      end

    Response.new(%{
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
    })
  end

  defp upload_input(%FileUpload{path: path}) when is_binary(path) and path != "", do: {:ok, path}

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

  defp upload_input(_upload), do: {:error, :missing_file_source}

  defp upload_caption(%FileUpload{} = upload) do
    metadata = upload.metadata || %{}

    metadata[:caption] || metadata["caption"] || metadata[:alt_text] || metadata["alt_text"] ||
      metadata[:transcript] || metadata["transcript"]
  end

  defp normalize_map(%_{} = struct), do: Map.from_struct(struct)
  defp normalize_map(map) when is_map(map), do: map
  defp normalize_map(_), do: %{}

  defp interaction_event_envelope(payload) do
    type = map_get(payload, [:type, "type"])
    channel_id = map_get(payload, [:channel_id, "channel_id"])
    user = interaction_user(payload)

    case type do
      2 ->
        slash_payload = %{
          adapter_name: :discord,
          channel_id: stringify(channel_id),
          command:
            "/" <> to_string(map_get(payload, [:data, "data"]) |> map_get([:name, "name"])),
          text: slash_arguments(payload),
          user: user,
          raw: payload,
          metadata: %{interaction_type: type}
        }

        {:ok,
         EventEnvelope.new(%{
           adapter_name: :discord,
           event_type: :slash_command,
           thread_id: "discord:#{channel_id}",
           channel_id: stringify(channel_id),
           message_id: stringify(map_get(payload, [:id, "id"])),
           payload: slash_payload,
           raw: payload,
           metadata: %{}
         })}

      3 ->
        data = map_get(payload, [:data, "data"]) || %{}
        message = map_get(payload, [:message, "message"]) || %{}

        action_payload = %{
          adapter_name: :discord,
          thread_id: "discord:#{channel_id}",
          message_id:
            stringify(map_get(data, [:message_id, "message_id"]) || map_get(message, [:id, "id"])),
          action_id: map_get(data, [:custom_id, "custom_id"]),
          value: inspect(map_get(data, [:values, "values"]) || %{}),
          user: user,
          raw: payload,
          metadata: %{interaction_type: type}
        }

        {:ok,
         EventEnvelope.new(%{
           adapter_name: :discord,
           event_type: :action,
           thread_id: "discord:#{channel_id}",
           channel_id: stringify(channel_id),
           message_id: stringify(map_get(payload, [:id, "id"])),
           payload: action_payload,
           raw: payload,
           metadata: %{}
         })}

      5 ->
        data = map_get(payload, [:data, "data"]) || %{}

        modal_payload = %{
          adapter_name: :discord,
          callback_id: map_get(data, [:custom_id, "custom_id"]),
          view_id: map_get(payload, [:id, "id"]) |> stringify(),
          values: normalize_modal_values(data),
          user: user,
          raw: payload,
          metadata: %{interaction_type: type}
        }

        {:ok,
         EventEnvelope.new(%{
           adapter_name: :discord,
           event_type: :modal_submit,
           thread_id: "discord:#{channel_id}",
           channel_id: stringify(channel_id),
           message_id: stringify(map_get(payload, [:id, "id"])),
           payload: modal_payload,
           raw: payload,
           metadata: %{}
         })}

      _ ->
        {:error, :unsupported_interaction_type}
    end
  end

  defp process_gateway_reaction(chat, payload, added, opts) do
    reaction_payload = %{
      adapter_name: :discord,
      thread_id: "discord:#{map_get(payload, [:channel_id, "channel_id"])}",
      message_id: stringify(map_get(payload, [:message_id, "message_id"])),
      emoji: reaction_emoji(payload),
      added: added,
      user: %{
        user_id: stringify(map_get(payload, [:user_id, "user_id"]) || "unknown"),
        user_name: stringify(map_get(payload, [:user_id, "user_id"]) || "unknown")
      },
      raw: payload,
      metadata: %{}
    }

    with {:ok, updated_chat, event} <-
           Jido.Chat.process_reaction(chat, :discord, reaction_payload, opts) do
      {:ok, updated_chat, event}
    end
  end

  defp process_gateway_modal_close(chat, payload, opts) do
    modal_close_payload = %{
      adapter_name: :discord,
      callback_id: stringify(map_get(payload, [:custom_id, "custom_id"])),
      view_id: stringify(map_get(payload, [:id, "id"])),
      raw: payload,
      metadata: %{}
    }

    with {:ok, updated_chat, event} <-
           Jido.Chat.process_modal_close(chat, :discord, modal_close_payload, opts) do
      {:ok, updated_chat, event}
    end
  end

  defp interaction_payload?(payload) when is_map(payload) do
    type = map_get(payload, [:type, "type"])
    type in [1, 2, 3, 5]
  end

  defp interaction_ping_payload?(payload) when is_map(payload),
    do: map_get(payload, [:type, "type"]) == 1

  defp interaction_user(payload) do
    member_user = map_get(payload, [:member, "member"]) |> map_get([:user, "user"])
    user = member_user || map_get(payload, [:user, "user"]) || %{}

    %{
      user_id: stringify(map_get(user, [:id, "id"]) || "unknown"),
      user_name:
        map_get(user, [:username, "username"]) ||
          stringify(map_get(user, [:id, "id"]) || "unknown"),
      full_name:
        map_get(user, [:global_name, "global_name"]) ||
          map_get(user, [:username, "username"])
    }
  end

  defp slash_arguments(payload) do
    payload
    |> map_get([:data, "data"])
    |> map_get([:options, "options"])
    |> case do
      list when is_list(list) ->
        list
        |> Enum.map(fn entry -> map_get(entry, [:value, "value"]) end)
        |> Enum.reject(&is_nil/1)
        |> Enum.map_join(" ", &to_string/1)

      _ ->
        ""
    end
  end

  defp normalize_modal_values(data) do
    data
    |> map_get([:components, "components"])
    |> case do
      components when is_list(components) ->
        Enum.reduce(components, %{}, fn component, acc ->
          inner = map_get(component, [:components, "components"]) || []

          Enum.reduce(inner, acc, fn field, inner_acc ->
            custom_id = map_get(field, [:custom_id, "custom_id"])
            value = map_get(field, [:value, "value"])
            if is_nil(custom_id), do: inner_acc, else: Map.put(inner_acc, custom_id, value)
          end)
        end)

      _ ->
        %{}
    end
  end

  defp synthetic_incoming(channel_id, user_id, message_id, raw, event_type) do
    Incoming.new(%{
      external_room_id: channel_id || "unknown",
      external_user_id: user_id,
      external_message_id: stringify(message_id),
      text: nil,
      raw: raw,
      metadata: %{event_type: event_type}
    })
  end

  defp reaction_emoji(payload) do
    emoji = map_get(payload, [:emoji, "emoji"]) || %{}
    map_get(emoji, [:name, "name"]) || ""
  end

  defp normalize_event_name(name) when is_atom(name),
    do: name |> Atom.to_string() |> String.upcase()

  defp normalize_event_name(name) when is_binary(name), do: String.upcase(name)
  defp normalize_event_name(_), do: ""

  defp verify_discord_signature(%WebhookRequest{} = request, public_key, opts) do
    signature =
      request.headers["x-signature-ed25519"] ||
        request.headers["X-Signature-Ed25519"]

    timestamp =
      request.headers["x-signature-timestamp"] ||
        request.headers["X-Signature-Timestamp"]

    raw_body =
      opts[:raw_body] ||
        request.metadata[:raw_body] ||
        request.metadata["raw_body"] ||
        request.raw

    with true <- is_binary(signature),
         true <- is_binary(timestamp),
         true <- is_binary(raw_body),
         {:ok, signature_bytes} <- decode_hex(signature),
         {:ok, public_key_bytes} <- decode_hex(public_key),
         true <-
           :crypto.verify(
             :eddsa,
             :none,
             timestamp <> raw_body,
             signature_bytes,
             [public_key_bytes, :ed25519]
           ) do
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

  defp transport(%{transport: transport}) when not is_nil(transport), do: transport
  defp transport(opts) when is_list(opts), do: Keyword.get(opts, :transport, NostrumClient)
  defp transport(_opts), do: NostrumClient

  defp thread_id(%Incoming{external_room_id: room_id, external_thread_id: nil}),
    do: "discord:#{room_id}"

  defp thread_id(%Incoming{external_room_id: room_id, external_thread_id: thread_id}),
    do: "discord:#{room_id}:#{thread_id}"

  defp get_map_value(map, keys) when is_map(map),
    do: Enum.find_value(keys, fn key -> Map.get(map, key) end)

  defp get_nested_id(nil), do: nil
  defp get_nested_id(author) when is_map(author), do: get_map_value(author, [:id, "id"])

  defp get_nested_username(nil), do: nil

  defp get_nested_username(author) when is_map(author),
    do: get_map_value(author, [:username, "username"])

  defp get_nested_display_name(nil), do: nil

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

  defp parse_chat_type(_), do: :unknown

  defp parse_map_chat_type(msg) when is_map(msg) do
    parse_chat_type(msg)
  end

  defp do_transform_incoming(msg) when is_map(msg) do
    route = thread_route(msg)
    chat_type = parse_map_chat_type(msg)

    {:ok,
     Incoming.new(%{
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
     })}
  end

  defp thread_route(msg) when is_map(msg) do
    channel_id = stringify(get_map_value(msg, [:channel_id, "channel_id"]))

    nested_parent_id =
      case get_map_value(msg, [:thread, "thread"]) do
        thread when is_map(thread) -> get_map_value(thread, [:parent_id, "parent_id"])
        _ -> nil
      end

    parent_id =
      stringify(get_map_value(msg, [:parent_id, "parent_id"]) || nested_parent_id)

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

  defp thread_channel_type?(type), do: type in [10, 11, 12, :thread, "thread"]

  defp extract_media(%Nostrum.Struct.Message{attachments: attachments})
       when is_list(attachments) do
    attachments
    |> Enum.map(&normalize_attachment/1)
    |> Enum.reject(&is_nil/1)
  end

  defp extract_media(msg) when is_map(msg) do
    msg
    |> get_map_value([:attachments, "attachments"])
    |> normalize_attachments()
  end

  defp normalize_attachments(attachments) when is_list(attachments) do
    attachments
    |> Enum.map(&normalize_attachment/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_attachments(_), do: []

  defp normalize_attachment(%_{} = attachment),
    do: attachment |> Map.from_struct() |> normalize_attachment()

  defp normalize_attachment(attachment) when is_map(attachment) do
    media_type = get_map_value(attachment, [:content_type, "content_type"])
    filename = get_map_value(attachment, [:filename, "filename", :name, "name"])
    url = get_map_value(attachment, [:url, "url", :proxy_url, "proxy_url"])
    kind = attachment_kind(media_type)

    %{
      kind: kind,
      url: url,
      media_type: media_type,
      filename: filename,
      size_bytes: get_map_value(attachment, [:size, "size"]),
      width: get_map_value(attachment, [:width, "width"]),
      height: get_map_value(attachment, [:height, "height"])
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp normalize_attachment(_), do: nil

  defp attachment_kind(media_type) when is_binary(media_type) do
    cond do
      String.starts_with?(media_type, "image/") -> :image
      String.starts_with?(media_type, "audio/") -> :audio
      String.starts_with?(media_type, "video/") -> :video
      true -> :file
    end
  end

  defp attachment_kind(_), do: :file

  defp normalize_channel_info(%ChannelInfo{} = info, _channel_id), do: info

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

  defp normalize_channel_info(_other, channel_id),
    do: ChannelInfo.new(%{id: to_string(channel_id)})

  defp normalize_messages(messages) when is_list(messages) do
    Enum.flat_map(messages, fn raw_message ->
      case transform_incoming(raw_message) do
        {:ok, incoming} -> [Message.from_incoming(incoming, adapter_name: :discord)]
        _ -> []
      end
    end)
  end

  defp normalize_thread_summary(channel_id, raw_thread) when is_map(raw_thread) do
    thread_id = map_get(raw_thread, [:id, "id"])

    %{
      id: "discord:#{channel_id}:#{thread_id}",
      reply_count:
        map_get(raw_thread, [:message_count, "message_count"]) ||
          map_get(raw_thread, [:member_count, "member_count"]),
      metadata: raw_thread
    }
  end

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

  defp map_get(nil, _keys), do: nil

  defp map_get(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key -> Map.get(map, key) end)
  end

  defp map_get(_other, _keys), do: nil

  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: to_string(value)

  defp pick_opts(opts, allowed_keys) when is_list(opts), do: Keyword.take(opts, allowed_keys)

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

  defp ensure_map(%{} = map), do: map
  defp ensure_map(_), do: %{}

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
       when is_atom(module) and is_atom(function) and is_list(args),
       do: {:ok, {module, function, args}}

  defp validate_sink_mfa(_), do: {:error, :invalid_sink_mfa}

  defp gateway_worker_opts(bridge_id, ingress, sink_mfa) do
    [
      bridge_id: bridge_id,
      sink_mfa: sink_mfa,
      sink_opts: [bridge_id: bridge_id],
      event_source_mfa: get_map_value(ingress, [:event_source_mfa, "event_source_mfa"]),
      poll_interval_ms: get_map_value(ingress, [:poll_interval_ms, "poll_interval_ms"]) || 250,
      max_backoff_ms: get_map_value(ingress, [:max_backoff_ms, "max_backoff_ms"]) || 5_000
    ]
  end

  defp gateway_listener_specs(bridge_id, ingress, sink_mfa) do
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
                 {GatewayWorker, gateway_worker_opts(bridge_id, ingress, sink_mfa)},
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
      source in [:nostrum, "nostrum"] ->
        :nostrum

      source in [:mfa, "mfa"] ->
        :mfa

      source in [nil, ""] and is_tuple(event_source_mfa) ->
        :mfa

      source in [nil, ""] ->
        :nostrum

      true ->
        :invalid
    end
  end

  defp nostrum_gateway_buffer_opts(bridge_id, ingress) do
    [
      bridge_id: bridge_id,
      max_events: get_map_value(ingress, [:max_events, "max_events"]) || 1_000
    ]
  end

  defp nostrum_gateway_listener_opts(bridge_id, ingress) do
    [
      bridge_id: bridge_id,
      event_names: get_map_value(ingress, [:event_names, "event_names"])
    ]
  end
end
