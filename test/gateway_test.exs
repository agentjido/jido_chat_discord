defmodule Jido.Chat.Discord.GatewayTest do
  use ExUnit.Case, async: true

  test "Mint connection can be closed before the remote socket opens" do
    alias Jido.Chat.Discord.Gateway
    Process.flag(:trap_exit, true)
    assert {:ok, pid} = Gateway.open("wss://127.0.0.1:9", [])
    ref = Process.monitor(pid)
    assert :ok = Gateway.close(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
  end
end
