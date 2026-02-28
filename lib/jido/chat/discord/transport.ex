defmodule Jido.Chat.Discord.Transport do
  @moduledoc """
  Transport contract for Discord API operations.
  """

  @type api_result :: {:ok, map() | boolean()} | {:error, term()}

  @callback send_message(
              channel_id :: String.t() | integer(),
              text :: String.t(),
              opts :: keyword()
            ) :: api_result()

  @callback edit_message(
              channel_id :: String.t() | integer(),
              message_id :: String.t() | integer(),
              text :: String.t(),
              opts :: keyword()
            ) :: api_result()

  @callback delete_message(
              channel_id :: String.t() | integer(),
              message_id :: String.t() | integer(),
              opts :: keyword()
            ) :: api_result()

  @callback start_typing(channel_id :: String.t() | integer(), opts :: keyword()) :: api_result()

  @callback fetch_metadata(channel_id :: String.t() | integer(), opts :: keyword()) ::
              api_result()

  @callback open_dm(user_id :: String.t() | integer(), opts :: keyword()) ::
              {:ok, String.t() | integer()} | {:error, term()}

  @callback add_reaction(
              channel_id :: String.t() | integer(),
              message_id :: String.t() | integer(),
              emoji :: String.t(),
              opts :: keyword()
            ) :: api_result()

  @callback remove_reaction(
              channel_id :: String.t() | integer(),
              message_id :: String.t() | integer(),
              emoji :: String.t(),
              opts :: keyword()
            ) :: api_result()

  @callback fetch_messages(channel_id :: String.t() | integer(), opts :: keyword()) ::
              api_result()

  @callback fetch_channel_messages(channel_id :: String.t() | integer(), opts :: keyword()) ::
              api_result()

  @callback list_threads(channel_id :: String.t() | integer(), opts :: keyword()) ::
              api_result()

  @callback fetch_message(
              channel_id :: String.t() | integer(),
              message_id :: String.t() | integer(),
              opts :: keyword()
            ) :: api_result()

  @callback fetch_thread(channel_id :: String.t() | integer(), opts :: keyword()) :: api_result()

  @callback create_interaction_response(
              interaction_id :: String.t() | integer(),
              interaction_token :: String.t(),
              payload :: map(),
              opts :: keyword()
            ) :: api_result()
end
