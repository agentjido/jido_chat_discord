defmodule Jido.Chat.Discord do
  @moduledoc """
  Discord adapter package for `Jido.Chat`.

  This package uses `Nostrum` as the Discord client.
  """

  alias Jido.Chat.Discord.Adapter

  @spec adapter() :: module()
  def adapter, do: Adapter
end
