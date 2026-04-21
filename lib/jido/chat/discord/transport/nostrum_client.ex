defmodule Jido.Chat.Discord.Transport.NostrumClient do
  @moduledoc """
  Default Discord transport backed by `Nostrum` API modules.
  """

  @behaviour Jido.Chat.Discord.Transport

  require Logger

  @impl true
  def send_message(channel_id, text, opts) do
    channel_id = to_integer(channel_id)
    message_opts = build_message_opts(text, opts)

    case message_api(opts).create(channel_id, message_opts) do
      {:ok, sent_message} ->
        raw_message = normalize_struct(sent_message)

        {:ok,
         %{
           message_id: map_get(raw_message, [:id, "id"]),
           channel_id: map_get(raw_message, [:channel_id, "channel_id"]),
           timestamp: map_get(raw_message, [:timestamp, "timestamp"]),
           attachments: map_get(raw_message, [:attachments, "attachments"]) || [],
           raw: raw_message
         }}

      {:error, reason} ->
        Logger.warning("Discord send_message failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl true
  def edit_message(channel_id, message_id, text, opts) do
    channel_id = to_integer(channel_id)
    message_id = to_integer(message_id)
    edit_opts = build_edit_opts(text, opts)

    case message_api(opts).edit(channel_id, message_id, edit_opts) do
      {:ok, edited_message} when is_map(edited_message) ->
        {:ok,
         %{
           message_id: map_get(edited_message, [:id, "id"]) || message_id,
           channel_id: map_get(edited_message, [:channel_id, "channel_id"]) || channel_id,
           timestamp:
             map_get(edited_message, [:edited_timestamp, "edited_timestamp"]) ||
               map_get(edited_message, [:timestamp, "timestamp"])
         }}

      {:ok, true} ->
        {:ok, %{message_id: message_id, channel_id: channel_id, timestamp: nil}}

      {:error, reason} ->
        Logger.warning("Discord edit_message failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl true
  def delete_message(channel_id, message_id, opts) do
    channel_id = to_integer(channel_id)
    message_id = to_integer(message_id)

    case message_api(opts).delete(channel_id, message_id) do
      {:ok} -> {:ok, true}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def start_typing(channel_id, opts) do
    channel_id = to_integer(channel_id)

    case channel_api(opts).start_typing(channel_id) do
      {:ok} -> {:ok, true}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def fetch_metadata(channel_id, opts) do
    channel_id = to_integer(channel_id)

    case channel_api(opts).get(channel_id) do
      {:ok, channel} ->
        {:ok,
         %{
           id: map_get(channel, [:id, "id"]) || channel_id,
           name: map_get(channel, [:name, "name"]),
           type: map_get(channel, [:type, "type"]),
           member_count: map_get(channel, [:member_count, "member_count"]),
           raw: normalize_struct(channel)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def open_dm(user_id, opts) do
    user_id = to_integer(user_id)

    case user_api(opts).create_dm(user_id) do
      {:ok, channel} ->
        {:ok, map_get(channel, [:id, "id"]) || user_id}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def add_reaction(channel_id, message_id, emoji, opts) do
    channel_id = to_integer(channel_id)
    message_id = to_integer(message_id)

    case message_api(opts).react(channel_id, message_id, emoji) do
      {:ok} -> {:ok, true}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def remove_reaction(channel_id, message_id, emoji, opts) do
    channel_id = to_integer(channel_id)
    message_id = to_integer(message_id)

    case message_api(opts).unreact(channel_id, message_id, emoji) do
      {:ok} -> {:ok, true}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def fetch_messages(channel_id, opts) do
    channel_id = to_integer(channel_id)
    limit = opts[:limit] || 50
    direction = opts[:direction] || :backward
    locator = build_locator(opts[:cursor], direction)

    case channel_api(opts).messages(channel_id, limit, locator) do
      {:ok, messages} when is_list(messages) ->
        {:ok,
         %{
           messages: Enum.map(messages, &normalize_struct/1),
           next_cursor: next_cursor(messages, limit),
           direction: direction
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def fetch_channel_messages(channel_id, opts), do: fetch_messages(channel_id, opts)

  @impl true
  def list_threads(channel_id, opts) do
    channel_id = to_integer(channel_id)
    api = channel_api(opts)

    cond do
      function_exported?(api, :list_active_threads, 1) ->
        case apply(api, :list_active_threads, [channel_id]) do
          {:ok, result} -> {:ok, normalize_threads_result(result)}
          {:error, reason} -> {:error, reason}
        end

      function_exported?(api, :active_threads, 1) ->
        case apply(api, :active_threads, [channel_id]) do
          {:ok, result} -> {:ok, normalize_threads_result(result)}
          {:error, reason} -> {:error, reason}
        end

      function_exported?(api, :archived_public_threads, 2) ->
        case apply(api, :archived_public_threads, [channel_id, []]) do
          {:ok, result} -> {:ok, normalize_threads_result(result)}
          {:error, reason} -> {:error, reason}
        end

      true ->
        {:error, :unsupported}
    end
  end

  @impl true
  def open_thread(channel_id, message_id, opts) do
    channel_id = to_integer(channel_id)
    message_id = to_integer(message_id)
    name = Keyword.get(opts, :name, Keyword.get(opts, :topic_name, "Thread"))
    api = channel_api(opts)

    cond do
      function_exported?(api, :start_thread_with_message, 4) ->
        case apply(api, :start_thread_with_message, [channel_id, message_id, name, []]) do
          {:ok, thread} -> {:ok, normalize_thread_open_result(thread)}
          {:error, reason} -> {:error, reason}
        end

      function_exported?(api, :start_thread_from_message, 4) ->
        case apply(api, :start_thread_from_message, [channel_id, message_id, name, []]) do
          {:ok, thread} -> {:ok, normalize_thread_open_result(thread)}
          {:error, reason} -> {:error, reason}
        end

      function_exported?(api, :create_message_thread, 4) ->
        case apply(api, :create_message_thread, [channel_id, message_id, name, []]) do
          {:ok, thread} -> {:ok, normalize_thread_open_result(thread)}
          {:error, reason} -> {:error, reason}
        end

      true ->
        {:error, :unsupported}
    end
  end

  @impl true
  def fetch_message(channel_id, message_id, opts) do
    channel_id = to_integer(channel_id)
    message_id = to_integer(message_id)
    api = message_api(opts)

    cond do
      function_exported?(api, :get, 2) ->
        case apply(api, :get, [channel_id, message_id]) do
          {:ok, message} -> {:ok, normalize_struct(message)}
          {:error, reason} -> {:error, reason}
        end

      true ->
        {:error, :unsupported}
    end
  end

  @impl true
  def fetch_thread(channel_id, opts) do
    fetch_metadata(channel_id, opts)
  end

  @impl true
  def create_interaction_response(interaction_id, interaction_token, payload, opts) do
    interaction_id = to_integer(interaction_id)
    api = interaction_api(opts)

    cond do
      function_exported?(api, :create_response, 3) ->
        apply(api, :create_response, [interaction_id, interaction_token, payload])

      true ->
        {:error, :unsupported}
    end
  end

  defp message_api(opts), do: Keyword.get(opts, :nostrum_message_api, Nostrum.Api.Message)
  defp channel_api(opts), do: Keyword.get(opts, :nostrum_channel_api, Nostrum.Api.Channel)
  defp user_api(opts), do: Keyword.get(opts, :nostrum_user_api, Nostrum.Api.User)

  defp interaction_api(opts),
    do: Keyword.get(opts, :nostrum_interaction_api, Nostrum.Api.Interaction)

  defp build_message_opts(text, opts) do
    %{}
    |> maybe_add_content(text)
    |> maybe_add_opt(:embeds, opts)
    |> maybe_add_opt(:components, opts)
    |> maybe_add_opt(:tts, opts)
    |> maybe_add_opt(:allowed_mentions, opts)
    |> maybe_add_opt(:message_reference, opts)
    |> maybe_add_opt(:file, opts)
    |> maybe_add_opt(:files, opts)
  end

  defp build_edit_opts(text, opts) do
    %{content: text}
    |> maybe_add_opt(:embeds, opts)
    |> maybe_add_opt(:components, opts)
    |> maybe_add_opt(:allowed_mentions, opts)
  end

  defp maybe_add_opt(map, key, opts) do
    case Keyword.get(opts, key) do
      nil -> map
      value -> Map.put(map, key, value)
    end
  end

  defp maybe_add_content(map, nil), do: map
  defp maybe_add_content(map, ""), do: map
  defp maybe_add_content(map, text), do: Map.put(map, :content, text)

  defp build_locator(nil, _direction), do: {}

  defp build_locator(cursor, :forward), do: {:after, to_integer(cursor)}
  defp build_locator(cursor, _direction), do: {:before, to_integer(cursor)}

  defp next_cursor(messages, limit) when is_list(messages) and is_integer(limit) do
    if length(messages) < limit do
      nil
    else
      messages
      |> List.last()
      |> map_get([:id, "id"])
      |> maybe_to_string()
    end
  end

  defp normalize_thread_open_result(thread) do
    %{
      external_thread_id: maybe_to_string(map_get(thread, [:id, "id"])),
      delivery_external_room_id: maybe_to_string(map_get(thread, [:id, "id"])),
      parent_id: maybe_to_string(map_get(thread, [:parent_id, "parent_id"])),
      name: map_get(thread, [:name, "name"])
    }
  end

  defp to_integer(value) when is_integer(value), do: value

  defp to_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> raise ArgumentError, "invalid snowflake #{inspect(value)}"
    end
  end

  defp map_get(nil, _keys), do: nil

  defp map_get(map, keys) when is_list(keys) do
    map = normalize_struct(map)
    Enum.find_value(keys, fn key -> Map.get(map, key) end)
  end

  defp normalize_struct(%_{} = struct), do: Map.from_struct(struct)
  defp normalize_struct(map) when is_map(map), do: map
  defp normalize_struct(other), do: other

  defp maybe_to_string(nil), do: nil
  defp maybe_to_string(value) when is_binary(value), do: value
  defp maybe_to_string(value), do: to_string(value)

  defp normalize_threads_result(%{} = result) do
    threads = map_get(result, [:threads, "threads"]) || []

    %{
      threads: Enum.map(threads, &normalize_struct/1),
      next_cursor:
        if(map_get(result, [:has_more, "has_more"])) do
          threads |> List.last() |> map_get([:id, "id"]) |> maybe_to_string()
        else
          nil
        end,
      metadata: %{raw: normalize_struct(result)}
    }
  end

  defp normalize_threads_result(threads) when is_list(threads) do
    %{threads: Enum.map(threads, &normalize_struct/1), next_cursor: nil, metadata: %{}}
  end
end
