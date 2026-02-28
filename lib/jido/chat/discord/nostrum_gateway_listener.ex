defmodule Jido.Chat.Discord.NostrumGatewayListener do
  @moduledoc """
  Bridge-scoped subscriber for `Nostrum.ConsumerGroup` gateway events.

  Selected events are normalized and pushed into `NostrumGatewayBuffer`, where
  `Jido.Chat.Discord.GatewayWorker` can consume them through `event_source_mfa`.
  """

  use GenServer

  alias Jido.Chat.Discord.NostrumGatewayBuffer

  @default_event_names [
    "MESSAGE_CREATE",
    "MESSAGE_REACTION_ADD",
    "MESSAGE_REACTION_REMOVE",
    "INTERACTION_CREATE",
    "THREAD_CREATE"
  ]

  @type state :: %{
          bridge_id: String.t(),
          join_fun: (pid() -> :ok | term()),
          event_names: MapSet.t(String.t())
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    bridge_id = Keyword.fetch!(opts, :bridge_id)
    name = Keyword.get(opts, :name, {:global, via_name(bridge_id)})
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec whereis(String.t()) :: pid() | nil
  def whereis(bridge_id) when is_binary(bridge_id) do
    :global.whereis_name(via_name(bridge_id))
  end

  @impl true
  def init(opts) do
    bridge_id = Keyword.fetch!(opts, :bridge_id)
    join_fun = Keyword.get(opts, :join_fun, &Nostrum.ConsumerGroup.join/1)
    event_names = normalize_event_names(Keyword.get(opts, :event_names))

    case safe_join(join_fun, self()) do
      :ok ->
        {:ok, %{bridge_id: bridge_id, join_fun: join_fun, event_names: event_names}}

      {:error, reason} ->
        {:stop, reason}

      other ->
        {:stop, {:invalid_join_result, other}}
    end
  end

  @impl true
  def handle_info({:event, event}, state) do
    case normalize_gateway_event(event, state.event_names) do
      {:ok, formatted_event} ->
        NostrumGatewayBuffer.push_event(state.bridge_id, formatted_event)

      :ignore ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp normalize_gateway_event({event_name, payload, _ws_state}, allowed_event_names)
       when is_map(payload) do
    normalize_gateway_event({event_name, payload}, allowed_event_names)
  end

  defp normalize_gateway_event({event_name, payload}, allowed_event_names) when is_map(payload) do
    event_name = event_name |> normalize_event_name() |> to_string()

    if MapSet.member?(allowed_event_names, event_name) do
      {:ok, {event_name, normalize_payload(payload)}}
    else
      :ignore
    end
  end

  defp normalize_gateway_event(_event, _allowed_event_names), do: :ignore

  defp normalize_event_names(nil), do: MapSet.new(@default_event_names)

  defp normalize_event_names(event_names) when is_list(event_names) do
    event_names
    |> Enum.map(&normalize_event_name/1)
    |> Enum.filter(&(&1 != ""))
    |> then(fn
      [] -> @default_event_names
      names -> names
    end)
    |> MapSet.new()
  end

  defp normalize_event_names(_other), do: MapSet.new(@default_event_names)

  defp normalize_event_name(name) when is_atom(name),
    do: name |> Atom.to_string() |> String.upcase()

  defp normalize_event_name(name) when is_binary(name), do: String.upcase(name)
  defp normalize_event_name(_), do: ""

  defp normalize_payload(%_{} = struct), do: struct |> Map.from_struct() |> normalize_payload()

  defp normalize_payload(payload) when is_map(payload) do
    Map.new(payload, fn {key, value} -> {key, normalize_payload(value)} end)
  end

  defp normalize_payload(payload) when is_list(payload),
    do: Enum.map(payload, &normalize_payload/1)

  defp normalize_payload(other), do: other

  defp safe_join(join_fun, pid) do
    join_fun.(pid)
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp via_name(bridge_id), do: {__MODULE__, bridge_id}
end
