defmodule Jido.Chat.Discord.Channel do
  @moduledoc """
  Compatibility wrapper for legacy `Jido.Chat.Channel` integrations.

  New integrations should use `Jido.Chat.Discord.Adapter`.
  """

  @behaviour Jido.Chat.Channel

  alias Jido.Chat.Discord.Adapter

  @impl true
  defdelegate channel_type(), to: Adapter

  @impl true
  def capabilities do
    [
      :text,
      :image,
      :audio,
      :video,
      :file,
      :reactions,
      :threads,
      :typing,
      :message_edit,
      :message_delete,
      :actions,
      :slash_commands,
      :modals,
      :gateway_events,
      :interaction_ephemeral
    ]
  end

  @impl true
  defdelegate transform_incoming(payload), to: Adapter

  @impl true
  defdelegate send_message(channel_id, text, opts), to: Adapter

  @impl true
  defdelegate edit_message(channel_id, message_id, text, opts), to: Adapter

  @doc "Deletes a message when supported by Discord permissions."
  @spec delete_message(String.t() | integer(), String.t() | integer(), keyword()) ::
          :ok | {:error, term()}
  defdelegate delete_message(channel_id, message_id, opts), to: Adapter

  @doc "Sends a typing indicator."
  @spec start_typing(String.t() | integer(), keyword()) :: :ok | {:error, term()}
  defdelegate start_typing(channel_id, opts), to: Adapter

  @doc "Fetches channel metadata and normalizes to `Jido.Chat.ChannelInfo`."
  @spec fetch_metadata(String.t() | integer(), keyword()) ::
          {:ok, Jido.Chat.ChannelInfo.t()} | {:error, term()}
  defdelegate fetch_metadata(channel_id, opts), to: Adapter

  @doc "Opens a DM channel with a user."
  @spec open_dm(String.t() | integer(), keyword()) ::
          {:ok, String.t() | integer()} | {:error, term()}
  defdelegate open_dm(user_id, opts), to: Adapter

  @doc "Posts ephemeral via DM fallback when `fallback_to_dm: true`."
  @spec post_ephemeral(String.t() | integer(), String.t() | integer(), String.t(), keyword()) ::
          {:ok, Jido.Chat.EphemeralMessage.t()} | {:error, term()}
  defdelegate post_ephemeral(channel_id, user_id, text, opts), to: Adapter

  @doc "Opens a Discord interaction modal when interaction context is provided."
  @spec open_modal(String.t() | integer(), map(), keyword()) ::
          {:ok, Jido.Chat.ModalResult.t()} | {:error, term()}
  defdelegate open_modal(channel_id, payload, opts), to: Adapter

  @doc "Adds reaction to a Discord message."
  @spec add_reaction(String.t() | integer(), String.t() | integer(), String.t(), keyword()) ::
          :ok | {:error, term()}
  defdelegate add_reaction(channel_id, message_id, emoji, opts), to: Adapter

  @doc "Removes reaction from a Discord message."
  @spec remove_reaction(String.t() | integer(), String.t() | integer(), String.t(), keyword()) ::
          :ok | {:error, term()}
  defdelegate remove_reaction(channel_id, message_id, emoji, opts), to: Adapter

  @doc "Fetches Discord message history and normalizes to `Jido.Chat.MessagePage`."
  @spec fetch_messages(String.t() | integer(), keyword()) ::
          {:ok, Jido.Chat.MessagePage.t()} | {:error, term()}
  defdelegate fetch_messages(channel_id, opts), to: Adapter

  @doc "Fetches Discord channel-level history and normalizes to `Jido.Chat.MessagePage`."
  @spec fetch_channel_messages(String.t() | integer(), keyword()) ::
          {:ok, Jido.Chat.MessagePage.t()} | {:error, term()}
  defdelegate fetch_channel_messages(channel_id, opts), to: Adapter

  @doc "Lists Discord threads when supported by the transport implementation."
  @spec list_threads(String.t() | integer(), keyword()) ::
          {:ok, Jido.Chat.ThreadPage.t()} | {:error, term()}
  defdelegate list_threads(channel_id, opts), to: Adapter

  @doc "Adapter webhook helper."
  @spec handle_webhook(Jido.Chat.t(), map(), keyword()) ::
          {:ok, Jido.Chat.t(), Jido.Chat.Incoming.t()} | {:error, term()}
  defdelegate handle_webhook(chat, payload, opts), to: Adapter

  @doc "Gateway helper for forwarding Discord gateway events."
  @spec handle_gateway_event(Jido.Chat.t(), map() | {atom() | String.t(), map()}, keyword()) ::
          {:ok, Jido.Chat.t(), term()} | {:error, term()}
  defdelegate handle_gateway_event(chat, event, opts), to: Adapter
end
