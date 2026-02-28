defmodule Jido.Chat.DiscordTest do
  use ExUnit.Case, async: true

  test "channel/0 returns the discord channel module" do
    assert Jido.Chat.Discord.channel() == Jido.Chat.Discord.Channel
  end
end
