defmodule Jido.Chat.Discord.GatewayWorkerTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.EventEnvelope
  alias Jido.Chat.Discord.{Adapter, GatewayWorker}

  defmodule Sink do
    def emit(test_pid, payload, opts) do
      send(test_pid, {:sink_emit, payload, opts})
      {:ok, :accepted}
    end
  end

  defmodule Source do
    def pop(agent) do
      Agent.get_and_update(agent, fn
        [next | rest] -> {next, rest}
        [] -> {[], []}
      end)
    end
  end

  test "adapter listener_child_specs/2 returns expected webhook/gateway specs" do
    assert {:ok, []} = Adapter.listener_child_specs("bridge_discord", ingress: %{mode: "webhook"})

    assert {:error, :invalid_sink_mfa} =
             Adapter.listener_child_specs("bridge_discord", ingress: %{mode: "gateway"})

    assert {:ok, specs} =
             Adapter.listener_child_specs("bridge_discord",
               ingress: %{mode: "gateway"},
               sink_mfa: {Sink, :emit, [self()]}
             )

    assert Enum.map(specs, & &1.id) == [
             {:discord_gateway_buffer, "bridge_discord"},
             {:discord_gateway_listener, "bridge_discord"},
             {:discord_gateway_worker, "bridge_discord"}
           ]

    assert {:ok, [spec]} =
             Adapter.listener_child_specs("bridge_discord",
               ingress: %{
                 mode: "gateway",
                 source: "mfa",
                 event_source_mfa: {Source, :pop, [self()]}
               },
               sink_mfa: {Sink, :emit, [self()]}
             )

    assert spec.id == {:discord_gateway_worker, "bridge_discord"}

    assert {:error, :invalid_event_source_mfa} =
             Adapter.listener_child_specs("bridge_discord",
               ingress: %{mode: "gateway", source: "mfa"},
               sink_mfa: {Sink, :emit, [self()]}
             )
  end

  test "gateway worker emits message create payload through sink" do
    {:ok, pid} =
      start_supervised({GatewayWorker, bridge_id: "bridge_discord", sink_mfa: {Sink, :emit, [self()]}, sink_opts: []})

    event = %{
      event: "MESSAGE_CREATE",
      payload: %{
        "id" => "msg-1",
        "channel_id" => "channel-1",
        "content" => "hello",
        "author" => %{"id" => "user-1"}
      }
    }

    :ok = GatewayWorker.emit(pid, event)

    assert_receive {:sink_emit, %{"id" => "msg-1", "channel_id" => "channel-1"}, opts}, 200
    assert opts[:mode] == :payload
  end

  test "gateway worker normalizes reaction dispatch payload into EventEnvelope" do
    {:ok, pid} =
      start_supervised({GatewayWorker, bridge_id: "bridge_discord", sink_mfa: {Sink, :emit, [self()]}, sink_opts: []})

    :ok =
      GatewayWorker.emit(pid, %{
        "t" => "MESSAGE_REACTION_ADD",
        "d" => %{
          "channel_id" => "channel-1",
          "message_id" => "msg-1",
          "user_id" => "user-1",
          "emoji" => %{"name" => "👍"}
        }
      })

    assert_receive {:sink_emit, %EventEnvelope{} = envelope, opts}, 200
    assert envelope.event_type == :reaction
    assert envelope.channel_id == "channel-1"
    assert opts[:mode] == :payload
  end

  test "gateway worker polls event source and emits events through sink" do
    {:ok, agent} =
      Agent.start_link(fn ->
        [
          [
            %{
              "t" => "MESSAGE_CREATE",
              "d" => %{"id" => "m1", "channel_id" => "c1", "content" => "from-source"}
            }
          ],
          []
        ]
      end)

    {:ok, _pid} =
      start_supervised(
        {GatewayWorker,
         bridge_id: "bridge_discord",
         sink_mfa: {Sink, :emit, [self()]},
         event_source_mfa: {Source, :pop, [agent]},
         poll_interval_ms: 10}
      )

    assert_receive {:sink_emit, %{"id" => "m1", "channel_id" => "c1"}, opts}, 300
    assert opts[:mode] == :payload
  end
end
