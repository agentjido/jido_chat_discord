defmodule Jido.Chat.Discord.AdapterSurfaceTest do
  use ExUnit.Case, async: true

  alias Jido.Chat
  alias Jido.Chat.Discord.Adapter
  alias Jido.Chat.FileUpload
  alias Jido.Chat.Media

  setup_all do
    Code.ensure_loaded!(Adapter)
    :ok
  end

  defmodule MockTransport do
    @behaviour Jido.Chat.Discord.Transport

    @impl true
    def send_message(channel_id, text, opts) do
      send(self(), {:send_message, channel_id, text, opts})

      attachment =
        case Keyword.get(opts, :file) do
          nil ->
            []

          file ->
            [
              %{
                id: 99,
                filename: attachment_name(file),
                size: attachment_size(file),
                url: "https://cdn.discordapp.com/mock/#{attachment_name(file)}",
                content_type: attachment_content_type(file)
              }
            ]
        end

      {:ok,
       %{
         message_id: 42,
         channel_id: channel_id,
         timestamp: ~U[2024-01-31 12:00:00.000000Z],
         attachments: attachment
       }}
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
    def open_thread(channel_id, message_id, opts) do
      send(self(), {:open_thread, channel_id, message_id, opts})
      {:ok, %{id: "thread-#{message_id}", parent_id: channel_id}}
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

      attachments =
        if message_id == "expired-message" do
          [
            %{
              id: "attachment-1",
              filename: "file.png",
              content_type: "image/png",
              url: "https://cdn.discordapp.com/refreshed.png"
            }
          ]
        else
          []
        end

      {:ok,
       %{
         id: message_id,
         channel_id: channel_id,
         content: "single",
         guild_id: nil,
         author: %{id: "444", username: "user", global_name: nil},
         attachments: attachments
       }}
    end

    @impl true
    def download_file("https://cdn.discordapp.com/expired.png", _opts) do
      {:error, {:http_error, 403, "expired"}}
    end

    def download_file("https://cdn.discordapp.com/refreshed.png", _opts) do
      {:ok, "refreshed bytes"}
    end

    def download_file(url, opts) do
      send(self(), {:download_file, url, opts})
      {:ok, "downloaded bytes"}
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

    defp attachment_name(path) when is_binary(path), do: Path.basename(path)
    defp attachment_name(%{name: name}), do: name

    defp attachment_size(path) when is_binary(path) do
      path |> File.read!() |> byte_size()
    end

    defp attachment_size(%{body: body}), do: byte_size(body)

    defp attachment_content_type(path) when is_binary(path), do: MIME.from_path(path)
    defp attachment_content_type(%{name: name}), do: MIME.from_path(name)
  end

  defp captured_binding(opts \\ []) do
    {:ok, binding} = Chat.bind(Adapter, [id: "discord-tests", transport: MockTransport, bot_id: "bot"] ++ opts)
    binding
  end

  defp native_message(payload) do
    binding = captured_binding()
    assert {:ok, %{signals: [fact]}} = Chat.normalize_event(binding, payload)
    assert fact.type == "jido.chat.message.received"
    assert {:ok, json} = Jido.Signal.Serialization.serialize(fact)
    catalog = Jido.Signal.Catalog.new!(Chat.signal_definitions())
    assert {:ok, ^fact} = Jido.Signal.Catalog.decode(catalog, json)
    assert fact.source == binding.source
    assert fact.subject == Jido.Chat.Signal.Identity.conversation_subject(binding.id, fact.data["room_id"])

    media =
      Enum.map(fact.data["media"], fn item ->
        assert {:ok, value} = Chat.resolve_resource(binding, item["resource_ref"])
        value
      end)

    {:ok, %{data: fact.data, media: media}}
  end

  defp normalized(payload, opts \\ []) do
    binding = captured_binding(opts)
    assert {:ok, %{signals: facts}} = Chat.normalize_event(binding, payload)
    facts
  end

  test "channel metadata" do
    caps = Adapter.capabilities()

    assert Adapter.channel_type() == :discord
    assert caps.send_message == :native
    assert caps.edit_message == :native
    assert caps.delete_message == :native
    assert caps.open_thread == :native
    assert caps.fetch_media == :native
  end

  test "adapter capabilities matrix declares native/fallback/unsupported surfaces" do
    caps = Jido.Chat.Discord.Adapter.capabilities()

    assert caps.send_message == :native
    assert caps.send_file == :native
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

    assert {:ok, incoming} = native_message(msg)
    assert incoming.data["room_id"] == "222"
    assert incoming.data["sender"]["id"] == "444"
    assert incoming.data["text"] == "Hello"
    assert incoming.data["conversation_kind"] == "channel"
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

    assert {:ok, incoming} = native_message(msg)
    assert incoming.data["room_id"] == "222"
    assert incoming.data["sender"]["id"] == "444"
    assert incoming.data["sender"]["display_name"] == "user"
    assert incoming.data["conversation_kind"] == "direct"
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
        },
        %{
          id: 10,
          url: "https://cdn.discordapp.com/fallback.png",
          filename: "fallback.png",
          content_type: nil
        },
        %{
          id: 11,
          url: "https://cdn.discordapp.com/archive.unknown",
          filename: "archive.unknown",
          content_type: " "
        },
        %{
          id: 12,
          url: " ",
          proxy_url: "https://cdn.discordapp.com/photo.PNG?token=signed",
          filename: " ",
          content_type: nil
        },
        %{
          id: 13,
          url: "https://cdn.discordapp.com/download/13",
          filename: "misleading.png",
          content_type: " application/pdf; charset=binary "
        }
      ]
    }

    assert {:ok, incoming} = native_message(msg)

    assert [media, fallback, unknown, signed_url, misleading] = incoming.media
    assert media.kind == :image
    assert media.url == "https://cdn.discordapp.com/file.png"
    assert media.media_type == "image/png"

    assert media.metadata == %{
             attachment_id: "9",
             channel_id: "2",
             filename: "file.png",
             message_id: "1"
           }

    assert fallback.kind == :image
    assert fallback.filename == "fallback.png"
    assert fallback.media_type == nil

    assert unknown.kind == :file
    assert unknown.filename == "archive.unknown"
    assert unknown.media_type == nil

    assert signed_url.kind == :image
    assert signed_url.url == "https://cdn.discordapp.com/photo.PNG?token=signed"
    assert signed_url.filename == nil
    assert signed_url.media_type == nil

    assert misleading.kind == :file
    assert misleading.media_type == "application/pdf"
  end

  test "fetch_media/2 downloads raw URLs and media references" do
    url = "https://cdn.discordapp.com/file.png"

    assert {:ok, "downloaded bytes"} = Adapter.fetch_media(url, transport: MockTransport)
    assert_received {:download_file, ^url, opts}
    assert opts[:transport] == MockTransport

    media = Media.new(%{url: url, filename: "file.png"})

    assert {:ok, "downloaded bytes"} = Adapter.fetch_media(media, transport: MockTransport)
    assert_received {:download_file, ^url, _opts}
  end

  test "fetch_media/2 refreshes an expired Discord attachment URL" do
    media =
      Media.new(%{
        url: "https://cdn.discordapp.com/expired.png",
        filename: "file.png",
        metadata: %{
          attachment_id: "attachment-1",
          channel_id: "123",
          filename: "file.png",
          message_id: "expired-message"
        }
      })

    assert {:ok, "refreshed bytes"} = Adapter.fetch_media(media, transport: MockTransport)
    assert_received {:fetch_message, "123", "expired-message"}

    filename_fallback = put_in(media.metadata.attachment_id, "stale-attachment-id")

    assert {:ok, "refreshed bytes"} =
             Adapter.fetch_media(filename_fallback, transport: MockTransport)

    assert_received {:fetch_message, "123", "expired-message"}

    assert {:error, {:http_error, 403, "expired"}} =
             Adapter.fetch_media("https://cdn.discordapp.com/expired.png",
               transport: MockTransport
             )

    refute_received {:fetch_message, _, _}
  end

  test "transform_incoming/1 unsupported input" do
    [failure] = normalized("invalid")
    assert failure.type == "jido.chat.normalization.failed"
    assert failure.data["code"] == "invalid_item"
  end

  test "send_message/3 delegates to transport" do
    assert {:ok, result} = Adapter.send_message("123", "hi", transport: MockTransport)
    assert_received {:send_message, "123", "hi", []}
    assert result.message_id == 42
    assert result.message_id == 42
  end

  test "send_message/3 maps generic reply_to_id to discord message_reference" do
    assert {:ok, _result} =
             Adapter.send_message("123", "hi",
               transport: MockTransport,
               reply_to_id: 777
             )

    assert_received {:send_message, "123", "hi", opts}
    assert Keyword.get(opts, :message_reference) == %{message_id: "777"}
  end

  test "send_file/3 uploads path-backed and in-memory files" do
    path =
      Path.join(
        System.tmp_dir!(),
        "jido-discord-upload-#{System.unique_integer([:positive])}.txt"
      )

    File.write!(path, "discord path upload\n")

    on_exit(fn ->
      File.rm(path)
    end)

    assert {:ok, path_result} =
             Adapter.send_file(
               "123",
               %FileUpload{
                 kind: :file,
                 path: path,
                 filename: Path.basename(path)
               },
               transport: MockTransport
             )

    assert path_result.message_id == "42"
    assert path_result.metadata.filename == Path.basename(path)
    assert path_result.metadata.upload_kind == :file
    assert path_result.metadata.delivered_kind == :file
    assert_received {:send_message, "123", nil, path_opts}
    assert Keyword.get(path_opts, :file) == path

    assert {:ok, bytes_result} =
             Adapter.send_file(
               "123",
               %FileUpload{
                 kind: :file,
                 data: "discord bytes upload\n",
                 filename: "bytes.txt"
               },
               transport: MockTransport
             )

    assert bytes_result.message_id == "42"
    assert bytes_result.metadata.filename == "bytes.txt"
    assert_received {:send_message, "123", nil, bytes_opts}
    assert Keyword.get(bytes_opts, :file) == %{body: "discord bytes upload\n", name: "bytes.txt"}
  end

  test "send_file/3 returns explicit validation errors for unsupported or incomplete inputs" do
    assert {:error, :missing_filename} =
             Adapter.send_file(
               "123",
               %FileUpload{kind: :file, data: "discord bytes upload\n"},
               transport: MockTransport
             )

    assert {:error, :unsupported_remote_url} =
             Adapter.send_file(
               "123",
               %FileUpload{
                 kind: :file,
                 url: "https://example.com/file.txt",
                 filename: "file.txt"
               },
               transport: MockTransport
             )

    assert {:error, :missing_file_source} =
             Adapter.send_file(
               "123",
               %FileUpload{kind: :file, filename: "missing.txt"},
               transport: MockTransport
             )
  end

  test "edit_message/4 delegates to transport" do
    assert {:ok, result} = Adapter.edit_message("123", "777", "updated", transport: MockTransport)
    assert_received {:edit_message, "123", "777", "updated"}
    assert result.message_id == "777"
  end

  test "delete/start_typing/fetch_metadata methods work" do
    assert :ok = Adapter.delete_message("123", "777", transport: MockTransport)
    assert_received {:delete_message, "123", "777"}

    assert :ok = Adapter.start_typing("123", transport: MockTransport)
    assert_received {:start_typing, "123", []}

    assert {:ok, info} = Adapter.fetch_metadata("123", transport: MockTransport)
    assert_received {:fetch_metadata, "123"}
    assert info.id == "123"
    assert info.name == "general"
  end

  test "open_dm and ephemeral fallback" do
    assert {:ok, "dm-42"} = Adapter.open_dm("42", transport: MockTransport)
    assert_received {:open_dm, "42"}

    assert {:ok, ephemeral} =
             Adapter.post_ephemeral("123", "42", "secret",
               fallback_to_dm: true,
               transport: MockTransport
             )

    assert ephemeral.used_fallback == true
    assert ephemeral.thread_id == "discord:dm-42"
  end

  test "reaction and history helpers" do
    assert :ok = Adapter.add_reaction("123", "777", "👍", transport: MockTransport)
    assert_received {:add_reaction, "123", "777", "👍"}

    assert :ok = Adapter.remove_reaction("123", "777", "👍", transport: MockTransport)
    assert_received {:remove_reaction, "123", "777", "👍"}

    assert {:ok, page} = Adapter.fetch_messages("123", transport: MockTransport)
    assert_received {:fetch_messages, "123"}
    assert length(page.messages) == 1

    assert {:ok, page2} = Adapter.fetch_channel_messages("123", transport: MockTransport)
    assert_received {:fetch_messages, "123"}
    assert length(page2.messages) == 1

    assert {:ok, threads} = Adapter.list_threads("123", transport: MockTransport)
    assert_received {:list_threads, "123"}
    assert length(threads.threads) == 1
  end

  test "handle_webhook/3 normalizes and routes through Jido.Chat.process_message/5" do
    payload = %{
      "id" => "111",
      "channel_id" => "222",
      "content" => "@jido ping",
      "author" => %{"id" => "444"},
      "mentions" => [%{"id" => "bot"}]
    }

    {binding, request} = signed_request(payload)
    {:ok, unit} = Chat.normalize_event(binding, request)
    {:ok, handlers} = Jido.Chat.Handlers.new()

    {:ok, handlers} =
      Jido.Chat.Handlers.on(handlers, Jido.Chat.Signal.MessageReceived, fn fact -> send(self(), {:mention, fact}) end,
        mode: :mention
      )

    assert {:ok, _, _} = Jido.Chat.Handlers.accept(handlers, binding, unit)
    assert_receive {:mention, fact}
    assert fact.data["room_id"] == "222"
    assert fact.data["message_id"] == "111"
    assert fact.data["text"] == "@jido ping"
  end

  test "interaction webhook routes slash/action/modal events" do
    binding = captured_binding()

    payloads = [
      %{
        "id" => "900",
        "type" => 2,
        "channel_id" => "222",
        "data" => %{"name" => "help", "options" => [%{"value" => "topic"}]},
        "member" => %{"user" => %{"id" => "444"}}
      },
      %{
        "id" => "901",
        "type" => 3,
        "channel_id" => "222",
        "data" => %{"custom_id" => "approve", "values" => ["yes"]},
        "member" => %{"user" => %{"id" => "444"}}
      },
      %{
        "id" => "902",
        "type" => 5,
        "channel_id" => "222",
        "data" => %{
          "custom_id" => "feedback",
          "components" => [%{"components" => [%{"custom_id" => "notes", "value" => "great"}]}]
        },
        "member" => %{"user" => %{"id" => "444"}}
      }
    ]

    assert {:ok, %{signals: [slash, action, modal]}} = Chat.normalize_event(binding, payloads)
    assert slash.type == "jido.chat.slash_command.received" and slash.data["text"] == "topic"
    assert action.type == "jido.chat.action.received" and action.data["values"] == %{"approve" => ["yes"]}
    assert modal.type == "jido.chat.modal.submitted" and modal.data["values"] == %{"notes" => "great"}
    {:ok, handlers} = Jido.Chat.Handlers.new()

    handlers =
      Enum.reduce(
        [Jido.Chat.Signal.SlashCommandReceived, Jido.Chat.Signal.ActionReceived, Jido.Chat.Signal.ModalSubmitted],
        handlers,
        fn definition, acc ->
          {:ok, acc} = Jido.Chat.Handlers.on(acc, definition, fn fact -> send(self(), {:handled, fact.type}) end)
          acc
        end
      )

    {:ok, unit} = Chat.normalize_event(binding, payloads)
    assert {:ok, _, _} = Jido.Chat.Handlers.accept(handlers, binding, unit)
    assert_receive {:handled, "jido.chat.slash_command.received"}
    assert_receive {:handled, "jido.chat.action.received"}
    assert_receive {:handled, "jido.chat.modal.submitted"}
  end

  test "handle_webhook/3 fails closed when signature verification fails" do
    binding = captured_binding(public_key: String.duplicate("A1", 32))
    payload = %{"id" => "900", "type" => 2, "channel_id" => "222", "data" => %{"name" => "help"}}

    request =
      Jido.Chat.WebhookRequest.new(%{
        payload: payload,
        raw: Jason.encode!(payload),
        headers: %{"x-signature-ed25519" => String.duplicate("00", 64), "x-signature-timestamp" => "1706745600"}
      })

    assert {:error, :invalid_signature} = Adapter.verify_webhook(request, binding.options)
    assert {:error, %Jido.Chat.Errors.Contract{code: :invalid_delivery}} = Chat.normalize_event(binding, request)
  end

  test "gateway helper routes reactions and modal_close events" do
    [reaction] =
      normalized(%{
        event: "MESSAGE_REACTION_ADD",
        payload: %{channel_id: "222", message_id: "111", user_id: "444", emoji: %{name: "👍"}}
      })

    assert reaction.type == "jido.chat.reaction.added"
    assert reaction.data["reaction"] == "👍"
    [unsupported] = normalized(%{event: "MODAL_CLOSE", payload: %{id: "abc", custom_id: "feedback"}})
    assert unsupported.type == "jido.chat.normalization.failed"
    assert unsupported.data["code"] == "unsupported_item"
  end

  test "gateway helper routes message lifecycle events without changing message create" do
    [updated] =
      normalized(%{
        "t" => "MESSAGE_UPDATE",
        "d" => %{"id" => "111", "channel_id" => "222", "edited_timestamp" => "2026-08-20T12:00:00Z", "flags" => 4}
      })

    assert updated.type == "jido.chat.message.updated"
    assert updated.data["message_id"] == "111" and updated.data["text"] == nil
    assert updated.data["timestamp"] == "2026-08-20T12:00:00Z"
    [deleted] = normalized({:MESSAGE_DELETE, %{"id" => "111", "channel_id" => "222", "guild_id" => "guild-1"}})
    assert deleted.type == "jido.chat.message.deleted" and deleted.data["message_id"] == "111"

    [created] =
      normalized(
        {:MESSAGE_CREATE,
         %{"id" => "112", "channel_id" => "222", "content" => "new message", "author" => %{"id" => "444"}}}
      )

    assert created.type == "jido.chat.message.received" and created.data["text"] == "new message"

    for payload <- [{:MESSAGE_UPDATE, %{"id" => "111"}}, {:MESSAGE_DELETE, %{"channel_id" => "222"}}] do
      [failure] = normalized(payload)
      assert failure.type == "jido.chat.normalization.failed" and failure.data["code"] == "invalid_item"
    end
  end

  test "gateway helper rejects invalid lifecycle payloads and still routes the next event" do
    payloads = [
      %{"t" => "MESSAGE_UPDATE", "d" => "not-a-map"},
      %{"t" => "MESSAGE_UPDATE", "d" => %{"id" => %{}, "channel_id" => %{}}},
      {:MESSAGE_CREATE,
       %{"id" => "112", "channel_id" => "222", "content" => "still routed", "author" => %{"id" => "444"}}}
    ]

    assert [first, second, created] = normalized(payloads)
    assert first.type == "jido.chat.normalization.failed"
    assert second.type == "jido.chat.normalization.failed"
    assert created.data["text"] == "still routed"
  end

  test "post_ephemeral supports native interaction response path" do
    assert {:ok, ephemeral} =
             Adapter.post_ephemeral("123", "42", "secret",
               transport: MockTransport,
               interaction_id: "777",
               interaction_token: "tok"
             )

    assert ephemeral.used_fallback == false

    assert_received {:interaction_response, "777", "tok", %{type: 4, data: %{content: "secret", flags: 64}}}
  end

  test "open_modal/3 supports interaction context and errors when missing context" do
    assert {:ok, modal} =
             Adapter.open_modal(
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
             Adapter.open_modal("123", %{custom_id: "feedback", title: "Feedback"}, [])
  end

  test "interaction ping parse and format path returns noop and pong body" do
    {binding, request} = signed_request(%{"type" => 1})
    assert {:ok, %{signals: []} = unit} = Chat.normalize_event(binding, request)
    response = Adapter.format_webhook_response({:ok, unit}, request: request)
    assert response.body == %{type: 1}
  end

  test "component action payload falls back to payload.message.id for message_id" do
    [action] =
      normalized(%{
        "id" => "901",
        "type" => 3,
        "channel_id" => "222",
        "message" => %{"id" => "msg-from-payload"},
        "data" => %{"custom_id" => "approve", "values" => ["yes"]},
        "member" => %{"user" => %{"id" => "444"}}
      })

    assert action.type == "jido.chat.action.received"
    assert action.data["message_id"] == "msg-from-payload"
  end

  defp signed_request(payload) do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    raw = Jason.encode!(payload)
    timestamp = "1706745600"
    signature = :crypto.sign(:eddsa, :none, timestamp <> raw, [private, :ed25519]) |> Base.encode16(case: :lower)
    binding = captured_binding(public_key: Base.encode16(public, case: :lower))

    request =
      Jido.Chat.WebhookRequest.new(%{
        payload: payload,
        raw: raw,
        headers: %{"x-signature-ed25519" => signature, "x-signature-timestamp" => timestamp}
      })

    {binding, request}
  end
end
