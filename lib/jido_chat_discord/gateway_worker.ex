defmodule Jido.Chat.Discord.GatewayWorker do
  @moduledoc """
  Bridge-ingress worker for Discord gateway events.

  The worker is runtime-agnostic and emits normalized payloads/events through
  `sink_mfa`. Event acquisition can be push-based (`emit/2`) or pull-based
  (`event_source_mfa` polling).
  """

  use GenServer

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
      binding: Keyword.fetch!(opts, :binding),
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
    result = emit_event(state, event)
    {:noreply, Map.put(state, :last_result, result)}
  end

  @impl true
  def handle_info(:poll, %{event_source_mfa: nil} = state), do: {:noreply, state}

  def handle_info(:poll, state) do
    case pull_events(state.event_source_mfa) do
      {:ok, events} ->
        result = emit_event(state, events)
        schedule_poll(state.poll_interval_ms)
        {:noreply, state |> Map.put(:last_result, result) |> Map.put(:backoff_ms, state.poll_interval_ms)}

      {:error, _reason} ->
        delay = min(state.backoff_ms, state.max_backoff_ms)
        schedule_poll(delay)

        {:noreply, %{state | backoff_ms: min(max(delay * 2, state.poll_interval_ms), state.max_backoff_ms)}}
    end
  end

  defp emit_event(state, event) do
    with {:ok, delivery} <- Jido.Chat.normalize_event(state.binding, event) do
      case invoke_sink(state.sink_mfa, delivery, state.sink_opts) do
        :ok -> :ok
        {:ok, _} -> :ok
        _ -> {:error, :sink_rejected}
      end
    end
  rescue
    _ -> {:error, :sink_failed}
  catch
    _, _ -> {:error, :sink_failed}
  end

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
end
