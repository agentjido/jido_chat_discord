defmodule Jido.Chat.Discord.NostrumGatewayBuffer do
  @moduledoc """
  In-memory event buffer used by Discord gateway listener integrations.

  This buffer is bridge-scoped and can be used as a pull source via
  `pop_events/2` for `Jido.Chat.Discord.GatewayWorker`.
  """

  use GenServer

  @type state :: %{
          bridge_id: String.t(),
          queue: :queue.queue(term()),
          queue_size: non_neg_integer(),
          max_events: pos_integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    bridge_id = Keyword.fetch!(opts, :bridge_id)
    name = Keyword.get(opts, :name, {:global, via_name(bridge_id)})
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec push_event(String.t(), term()) :: :ok
  def push_event(bridge_id, event) when is_binary(bridge_id) do
    GenServer.cast(server_name(bridge_id), {:push, event})
  end

  @spec pop_events(String.t(), pos_integer()) :: [term()]
  def pop_events(bridge_id, max_count \\ 100)
      when is_binary(bridge_id) and is_integer(max_count) and max_count > 0 do
    GenServer.call(server_name(bridge_id), {:pop, max_count})
  end

  @spec whereis(String.t()) :: pid() | nil
  def whereis(bridge_id) when is_binary(bridge_id) do
    :global.whereis_name(via_name(bridge_id))
  end

  @impl true
  def init(opts) do
    state = %{
      bridge_id: Keyword.fetch!(opts, :bridge_id),
      queue: :queue.new(),
      queue_size: 0,
      max_events: normalize_max_events(opts[:max_events])
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:push, event}, state) do
    {queue, queue_size} =
      :queue.in(event, state.queue)
      |> trim_queue(state.queue_size + 1, state.max_events)

    {:noreply, %{state | queue: queue, queue_size: queue_size}}
  end

  @impl true
  def handle_call({:pop, max_count}, _from, state) do
    {events, queue, queue_size} = pop_many(state.queue, state.queue_size, max_count, [])
    {:reply, Enum.reverse(events), %{state | queue: queue, queue_size: queue_size}}
  end

  defp pop_many(queue, queue_size, 0, acc), do: {acc, queue, queue_size}

  defp pop_many(queue, queue_size, remaining, acc) do
    case :queue.out(queue) do
      {{:value, event}, rest} ->
        pop_many(rest, max(queue_size - 1, 0), remaining - 1, [event | acc])

      {:empty, _queue} ->
        {acc, queue, queue_size}
    end
  end

  defp trim_queue(queue, queue_size, max_events) when queue_size <= max_events,
    do: {queue, queue_size}

  defp trim_queue(queue, queue_size, max_events) do
    case :queue.out(queue) do
      {{:value, _dropped}, rest} ->
        trim_queue(rest, queue_size - 1, max_events)

      {:empty, _} ->
        {:queue.new(), 0}
    end
  end

  defp normalize_max_events(value) when is_integer(value) and value > 0, do: value

  defp normalize_max_events(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> 1_000
    end
  end

  defp normalize_max_events(_), do: 1_000

  defp server_name(bridge_id), do: {:global, via_name(bridge_id)}
  defp via_name(bridge_id), do: {__MODULE__, bridge_id}
end
