defmodule Jido.Chat.Discord.GatewayWorker do
  @moduledoc """
  Bridge-ingress worker for Discord gateway events.

  The worker is runtime-agnostic and emits normalized payloads/events through
  `sink_mfa`. Event acquisition can be push-based (`emit/2`) or pull-based
  (`event_source_mfa` polling).
  """

  use GenServer

  alias Jido.Chat.EventEnvelope

  @type sink_mfa :: {module(), atom(), [term()]}
  @type source_mfa :: {module(), atom(), [term()]}

  @type state :: %{
          bridge_id: String.t(),
          sink_mfa: sink_mfa(),
          sink_opts: keyword(),
          event_source_mfa: source_mfa() | nil,
          poll_interval_ms: pos_integer(),
          max_backoff_ms: pos_integer(),
          backoff_ms: pos_integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec emit(pid(), map() | tuple()) :: :ok
  def emit(pid, event) when is_pid(pid) do
    GenServer.cast(pid, {:emit, event})
  end

  @impl true
  def init(opts) do
    bridge_id = Keyword.fetch!(opts, :bridge_id)
    sink_mfa = Keyword.fetch!(opts, :sink_mfa)
    poll_interval_ms = normalize_pos_integer(opts[:poll_interval_ms], 250)

    state = %{
      bridge_id: bridge_id,
      sink_mfa: sink_mfa,
      sink_opts: Keyword.get(opts, :sink_opts, []),
      event_source_mfa: normalize_source_mfa(opts[:event_source_mfa]),
      poll_interval_ms: poll_interval_ms,
      max_backoff_ms: normalize_pos_integer(opts[:max_backoff_ms], 5_000),
      backoff_ms: poll_interval_ms
    }

    if state.event_source_mfa, do: send(self(), :poll)
    {:ok, state}
  end

  @impl true
  def handle_cast({:emit, event}, state) do
    _ = emit_event(state, event)
    {:noreply, state}
  end

  @impl true
  def handle_info(:poll, %{event_source_mfa: nil} = state), do: {:noreply, state}

  def handle_info(:poll, state) do
    case pull_events(state.event_source_mfa) do
      {:ok, events} when is_list(events) ->
        Enum.each(events, fn event -> _ = emit_event(state, event) end)
        schedule_poll(state.poll_interval_ms)
        {:noreply, %{state | backoff_ms: state.poll_interval_ms}}

      {:ok, _other} ->
        delay = min(state.backoff_ms, state.max_backoff_ms)
        schedule_poll(delay)

        {:noreply,
         %{state | backoff_ms: min(max(delay * 2, state.poll_interval_ms), state.max_backoff_ms)}}

      {:error, _reason} ->
        delay = min(state.backoff_ms, state.max_backoff_ms)
        schedule_poll(delay)

        {:noreply,
         %{state | backoff_ms: min(max(delay * 2, state.poll_interval_ms), state.max_backoff_ms)}}
    end
  end

  defp emit_event(state, event) do
    with {:ok, event_name, payload} <- normalize_event(event),
         {:ok, sink_payload, sink_event_opts} <- build_sink_payload(event_name, payload) do
      invoke_sink(state.sink_mfa, sink_payload, state.sink_opts ++ sink_event_opts)
    else
      :ignore -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp build_sink_payload("MESSAGE_CREATE", payload) do
    {:ok, payload, [mode: :payload, path: "/gateway/message_create", method: "GATEWAY"]}
  end

  defp build_sink_payload("MESSAGE_REACTION_ADD", payload) do
    {:ok, reaction_envelope(payload, true),
     [mode: :payload, path: "/gateway/reaction", method: "GATEWAY"]}
  end

  defp build_sink_payload("MESSAGE_REACTION_REMOVE", payload) do
    {:ok, reaction_envelope(payload, false),
     [mode: :payload, path: "/gateway/reaction", method: "GATEWAY"]}
  end

  defp build_sink_payload("INTERACTION_CREATE", payload) do
    {:ok, payload, [mode: :payload, path: "/gateway/interaction", method: "GATEWAY"]}
  end

  defp build_sink_payload("THREAD_CREATE", payload) do
    channel_id = map_get(payload, [:parent_id, "parent_id"]) || map_get(payload, [:id, "id"])

    action_payload = %{
      adapter_name: :discord,
      thread_id: "discord:#{channel_id}",
      message_id: nil,
      action_id: "thread_create",
      value: to_string(map_get(payload, [:id, "id"]) || ""),
      user: %{},
      raw: payload,
      metadata: %{channel_id: to_string(channel_id)}
    }

    envelope =
      EventEnvelope.new(%{
        adapter_name: :discord,
        event_type: :action,
        thread_id: "discord:#{channel_id}",
        channel_id: to_string(channel_id),
        message_id: nil,
        payload: action_payload,
        raw: payload,
        metadata: %{source: :gateway, gateway_event: "THREAD_CREATE"}
      })

    {:ok, envelope, [mode: :payload, path: "/gateway/thread_create", method: "GATEWAY"]}
  end

  defp build_sink_payload(_unsupported, _payload), do: :ignore

  defp reaction_envelope(payload, added) do
    channel_id = map_get(payload, [:channel_id, "channel_id"])
    message_id = map_get(payload, [:message_id, "message_id"])
    emoji = extract_emoji(payload)
    user_id = map_get(payload, [:user_id, "user_id"])

    EventEnvelope.new(%{
      adapter_name: :discord,
      event_type: :reaction,
      thread_id: "discord:#{channel_id}",
      channel_id: to_string(channel_id),
      message_id: to_string(message_id),
      payload: %{
        adapter_name: :discord,
        thread_id: "discord:#{channel_id}",
        message_id: to_string(message_id),
        emoji: emoji,
        added: added,
        user: %{user_id: to_string(user_id || "unknown")},
        raw: payload,
        metadata: %{channel_id: channel_id}
      },
      raw: payload,
      metadata: %{
        source: :gateway,
        gateway_event: if(added, do: "MESSAGE_REACTION_ADD", else: "MESSAGE_REACTION_REMOVE")
      }
    })
  end

  defp extract_emoji(payload) when is_map(payload) do
    emoji = map_get(payload, [:emoji, "emoji"]) || %{}
    map_get(emoji, [:name, "name"]) || map_get(emoji, [:id, "id"]) |> to_string_safe()
  end

  defp extract_emoji(_), do: ""

  defp normalize_event({event_name, payload}) when is_map(payload) do
    {:ok, normalize_event_name(event_name), payload}
  end

  defp normalize_event(%{} = event) do
    cond do
      is_map(Map.get(event, "d")) or is_map(Map.get(event, :d)) ->
        payload = Map.get(event, "d") || Map.get(event, :d)
        event_name = Map.get(event, "t") || Map.get(event, :t)
        {:ok, normalize_event_name(event_name), payload}

      is_map(Map.get(event, "payload")) or is_map(Map.get(event, :payload)) ->
        payload = Map.get(event, "payload") || Map.get(event, :payload)
        event_name = Map.get(event, "event") || Map.get(event, :event)
        {:ok, normalize_event_name(event_name), payload}

      true ->
        {:error, :invalid_event}
    end
  end

  defp normalize_event(_), do: {:error, :invalid_event}

  defp normalize_event_name(event_name) when is_atom(event_name),
    do: event_name |> Atom.to_string() |> String.upcase()

  defp normalize_event_name(event_name) when is_binary(event_name),
    do: String.upcase(event_name)

  defp normalize_event_name(_), do: ""

  defp invoke_sink({module, function, base_args}, payload, opts)
       when is_atom(module) and is_atom(function) and is_list(base_args) and is_list(opts) do
    apply(module, function, base_args ++ [payload, opts])
  end

  defp invoke_sink(_sink_mfa, _payload, _opts), do: {:error, :invalid_sink_mfa}

  defp pull_events({module, function, args})
       when is_atom(module) and is_atom(function) and is_list(args) do
    case apply(module, function, args) do
      {:ok, events} when is_list(events) -> {:ok, events}
      events when is_list(events) -> {:ok, events}
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_source_result, other}}
    end
  end

  defp pull_events(_), do: {:error, :invalid_event_source}

  defp schedule_poll(delay_ms) when is_integer(delay_ms) and delay_ms >= 0 do
    Process.send_after(self(), :poll, delay_ms)
  end

  defp normalize_source_mfa({module, function, args})
       when is_atom(module) and is_atom(function) and is_list(args),
       do: {module, function, args}

  defp normalize_source_mfa(_), do: nil

  defp normalize_pos_integer(value, default)
  defp normalize_pos_integer(nil, default), do: default
  defp normalize_pos_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp normalize_pos_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> default
    end
  end

  defp normalize_pos_integer(_value, default), do: default

  defp map_get(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key -> Map.get(map, key) end)
  end

  defp map_get(_other, _keys), do: nil

  defp to_string_safe(nil), do: ""
  defp to_string_safe(value) when is_binary(value), do: value
  defp to_string_safe(value), do: to_string(value)
end
