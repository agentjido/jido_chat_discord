defmodule Jido.Chat.Discord.OptionsTest do
  use ExUnit.Case, async: true

  alias Jido.Chat.Discord.{
    DeleteOptions,
    EditOptions,
    FetchOptions,
    MetadataOptions,
    ReactionOptions,
    SendOptions,
    TypingOptions
  }

  test "SendOptions.new/1 normalizes keyword options into typed struct" do
    options =
      SendOptions.new(
        embeds: [%{title: "hi"}],
        allowed_mentions: %{parse: ["users"]},
        tts: true
      )

    assert options.tts == true

    transport_opts = SendOptions.transport_opts(options)
    assert Keyword.get(transport_opts, :embeds) == [%{title: "hi"}]
    assert Keyword.get(transport_opts, :allowed_mentions) == %{parse: ["users"]}
    assert Keyword.get(transport_opts, :tts) == true
  end

  test "EditOptions.new/1 normalizes keyword options into typed struct" do
    options =
      EditOptions.new(
        components: [%{type: 1}],
        allowed_mentions: %{parse: []}
      )

    transport_opts = EditOptions.transport_opts(options)
    assert Keyword.get(transport_opts, :components) == [%{type: 1}]
    assert Keyword.get(transport_opts, :allowed_mentions) == %{parse: []}
  end

  test "Delete/Typing/Reaction options normalize" do
    delete_opts = DeleteOptions.new(nostrum_message_api: :message_api)
    typing_opts = TypingOptions.new(status: "working", nostrum_channel_api: :channel_api)
    reaction_opts = ReactionOptions.new(nostrum_message_api: :message_api)

    assert Keyword.get(DeleteOptions.transport_opts(delete_opts), :nostrum_message_api) ==
             :message_api

    assert Keyword.get(TypingOptions.transport_opts(typing_opts), :status) == "working"

    assert Keyword.get(TypingOptions.transport_opts(typing_opts), :nostrum_channel_api) ==
             :channel_api

    assert Keyword.get(ReactionOptions.transport_opts(reaction_opts), :nostrum_message_api) ==
             :message_api
  end

  test "Fetch and Metadata options normalize" do
    fetch_opts =
      FetchOptions.new(
        cursor: "123",
        limit: 25,
        direction: :forward,
        nostrum_channel_api: :channel_api
      )

    metadata_opts = MetadataOptions.new(nostrum_channel_api: :channel_api)

    assert Keyword.get(FetchOptions.transport_opts(fetch_opts), :cursor) == "123"
    assert Keyword.get(FetchOptions.transport_opts(fetch_opts), :limit) == 25
    assert Keyword.get(FetchOptions.transport_opts(fetch_opts), :direction) == :forward

    assert Keyword.get(MetadataOptions.transport_opts(metadata_opts), :nostrum_channel_api) ==
             :channel_api
  end
end
