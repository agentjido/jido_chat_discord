defmodule Jido.Chat.Discord do
  @moduledoc """
  Discord adapter package for `Jido.Chat`.

  This package uses `Nostrum` as the Discord client.
  """

  alias Jido.Chat.Discord.Adapter
  alias Jido.Chat.Discord.Channel

  @spec adapter() :: module()
  def adapter, do: Adapter

  @spec channel() :: module()
  def channel, do: Channel
end
