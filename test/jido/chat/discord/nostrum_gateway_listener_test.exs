defmodule Jido.Chat.Discord.NostrumGatewayListenerTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.Discord.{NostrumGatewayBuffer, NostrumGatewayListener}

  defmodule PayloadStruct do
    defstruct [:id, :nested]
  end

  test "listener joins consumer group and forwards supported events into bridge buffer" do
    bridge_id = "bridge_listener_forward"
    test_pid = self()

    start_supervised!({NostrumGatewayBuffer, bridge_id: bridge_id})

    join_fun = fn pid ->
      send(test_pid, {:joined_consumer_group, pid})
      :ok
    end

    listener_pid =
      start_supervised!({NostrumGatewayListener, bridge_id: bridge_id, join_fun: join_fun})

    assert_receive {:joined_consumer_group, ^listener_pid}, 200

    send(
      listener_pid,
      {:event,
       {:MESSAGE_CREATE, %PayloadStruct{id: "msg-1", nested: %PayloadStruct{id: "n1"}}, %{}}}
    )

    assert [{"MESSAGE_CREATE", payload}] = await_buffer_events(bridge_id)
    assert payload.id == "msg-1"
    assert payload.nested.id == "n1"
    refute Map.has_key?(payload, :__struct__)
    refute Map.has_key?(payload.nested, :__struct__)
  end

  test "listener ignores unsupported event names" do
    bridge_id = "bridge_listener_ignore"

    start_supervised!({NostrumGatewayBuffer, bridge_id: bridge_id})

    start_supervised!(
      {NostrumGatewayListener, bridge_id: bridge_id, join_fun: fn _pid -> :ok end}
    )

    listener_pid = NostrumGatewayListener.whereis(bridge_id)
    send(listener_pid, {:event, {:GUILD_CREATE, %{id: "guild-1"}, %{}}})

    assert [] == NostrumGatewayBuffer.pop_events(bridge_id)
  end

  test "buffer enforces max_events limit" do
    bridge_id = "bridge_listener_limit"
    start_supervised!({NostrumGatewayBuffer, bridge_id: bridge_id, max_events: 2})

    :ok = NostrumGatewayBuffer.push_event(bridge_id, {"MESSAGE_CREATE", %{id: "1"}})
    :ok = NostrumGatewayBuffer.push_event(bridge_id, {"MESSAGE_CREATE", %{id: "2"}})
    :ok = NostrumGatewayBuffer.push_event(bridge_id, {"MESSAGE_CREATE", %{id: "3"}})

    assert [
             {"MESSAGE_CREATE", %{id: "2"}},
             {"MESSAGE_CREATE", %{id: "3"}}
           ] = NostrumGatewayBuffer.pop_events(bridge_id, 10)
  end

  defp await_buffer_events(bridge_id, timeout_ms \\ 300) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_buffer_events(bridge_id, deadline)
  end

  defp do_await_buffer_events(bridge_id, deadline) do
    case NostrumGatewayBuffer.pop_events(bridge_id, 10) do
      [] ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(10)
          do_await_buffer_events(bridge_id, deadline)
        else
          []
        end

      events ->
        events
    end
  end
end
