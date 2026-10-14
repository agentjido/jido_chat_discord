defmodule Jido.Chat.Discord.ProtocolTest do
  use ExUnit.Case, async: false
  alias Jido.Chat.Discord.Adapter
  alias Jido.Chat.AdapterTestKit.Factories

  defmodule Transport do
    @behaviour Jido.Chat.Discord.Transport
    @methods [
      send_message: 3,
      edit_message: 4,
      delete_message: 3,
      start_typing: 2,
      fetch_metadata: 2,
      open_dm: 2,
      add_reaction: 4,
      remove_reaction: 4,
      fetch_messages: 2,
      fetch_channel_messages: 2,
      list_threads: 2,
      open_thread: 3,
      fetch_message: 3,
      download_file: 2,
      fetch_thread: 2,
      create_interaction_response: 4
    ]
    for {name, arity} <- @methods do
      args = Macro.generate_arguments(arity, __MODULE__)
      @impl true
      def unquote(name)(unquote_splicing(args)) do
        args = [unquote_splicing(args)]
        send(self(), {:provider, unquote(name)})
        if Process.get(:provider_failure), do: {:error, :timeout}, else: result(unquote(name), args)
      end
    end

    defp message(room), do: %{id: "m1", channel_id: room, content: "body", author: %{id: "u1"}}
    defp result(:fetch_message, [room | _]), do: {:ok, message(room)}
    defp result(:fetch_messages, [room | _]), do: {:ok, %{messages: [message(room)], next_cursor: "next"}}
    defp result(:fetch_channel_messages, args), do: result(:fetch_messages, args)
    defp result(:fetch_metadata, [room | _]), do: {:ok, %{id: room, name: "Room", type: 0}}
    defp result(:list_threads, _), do: {:ok, %{threads: [%{id: "thread-1", parent_id: "room/1"}], next_cursor: "next"}}

    defp result(:open_thread, _),
      do: {:ok, %{external_thread_id: "thread-1", delivery_external_room_id: "thread-1", parent_id: "room/1"}}

    defp result(:open_dm, _), do: {:ok, "dm-1"}
    defp result(:download_file, _), do: {:ok, "private-bytes"}
    defp result(:create_interaction_response, _), do: {:ok, true}
    defp result(:send_message, [room | _]), do: {:ok, %{message_id: "m1", channel_id: room}}
    defp result(:edit_message, [room | _]), do: {:ok, %{message_id: "m1", channel_id: room}}
    defp result(_, _), do: :ok
  end

  @matrix Path.join(Mix.Project.deps_paths()[:jido_chat], "docs/migration/adapter-matrix.json")
          |> File.read!()
          |> Jason.decode!()
  @row Enum.find(@matrix["adapters"], &(&1["package"] == "jido_chat_discord"))
  @calls %{
    send_message: [:send_message],
    send_file: [:send_message],
    post_message: [:send_message],
    edit_message: [:edit_message],
    delete_message: [:delete_message],
    start_typing: [:start_typing],
    fetch_metadata: [:fetch_metadata],
    fetch_thread: [:fetch_metadata],
    fetch_message: [:fetch_message],
    fetch_subject: [:fetch_metadata],
    fetch_media: [:download_file],
    add_reaction: [:add_reaction],
    remove_reaction: [:remove_reaction],
    post_ephemeral: [:create_interaction_response],
    post_channel_message: [:send_message],
    stream: [:send_message, :edit_message, :edit_message],
    open_modal: [:create_interaction_response],
    fetch_messages: [:fetch_messages],
    fetch_channel_messages: [:fetch_messages],
    list_threads: [:list_threads],
    open_thread: [:open_thread],
    open_dm: [:open_dm]
  }

  setup do
    {:ok, binding} =
      Jido.Chat.bind(Adapter,
        id: "discord-contract",
        transport: Transport,
        interaction_id: "private-interaction",
        interaction_token: "private-token"
      )

    %{binding: binding}
  end

  test "interaction controls remain private and scoped to their owner and room" do
    {:ok, binding} = Jido.Chat.bind(Adapter, id: "interaction-owner", transport: Transport)

    payload = %{
      "id" => "i-private",
      "type" => 3,
      "channel_id" => "C1",
      "token" => "private-token",
      "data" => %{"custom_id" => "confirm"},
      "user" => %{"id" => "u1"}
    }

    assert {:ok, %{signals: [action]}} = Jido.Chat.normalize_event(binding, payload)
    portable(action)
    assert {:ok, ref} = Adapter.prepare_modal(binding, "i-private", %{title: "Confirm", callback_id: "confirm"})
    assert {:ok, modal} = Jido.Chat.resolve_resource(binding, ref)
    assert modal.metadata.interaction_token == "private-token"

    assert {:error, %{code: :resource_owner_mismatch}} =
             Task.async(fn -> Jido.Chat.resolve_resource(binding, ref) end) |> Task.await()

    {:ok, other} = Jido.Chat.bind(Adapter, id: "other", transport: Transport)
    assert {:error, %{code: :invalid_resource}} = Jido.Chat.resolve_resource(other, ref)
    assert {:error, :interaction_room_mismatch} = Adapter.open_modal("C2", modal, binding.options)
    assert calls() == []
    parent = Factories.operation_request(binding, :open_modal, %{"room_id" => "C1", "modal" => ref})
    assert {:ok, result} = Jido.Chat.execute(binding, parent)
    assert result.type == "jido.chat.operation.completed"
    portable(result)
    assert calls() == [:create_interaction_response]
    assert :ok = Jido.Chat.cancel_resource(binding, ref)
    assert {:error, %{code: :resource_cancelled}} = Jido.Chat.resolve_resource(binding, ref)
    assert {:ok, expired} = Jido.Chat.put_resource(binding, "modal", modal, ttl_ms: 0)
    assert {:error, %{code: :resource_expired}} = Jido.Chat.resolve_resource(binding, expired)
  end

  test "unsupported interactions release private controls and HTTP controls report rejection", %{binding: binding} do
    assert {:ok, unit} =
             Jido.Chat.normalize_event(
               binding,
               {"INTERACTION_CREATE",
                %{"id" => "unsupported", "type" => 99, "token" => "private-token", "channel_id" => "C1"}}
             )

    assert [%{type: "jido.chat.normalization.failed"}] = unit.signals
    assert {:error, %{code: :resource_cancelled}} = Adapter.prepare_modal(binding, "unsupported", %{title: "Test"})
    assert Adapter.format_webhook_response({:ok, unit}, []).status == 200
    response = Adapter.format_webhook_response({:error, {:rejected, "private-token"}}, [])
    assert response.status == 400
    refute inspect(response) =~ "private-token"
    request = Jido.Chat.WebhookRequest.new(%{payload: %{"type" => 1}})
    assert Adapter.format_webhook_response({:ok, unit}, request: request).body == %{type: 1}
  end

  defp request(binding, operation, extra \\ %{}) do
    extra =
      if operation == :fetch_media do
        {:ok, ref} =
          Jido.Chat.put_resource(binding, "media", Jido.Chat.Media.new(%{url: "https://fixture.test/private"}))

        Map.put(extra, "media_ref", ref)
      else
        extra
      end

    Factories.operation_request(binding, operation, extra)
  end

  defp calls do
    receive do
      {:provider, name} -> [name | calls()]
    after
      0 -> []
    end
  end

  defp portable(fact) do
    {:ok, json} = Jido.Signal.Serialization.serialize(fact)
    catalog = Jido.Signal.Catalog.new!(Jido.Chat.signal_definitions())
    assert {:ok, ^fact} = Jido.Signal.Catalog.decode(catalog, json)
    refute json =~ "private-token"
    refute json =~ "private-bytes"
  end

  for {name, support} <- @row["operation_support"] do
    operation = String.to_atom(name)

    test "#{name} matches frozen #{support} with exact calls and a cached native result", %{binding: binding} do
      operation = unquote(operation)
      assert Jido.Chat.Adapter.capabilities(Adapter)[operation] == unquote(String.to_atom(support))
      parent = request(binding, operation)
      before = Jido.Signal.to_map(parent)
      assert {:ok, result} = Jido.Chat.execute(binding, parent)

      if unquote(support) == "unsupported" do
        assert result.type == "jido.chat.operation.failed" and result.data["code"] == "unsupported"
      else
        assert result.type == "jido.chat.operation.completed"
      end

      assert calls() == unquote(Map.get(@calls, operation, []))
      assert {:ok, ^result} = Jido.Chat.execute(binding, parent)
      assert calls() == []
      assert Jido.Signal.to_map(parent) == before
      assert Jido.Signal.Context.get(result, "causationid") == parent.id
      assert Jido.Signal.Trace.get(result).trace_id == Jido.Signal.Trace.get(parent).trace_id
      portable(result)
    end
  end

  defp event(name) do
    message = %{"id" => "m1", "channel_id" => "C1", "content" => "body", "author" => %{"id" => "u1"}}

    case name do
      "MessageReceived" ->
        {"MESSAGE_CREATE", message}

      "MessageUpdated" ->
        {"MESSAGE_UPDATE", Map.put(message, "content", nil)}

      "MessageDeleted" ->
        {"MESSAGE_DELETE", message}

      "ReactionAdded" ->
        {"MESSAGE_REACTION_ADD",
         %{"message_id" => "m1", "channel_id" => "C1", "user_id" => "u1", "emoji" => %{"name" => "👍"}}}

      "ReactionRemoved" ->
        {"MESSAGE_REACTION_REMOVE",
         %{"message_id" => "m1", "channel_id" => "C1", "user_id" => "u1", "emoji" => %{"name" => "👍"}}}

      "ActionReceived" ->
        {"INTERACTION_CREATE",
         %{
           "id" => "i1",
           "channel_id" => "C1",
           "type" => 3,
           "token" => "private-token",
           "data" => %{"custom_id" => "confirm", "values" => ["yes"]}
         }}

      "SlashCommandReceived" ->
        {"INTERACTION_CREATE", %{"id" => "i1", "channel_id" => "C1", "type" => 2, "data" => %{"name" => "help"}}}

      "ModalSubmitted" ->
        {"INTERACTION_CREATE",
         %{"id" => "i1", "channel_id" => "C1", "type" => 5, "data" => %{"custom_id" => "feedback", "components" => []}}}

      "ThreadStarted" ->
        {"THREAD_CREATE", %{"id" => "thread-1", "parent_id" => "C1", "name" => "Thread"}}

      _ ->
        {Macro.underscore(name) |> String.upcase(), %{"guild_id" => "G1", "user_id" => "u1", "roles" => ["R1"]}}
    end
  end

  for {name, support} <- @row["event_support"] do
    test "#{name} has frozen #{support} mapping through all gateway forms", %{binding: binding} do
      {kind, payload} = event(unquote(name))
      forms = [{kind, payload}, %{"t" => kind, "d" => payload}, %{event: kind, payload: payload}]

      facts =
        for input <- forms do
          assert {:ok, %{signals: [fact]}} = Jido.Chat.normalize_event(binding, input)

          expected =
            if unquote(support) == "unsupported",
              do: Jido.Chat.Signal.NormalizationFailed.type(),
              else: Module.concat(Jido.Chat.Signal, unquote(name)).type()

          assert fact.type == expected
          portable(fact)
          fact
        end

      assert Enum.uniq(Enum.map(facts, & &1.data["item_id"])) |> length() == 1
      assert calls() == []
    end
  end

  test "zero, one and many preserve item order and identity across batches", %{binding: binding} do
    assert {:ok, %{signals: []}} = Jido.Chat.normalize_event(binding, [])
    first = event("MessageReceived")
    second = event("MessageDeleted")
    assert {:ok, %{signals: [one]}} = Jido.Chat.normalize_event(binding, first)
    assert {:ok, %{signals: [a, b]}} = Jido.Chat.normalize_event(binding, [first, second])
    assert a.data["item_id"] == one.data["item_id"]
    assert [a.type, b.type] == ["jido.chat.message.received", "jido.chat.message.deleted"]
  end

  test "provider failure is typed and cached with one call", %{binding: binding} do
    Process.put(:provider_failure, true)
    parent = request(binding, :send_message)
    assert {:ok, result} = Jido.Chat.execute(binding, parent)
    assert result.data["code"] == "provider_failure"
    assert calls() == [:send_message]
    assert {:ok, ^result} = Jido.Chat.execute(binding, parent)
    assert calls() == []
  end

  test "cancelled stream has zero enumeration and provider calls", %{binding: binding} do
    stream =
      Stream.map(["hello"], fn text ->
        send(self(), :enumerated)
        text
      end)

    {:ok, ref} = Jido.Chat.put_resource(binding, "stream", stream)
    :ok = Jido.Chat.cancel_resource(binding, ref)
    parent = request(binding, :stream, %{"resource_ref" => ref})
    assert {:ok, result} = Jido.Chat.execute(binding, parent)
    assert result.data["code"] == "resource_cancelled"
    refute_received :enumerated
    assert calls() == []
  end

  test "HTTP mapping uses the signed body and requires a captured public key" do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    {:ok, binding} = Jido.Chat.bind(Adapter, id: "signed-body", public_key: Base.encode16(public, case: :lower))
    signed = %{"id" => "signed", "type" => 2, "channel_id" => "C1", "data" => %{"name" => "help"}}
    raw = Jason.encode!(signed)
    timestamp = "1706745600"
    signature = :crypto.sign(:eddsa, :none, timestamp <> raw, [private, :ed25519]) |> Base.encode16(case: :lower)

    request =
      Jido.Chat.WebhookRequest.new(%{
        payload: Map.put(signed, "id", "unsigned"),
        raw: raw,
        headers: %{"x-signature-ed25519" => signature, "x-signature-timestamp" => timestamp}
      })

    assert {:ok, %{signals: [fact]}} = Jido.Chat.normalize_event(binding, request)
    assert fact.data["interaction_id"] == "signed"
    {:ok, missing} = Jido.Chat.bind(Adapter, id: "missing-key", public_key: nil)
    assert {:error, :missing_public_key} = Adapter.verify_webhook(request, missing.options)
    assert {:error, _} = Jido.Chat.normalize_event(missing, request)
    assert :ets.tab2list(missing.resources) == []
    {:ok, other} = Jido.Chat.bind(Adapter, id: "other")
    assert {:ok, first} = Jido.Chat.normalize_event(binding, event("MessageReceived"))
    assert {:ok, second} = Jido.Chat.normalize_event(other, event("MessageReceived"))
    refute first.id == second.id
  end
end
