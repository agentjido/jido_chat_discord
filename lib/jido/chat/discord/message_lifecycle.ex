defmodule Jido.Chat.Discord.MessageLifecycle do
  @moduledoc false

  alias Jido.Chat.{Author, EventEnvelope, MessageDeletedEvent, MessageUpdatedEvent}

  @spec envelope(:message_updated | :message_deleted, map()) ::
          {:ok, EventEnvelope.t()}
          | {:error, {:invalid_message_lifecycle_payload, [atom()]}}
  def envelope(event_type, payload)

  def envelope(:message_updated, payload) when is_map(payload) do
    with {:ok, attrs} <- common_attrs(payload) do
      author = author(payload)
      timestamp = timestamp(payload)

      lifecycle_event =
        attrs
        |> Map.put(:author, author)
        |> Map.put(:timestamp, timestamp)
        |> Map.put(:message, updated_message(payload, attrs, author, timestamp))
        |> MessageUpdatedEvent.new()

      {:ok, build_envelope(:message_updated, payload, lifecycle_event)}
    end
  end

  def envelope(:message_deleted, payload) when is_map(payload) do
    with {:ok, attrs} <- common_attrs(payload) do
      {:ok, build_envelope(:message_deleted, payload, MessageDeletedEvent.new(attrs))}
    end
  end

  def envelope(_event_type, _payload),
    do: {:error, {:invalid_message_lifecycle_payload, [:payload]}}

  defp build_envelope(event_type, payload, lifecycle_event) do
    EventEnvelope.new(%{
      adapter_name: :discord,
      event_type: event_type,
      thread_id: lifecycle_event.thread_id,
      channel_id: lifecycle_event.channel_id,
      message_id: lifecycle_event.message_id,
      payload: lifecycle_event,
      raw: payload,
      metadata: %{source: :gateway, gateway_event: gateway_event_name(event_type)}
    })
  end

  defp common_attrs(payload) do
    channel_id = payload |> map_get([:channel_id, "channel_id"]) |> stringify()
    message_id = payload |> map_get([:id, "id", :message_id, "message_id"]) |> stringify()

    case missing_ids(channel_id, message_id) do
      [] ->
        {:ok,
         %{
           adapter_name: :discord,
           thread_id: "discord:#{channel_id}",
           channel_id: channel_id,
           message_id: message_id,
           raw: payload
         }}

      missing ->
        {:error, {:invalid_message_lifecycle_payload, missing}}
    end
  end

  defp updated_message(payload, attrs, author, timestamp) do
    case fetch(payload, [:content, "content"]) do
      {:ok, nil} ->
        nil

      {:ok, content} ->
        %{
          id: attrs.message_id,
          external_message_id: attrs.message_id,
          thread_id: attrs.thread_id,
          channel_id: attrs.channel_id,
          external_room_id: attrs.channel_id,
          text: content,
          formatted: content,
          author: author,
          updated_at: timestamp,
          raw: payload
        }

      :error ->
        nil
    end
  end

  defp author(payload) do
    case map_get(payload, [:author, "author"]) do
      author when is_map(author) ->
        user_id = author |> map_get([:id, "id", :user_id, "user_id"]) |> stringify()

        if user_id do
          Author.new(%{
            user_id: user_id,
            user_name: map_get(author, [:username, "username", :user_name, "user_name"]) || user_id,
            full_name: map_get(author, [:global_name, "global_name", :name, "name"]),
            is_bot: map_get(author, [:bot, "bot", :is_bot, "is_bot"]) || false,
            metadata: %{raw: author}
          })
        end

      _ ->
        nil
    end
  end

  defp fetch(map, keys) do
    Enum.find_value(keys, :error, fn key ->
      if Map.has_key?(map, key), do: {:ok, Map.get(map, key)}
    end)
  end

  defp map_get(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key -> Map.get(map, key) end)
  end

  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_integer(value), do: Integer.to_string(value)
  defp stringify(_value), do: nil

  defp timestamp(payload),
    do: map_get(payload, [:edited_timestamp, "edited_timestamp", :timestamp, "timestamp"])

  defp missing_ids(channel_id, message_id) do
    []
    |> maybe_add_missing(:channel_id, channel_id)
    |> maybe_add_missing(:message_id, message_id)
  end

  defp maybe_add_missing(missing, field, value) when value in [nil, ""], do: missing ++ [field]
  defp maybe_add_missing(missing, _field, _value), do: missing

  defp gateway_event_name(:message_updated), do: "MESSAGE_UPDATE"
  defp gateway_event_name(:message_deleted), do: "MESSAGE_DELETE"
end
