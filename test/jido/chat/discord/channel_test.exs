defmodule Jido.Chat.Discord.ChannelTest do
  use ExUnit.Case, async: true

  alias Jido.Chat
  alias Jido.Chat.Discord.Channel

  defmodule MockTransport do
    @behaviour Jido.Chat.Discord.Transport

    @impl true
    def send_message(channel_id, text, _opts) do
      send(self(), {:send_message, channel_id, text})
      {:ok, %{message_id: 42, channel_id: channel_id, timestamp: ~U[2024-01-31 12:00:00.000000Z]}}
    end

    @impl true
    def edit_message(channel_id, message_id, text, _opts) do
      send(self(), {:edit_message, channel_id, message_id, text})

      {:ok,
       %{
         message_id: message_id,
         channel_id: channel_id,
         timestamp: ~U[2024-01-31 12:01:00.000000Z]
       }}
    end

    @impl true
    def delete_message(channel_id, message_id, _opts) do
      send(self(), {:delete_message, channel_id, message_id})
      {:ok, true}
    end

    @impl true
    def start_typing(channel_id, opts) do
      send(self(), {:start_typing, channel_id, opts})
      {:ok, true}
    end

    @impl true
    def fetch_metadata(channel_id, _opts) do
      send(self(), {:fetch_metadata, channel_id})
      {:ok, %{id: channel_id, name: "general", type: 0, member_count: 10}}
    end

    @impl true
    def open_dm(user_id, _opts) do
      send(self(), {:open_dm, user_id})
      {:ok, "dm-#{user_id}"}
    end

    @impl true
    def add_reaction(channel_id, message_id, emoji, _opts) do
      send(self(), {:add_reaction, channel_id, message_id, emoji})
      {:ok, true}
    end

    @impl true
    def remove_reaction(channel_id, message_id, emoji, _opts) do
      send(self(), {:remove_reaction, channel_id, message_id, emoji})
      {:ok, true}
    end

    @impl true
    def fetch_messages(channel_id, _opts) do
      send(self(), {:fetch_messages, channel_id})

      {:ok,
       %{
         messages: [
           %{
             id: "111",
             channel_id: channel_id,
             content: "history",
             guild_id: nil,
             author: %{id: "444", username: "user", global_name: nil}
           }
         ],
         next_cursor: nil
       }}
    end

    @impl true
    def fetch_channel_messages(channel_id, opts), do: fetch_messages(channel_id, opts)

    @impl true
    def list_threads(channel_id, _opts) do
      send(self(), {:list_threads, channel_id})

      {:ok,
       %{
         threads: [
           %{id: "thread-1", parent_id: channel_id, message_count: 3}
         ],
         next_cursor: nil
       }}
    end

    @impl true
    def fetch_message(channel_id, message_id, _opts) do
      send(self(), {:fetch_message, channel_id, message_id})

      {:ok,
       %{
         id: message_id,
         channel_id: channel_id,
         content: "single",
         guild_id: nil,
         author: %{id: "444", username: "user", global_name: nil}
       }}
    end

    @impl true
    def fetch_thread(channel_id, _opts) do
      send(self(), {:fetch_thread, channel_id})
      {:ok, %{id: channel_id, name: "thread-name", type: 11}}
    end

    @impl true
    def create_interaction_response(interaction_id, interaction_token, payload, _opts) do
      send(self(), {:interaction_response, interaction_id, interaction_token, payload})
      {:ok, true}
    end
  end

  test "channel metadata" do
    assert Channel.channel_type() == :discord
    assert :text in Channel.capabilities()
    assert :message_edit in Channel.capabilities()
    assert :threads in Channel.capabilities()
    assert :message_delete in Channel.capabilities()
  end

  test "adapter capabilities matrix declares native/fallback/unsupported surfaces" do
    caps = Jido.Chat.Discord.Adapter.capabilities()

    assert caps.send_message == :native
    assert caps.edit_message == :native
    assert caps.list_threads == :native
    assert caps.stream == :fallback
    assert caps.open_modal == :native

    assert :ok = Jido.Chat.Adapter.validate_capabilities(Jido.Chat.Discord.Adapter)
  end

  test "transform_incoming/1 with atom map" do
    msg = %{
      id: 111,
      channel_id: 222,
      content: "Hello",
      timestamp: ~U[2024-01-31 12:00:00.000000Z],
      guild_id: 333,
      author: %{id: 444, username: "user", global_name: "User"}
    }

    assert {:ok, incoming} = Channel.transform_incoming(msg)
    assert incoming.external_room_id == 222
    assert incoming.external_user_id == 444
    assert incoming.text == "Hello"
    assert incoming.chat_type == :guild
    assert incoming.channel_meta.adapter_name == :discord
    assert incoming.channel_meta.external_room_id == 222
    assert incoming.channel_meta.is_dm == false
  end

  test "transform_incoming/1 with string map" do
    msg = %{
      "id" => 111,
      "channel_id" => 222,
      "content" => "Hello",
      "timestamp" => ~U[2024-01-31 12:00:00.000000Z],
      "guild_id" => nil,
      "author" => %{"id" => 444, "username" => "user", "global_name" => nil}
    }

    assert {:ok, incoming} = Channel.transform_incoming(msg)
    assert incoming.external_room_id == 222
    assert incoming.external_user_id == 444
    assert incoming.display_name == "user"
    assert incoming.chat_type == :dm
    assert incoming.channel_meta.adapter_name == :discord
    assert incoming.channel_meta.external_room_id == 222
    assert incoming.channel_meta.is_dm == true
  end

  test "transform_incoming/1 extracts attachments" do
    msg = %{
      id: 1,
      channel_id: 2,
      content: nil,
      guild_id: 3,
      author: %{id: 4, username: "u", global_name: "U"},
      attachments: [
        %{
          id: 9,
          url: "https://cdn.discordapp.com/file.png",
          filename: "file.png",
          content_type: "image/png",
          size: 256,
          width: 128,
          height: 128
        }
      ]
    }

    assert {:ok, incoming} = Channel.transform_incoming(msg)

    assert [%{kind: :image, url: "https://cdn.discordapp.com/file.png", media_type: "image/png"}] =
             incoming.media
  end

  test "transform_incoming/1 unsupported input" do
    assert {:error, :unsupported_message_type} = Channel.transform_incoming("invalid")
  end

  test "send_message/3 delegates to transport" do
    assert {:ok, result} = Channel.send_message("123", "hi", transport: MockTransport)
    assert_received {:send_message, "123", "hi"}
    assert result.message_id == 42
  end

  test "edit_message/4 delegates to transport" do
    assert {:ok, result} = Channel.edit_message("123", "777", "updated", transport: MockTransport)
    assert_received {:edit_message, "123", "777", "updated"}
    assert result.message_id == "777"
  end

  test "delete/start_typing/fetch_metadata methods work" do
    assert :ok = Channel.delete_message("123", "777", transport: MockTransport)
    assert_received {:delete_message, "123", "777"}

    assert :ok = Channel.start_typing("123", transport: MockTransport)
    assert_received {:start_typing, "123", []}

    assert {:ok, info} = Channel.fetch_metadata("123", transport: MockTransport)
    assert_received {:fetch_metadata, "123"}
    assert info.id == "123"
    assert info.name == "general"
  end

  test "open_dm and ephemeral fallback" do
    assert {:ok, "dm-42"} = Channel.open_dm("42", transport: MockTransport)
    assert_received {:open_dm, "42"}

    assert {:ok, ephemeral} =
             Channel.post_ephemeral("123", "42", "secret",
               fallback_to_dm: true,
               transport: MockTransport
             )

    assert ephemeral.used_fallback == true
    assert ephemeral.thread_id == "discord:dm-42"
  end

  test "reaction and history helpers" do
    assert :ok = Channel.add_reaction("123", "777", "👍", transport: MockTransport)
    assert_received {:add_reaction, "123", "777", "👍"}

    assert :ok = Channel.remove_reaction("123", "777", "👍", transport: MockTransport)
    assert_received {:remove_reaction, "123", "777", "👍"}

    assert {:ok, page} = Channel.fetch_messages("123", transport: MockTransport)
    assert_received {:fetch_messages, "123"}
    assert length(page.messages) == 1

    assert {:ok, page2} = Channel.fetch_channel_messages("123", transport: MockTransport)
    assert_received {:fetch_messages, "123"}
    assert length(page2.messages) == 1

    assert {:ok, threads} = Channel.list_threads("123", transport: MockTransport)
    assert_received {:list_threads, "123"}
    assert length(threads.threads) == 1
  end

  test "handle_webhook/3 normalizes and routes through Jido.Chat.process_message/5" do
    chat =
      Chat.new(user_name: "jido", adapters: %{discord: Jido.Chat.Discord.Adapter})
      |> Chat.on_new_mention(fn _thread, _incoming -> send(self(), :mention) end)

    payload = %{
      "id" => "111",
      "channel_id" => "222",
      "content" => "@jido ping",
      "timestamp" => ~U[2024-01-31 12:00:00.000000Z],
      "guild_id" => nil,
      "author" => %{"id" => "444", "username" => "user", "global_name" => nil}
    }

    assert {:ok, _updated_chat, %Jido.Chat.Incoming{} = incoming} =
             Channel.handle_webhook(chat, payload, [])

    assert incoming.external_room_id == "222"
    assert incoming.external_message_id == "111"
    assert_received :mention
  end

  test "interaction webhook routes slash/action/modal events" do
    chat =
      Chat.new(adapters: %{discord: Jido.Chat.Discord.Adapter})
      |> Chat.on_slash_command(fn _event -> send(self(), :slash_hit) end)
      |> Chat.on_action(fn _event -> send(self(), :action_hit) end)
      |> Chat.on_modal_submit(fn _event -> send(self(), :modal_hit) end)

    slash_payload = %{
      "id" => "900",
      "type" => 2,
      "channel_id" => "222",
      "data" => %{"name" => "help", "options" => [%{"value" => "topic"}]},
      "member" => %{"user" => %{"id" => "444", "username" => "user"}}
    }

    assert {:ok, _chat, _incoming} = Channel.handle_webhook(chat, slash_payload, [])
    assert_received :slash_hit

    action_payload = %{
      "id" => "901",
      "type" => 3,
      "channel_id" => "222",
      "data" => %{"custom_id" => "approve", "values" => ["yes"]},
      "member" => %{"user" => %{"id" => "444", "username" => "user"}}
    }

    assert {:ok, _chat, _incoming} = Channel.handle_webhook(chat, action_payload, [])
    assert_received :action_hit

    modal_payload = %{
      "id" => "902",
      "type" => 5,
      "channel_id" => "222",
      "data" => %{
        "custom_id" => "feedback",
        "components" => [%{"components" => [%{"custom_id" => "notes", "value" => "great"}]}]
      },
      "member" => %{"user" => %{"id" => "444", "username" => "user"}}
    }

    assert {:ok, _chat, _incoming} = Channel.handle_webhook(chat, modal_payload, [])
    assert_received :modal_hit
  end

  test "handle_webhook/3 fails closed when signature verification fails" do
    chat = Chat.new(adapters: %{discord: Jido.Chat.Discord.Adapter})

    payload = %{
      "id" => "900",
      "type" => 2,
      "channel_id" => "222",
      "data" => %{"name" => "help"},
      "member" => %{"user" => %{"id" => "444", "username" => "user"}}
    }

    assert {:error, :invalid_signature} =
             Channel.handle_webhook(chat, payload,
               public_key: String.duplicate("A1", 32),
               headers: %{
                 "x-signature-ed25519" => String.duplicate("00", 64),
                 "x-signature-timestamp" => "1706745600"
               },
               raw_body: Jason.encode!(payload)
             )
  end

  test "gateway helper routes reactions and modal_close events" do
    chat =
      Chat.new(adapters: %{discord: Jido.Chat.Discord.Adapter})
      |> Chat.on_reaction(fn _event -> send(self(), :reaction_hit) end)
      |> Chat.on_modal_close(fn _event -> send(self(), :modal_close_hit) end)

    reaction_event = %{
      event: "MESSAGE_REACTION_ADD",
      payload: %{
        channel_id: "222",
        message_id: "111",
        user_id: "444",
        emoji: %{name: "👍"}
      }
    }

    assert {:ok, _chat, _event} = Channel.handle_gateway_event(chat, reaction_event, [])
    assert_received :reaction_hit

    modal_close_event = %{event: "MODAL_CLOSE", payload: %{id: "abc", custom_id: "feedback"}}
    assert {:ok, _chat, _event} = Channel.handle_gateway_event(chat, modal_close_event, [])
    assert_received :modal_close_hit
  end

  test "post_ephemeral supports native interaction response path" do
    assert {:ok, ephemeral} =
             Channel.post_ephemeral("123", "42", "secret",
               transport: MockTransport,
               interaction_id: "777",
               interaction_token: "tok"
             )

    assert ephemeral.used_fallback == false

    assert_received {:interaction_response, "777", "tok",
                     %{type: 4, data: %{content: "secret", flags: 64}}}
  end

  test "open_modal/3 supports interaction context and errors when missing context" do
    assert {:ok, modal} =
             Channel.open_modal(
               "123",
               %{custom_id: "feedback", title: "Feedback", components: []},
               transport: MockTransport,
               interaction_id: "777",
               interaction_token: "tok"
             )

    assert modal.status == :opened

    assert_received {:interaction_response, "777", "tok",
                     %{
                       type: 9,
                       data: %{custom_id: "feedback", title: "Feedback", components: []}
                     }}

    assert {:error, :missing_interaction_context} =
             Channel.open_modal("123", %{custom_id: "feedback", title: "Feedback"}, [])
  end

  test "interaction ping parse and format path returns noop and pong body" do
    request =
      Jido.Chat.WebhookRequest.new(%{
        adapter_name: :discord,
        payload: %{"type" => 1}
      })

    assert {:ok, :noop} = Jido.Chat.Discord.Adapter.parse_event(request, [])

    response =
      Jido.Chat.Discord.Adapter.format_webhook_response(
        {:ok, Chat.new(adapters: %{discord: Jido.Chat.Discord.Adapter}), :noop},
        request: request
      )

    assert response.body == %{type: 1}
  end

  test "component action payload falls back to payload.message.id for message_id" do
    chat =
      Chat.new(adapters: %{discord: Jido.Chat.Discord.Adapter})
      |> Chat.on_action(fn event -> send(self(), {:action_message_id, event.message_id}) end)

    action_payload = %{
      "id" => "901",
      "type" => 3,
      "channel_id" => "222",
      "message" => %{"id" => "msg-from-payload"},
      "data" => %{"custom_id" => "approve", "values" => ["yes"]},
      "member" => %{"user" => %{"id" => "444", "username" => "user"}}
    }

    assert {:ok, _chat, _incoming} = Channel.handle_webhook(chat, action_payload, [])
    assert_received {:action_message_id, "msg-from-payload"}
  end
end
