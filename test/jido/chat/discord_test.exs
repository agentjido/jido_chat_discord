defmodule Jido.Chat.DiscordTest do
  use ExUnit.Case, async: true

  test "adapter/0 returns the discord adapter module" do
    assert Jido.Chat.Discord.adapter() == Jido.Chat.Discord.Adapter
  end
end
