defmodule Jido.Chat.Discord.Transport.NostrumClientTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.Discord.Transport.NostrumClient

  defmodule MockMessageAPI do
    def create(channel_id, opts) do
      send(self(), {:create, channel_id, opts})
      {:ok, %{id: 42, channel_id: channel_id, timestamp: ~U[2024-01-31 12:00:00.000000Z]}}
    end

    def edit(channel_id, message_id, opts) do
      send(self(), {:edit, channel_id, message_id, opts})

      {:ok,
       %{
         id: message_id,
         channel_id: channel_id,
         edited_timestamp: ~U[2024-01-31 12:01:00.000000Z]
       }}
    end

    def delete(channel_id, message_id) do
      send(self(), {:delete, channel_id, message_id})
      {:ok}
    end

    def react(channel_id, message_id, emoji) do
      send(self(), {:react, channel_id, message_id, emoji})
      {:ok}
    end

    def unreact(channel_id, message_id, emoji) do
      send(self(), {:unreact, channel_id, message_id, emoji})
      {:ok}
    end

    def get(channel_id, message_id) do
      send(self(), {:get_message, channel_id, message_id})

      {:ok,
       %{
         id: message_id,
         channel_id: channel_id,
         content: "fetched",
         guild_id: nil,
         author: %{id: 1, username: "alice", global_name: nil}
       }}
    end
  end

  defmodule MockBooleanEditAPI do
    def create(channel_id, _opts), do: {:ok, %{id: 1, channel_id: channel_id, timestamp: nil}}

    def edit(channel_id, message_id, opts) do
      send(self(), {:edit_bool, channel_id, message_id, opts})
      {:ok, true}
    end

    def delete(_channel_id, _message_id), do: {:ok}
    def react(_channel_id, _message_id, _emoji), do: {:ok}
    def unreact(_channel_id, _message_id, _emoji), do: {:ok}
    def get(_channel_id, _message_id), do: {:ok, %{}}
  end

  defmodule MockChannelAPI do
    def start_typing(channel_id) do
      send(self(), {:start_typing, channel_id})
      {:ok}
    end

    def get(channel_id) do
      send(self(), {:get_channel, channel_id})
      {:ok, %{id: channel_id, name: "general", type: 0, member_count: 10}}
    end

    def messages(channel_id, limit, locator) do
      send(self(), {:messages, channel_id, limit, locator})

      {:ok,
       [
         %{
           id: 101,
           channel_id: channel_id,
           content: "hi",
           guild_id: nil,
           author: %{id: 1, username: "alice", global_name: nil}
         },
         %{
           id: 100,
           channel_id: channel_id,
           content: "older",
           guild_id: nil,
           author: %{id: 2, username: "bob", global_name: nil}
         }
       ]}
    end

    def list_active_threads(channel_id) do
      send(self(), {:list_active_threads, channel_id})

      {:ok,
       %{
         threads: [
           %{id: 999, parent_id: channel_id, message_count: 12}
         ],
         has_more: false
       }}
    end
  end

  defmodule MockUserAPI do
    def create_dm(user_id) do
      send(self(), {:create_dm, user_id})
      {:ok, %{id: 999}}
    end
  end

  defmodule MockInteractionAPI do
    def create_response(interaction_id, interaction_token, payload) do
      send(self(), {:interaction_response, interaction_id, interaction_token, payload})
      {:ok, true}
    end
  end

  test "send_message/3 calls Nostrum API and normalizes response" do
    assert {:ok, result} =
             NostrumClient.send_message("123", "hello",
               nostrum_message_api: MockMessageAPI,
               tts: true
             )

    assert_received {:create, 123, opts}
    assert opts.content == "hello"
    assert opts.tts == true

    assert result.message_id == 42
    assert result.channel_id == 123
    assert result.timestamp == ~U[2024-01-31 12:00:00.000000Z]
  end

  test "send_message/3 forwards file attachments and omits empty content" do
    assert {:ok, _result} =
             NostrumClient.send_message("123", nil,
               nostrum_message_api: MockMessageAPI,
               file: %{name: "bytes.txt", body: "hello"}
             )

    assert_received {:create, 123, opts}
    refute Map.has_key?(opts, :content)
    assert opts.file == %{name: "bytes.txt", body: "hello"}
  end

  test "edit_message/4 calls Nostrum API and normalizes response" do
    assert {:ok, result} =
             NostrumClient.edit_message("123", "456", "updated",
               nostrum_message_api: MockMessageAPI
             )

    assert_received {:edit, 123, 456, opts}
    assert opts.content == "updated"

    assert result.message_id == 456
    assert result.channel_id == 123
    assert result.timestamp == ~U[2024-01-31 12:01:00.000000Z]
  end

  test "edit_message/4 handles boolean success response" do
    assert {:ok, result} =
             NostrumClient.edit_message(123, 456, "updated",
               nostrum_message_api: MockBooleanEditAPI
             )

    assert_received {:edit_bool, 123, 456, %{content: "updated"}}
    assert result.message_id == 456
    assert result.channel_id == 123
    assert result.timestamp == nil
  end

  test "delete/start_typing/fetch_metadata/open_dm methods work" do
    assert {:ok, true} =
             NostrumClient.delete_message("123", "456", nostrum_message_api: MockMessageAPI)

    assert_received {:delete, 123, 456}

    assert {:ok, true} = NostrumClient.start_typing("123", nostrum_channel_api: MockChannelAPI)
    assert_received {:start_typing, 123}

    assert {:ok, metadata} =
             NostrumClient.fetch_metadata("123", nostrum_channel_api: MockChannelAPI)

    assert_received {:get_channel, 123}
    assert metadata.id == 123
    assert metadata.name == "general"

    assert {:ok, 999} = NostrumClient.open_dm("42", nostrum_user_api: MockUserAPI)
    assert_received {:create_dm, 42}
  end

  test "reaction helpers call Nostrum message API" do
    assert {:ok, true} =
             NostrumClient.add_reaction("123", "456", "👍", nostrum_message_api: MockMessageAPI)

    assert_received {:react, 123, 456, "👍"}

    assert {:ok, true} =
             NostrumClient.remove_reaction(
               "123",
               "456",
               "👍",
               nostrum_message_api: MockMessageAPI
             )

    assert_received {:unreact, 123, 456, "👍"}
  end

  test "fetch_messages/2 maps cursor and normalizes page" do
    assert {:ok, result} =
             NostrumClient.fetch_messages("123",
               limit: 2,
               direction: :backward,
               cursor: "200",
               nostrum_channel_api: MockChannelAPI
             )

    assert_received {:messages, 123, 2, {:before, 200}}
    assert length(result.messages) == 2
    assert result.next_cursor == "100"

    assert {:ok, _result2} =
             NostrumClient.fetch_channel_messages("123",
               limit: 2,
               direction: :forward,
               cursor: "50",
               nostrum_channel_api: MockChannelAPI
             )

    assert_received {:messages, 123, 2, {:after, 50}}
  end

  test "list_threads/fetch_message/create_interaction_response helpers work" do
    assert {:ok, threads_result} =
             NostrumClient.list_threads("123", nostrum_channel_api: MockChannelAPI)

    assert_received {:list_active_threads, 123}
    assert [%{id: 999}] = threads_result.threads

    assert {:ok, message_result} =
             NostrumClient.fetch_message("123", "456", nostrum_message_api: MockMessageAPI)

    assert_received {:get_message, 123, 456}
    assert message_result.id == 456

    assert {:ok, true} =
             NostrumClient.create_interaction_response(
               "1",
               "token-abc",
               %{type: 4, data: %{content: "hi"}},
               nostrum_interaction_api: MockInteractionAPI
             )

    assert_received {:interaction_response, 1, "token-abc", %{type: 4, data: %{content: "hi"}}}
  end
end
