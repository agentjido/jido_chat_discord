defmodule Jido.Chat.Discord.SignalsContractTest do
  use Covenant.Case, component: "jido_chat_discord.signals", async: true
  @moduletag capture_log: true
  import Jido.Chat.Discord.Fixtures
  alias Jido.Chat.Discord.Signal, as: D

  defp cases do
    [
      {D.RespondInteraction, "respond_interaction",
       %{"room_id" => "202", "interaction_id" => "909", "response_type" => 4, "data" => %{"content" => "hello"}}},
      {D.SendRichMessage, "send_rich_message",
       %{"room_id" => "202", "text" => "hello", "embeds" => [%{"title" => "hello"}]}},
      {D.StartMessageThread, "start_message_thread", %{"room_id" => "202", "message_id" => "101", "name" => "thread"}}
    ]
  end

  @tag obligation: "jido_chat_discord.signals.I1"
  test "all nine native Signal identities are fixed and catalog roundtrip" do
    schemas = File.read!(Path.join(__DIR__, "fixtures/native_request_schemas.json")) |> Jason.decode!()
    definitions = Jido.Chat.Discord.signal_definitions()
    assert length(definitions) == 9

    for {definition, suffix, data} <- cases() do
      assert definition.__signal_owner__() == :discord
      assert definition.__signal_kind__() == :command
      assert definition.type() == "jido.chat.discord.command." <> suffix
      assert definition.dataschema() == "urn:jido:chat:discord:" <> suffix <> ":1"
      actual_schema = definition.schema() |> Zoi.to_json_schema() |> Jason.encode!() |> Jason.decode!()
      assert actual_schema == schemas[suffix]
      signal = request(definition, data)
      assert {:ok, encoded} = Jido.Signal.Serialization.serialize(signal)
      assert {:ok, ^signal} = Jido.Signal.Catalog.decode(Jido.Chat.Discord.catalog(), encoded)
      assert {:ok, _} = Jido.Signal.Catalog.validate(Jido.Chat.Discord.catalog(), signal)

      for outcome <- ["completed", "failed"] do
        assert Enum.any?(definitions, &(&1.type() == definition.type() <> "." <> outcome))
        assert Enum.any?(definitions, &(&1.dataschema() == definition.dataschema() <> ":" <> outcome))
      end
    end
  end

  @tag obligation: "jido_chat_discord.signals.I2"
  test "constructors enforce shared JSON context options and encoded size policy" do
    for {definition, _, data} <- cases() do
      base = Map.merge(%{"client_id" => "discord-test", "request_id" => "contract"}, data)

      for opts <- [
            [unexpected: true],
            [id: "a", id: "b"],
            %{"id" => "b", :id => "a"},
            [extensions: %{"traceparent" => "bad"}],
            [extensions: %{"private" => "hidden"}],
            [source: "https://user:pass@example.com"]
          ] do
        assert {:error, %Jido.Chat.Errors.Contract{}} = definition.new(base, opts)
      end

      for value <- [
            %{"token" => "blocked"},
            %{"nested" => [%{"credentials" => %{}}]},
            %{"pid" => self()},
            %{atom_key: 1}
          ] do
        changed =
          case definition do
            D.RespondInteraction -> Map.put(base, "data", value)
            D.SendRichMessage -> Map.put(base, "embeds", [value])
            D.StartMessageThread -> Map.put(base, "name", value)
          end

        assert {:error, %Jido.Chat.Errors.Contract{}} = definition.new(changed)
      end

      oversized =
        Map.put(
          base,
          if(definition == D.StartMessageThread,
            do: "name",
            else: if(definition == D.SendRichMessage, do: "text", else: "data")
          ),
          if(definition == D.RespondInteraction,
            do: %{"content" => String.duplicate("x", 263_000)},
            else: String.duplicate("x", 263_000)
          )
        )

      assert {:error, %Jido.Chat.Errors.Contract{code: :signal_too_large}} = definition.new(oversized)
    end
  end
end
