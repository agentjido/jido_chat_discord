defmodule Jido.Chat.Discord.LiveIntegrationTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.Adapter, as: ChatAdapter
  alias Jido.Chat.PostPayload
  alias Jido.Chat.Discord.Adapter
  alias Jido.Chat.FileUpload

  @run_live System.get_env("RUN_LIVE_DISCORD_TESTS") in ["1", "true", "TRUE", "yes", "on"]
  @token System.get_env("DISCORD_BOT_TOKEN")
  @channel_id System.get_env("DISCORD_TEST_CHANNEL_ID")
  @user_id System.get_env("DISCORD_TEST_USER_ID")
  @reaction System.get_env("DISCORD_TEST_REACTION") || "👍"

  @moduletag :live
  @moduletag :discord_live

  if not @run_live do
    @moduletag skip: "set RUN_LIVE_DISCORD_TESTS=true to run live Discord integration tests"
  end

  if @run_live and (is_nil(@token) or @token == "" or is_nil(@channel_id) or @channel_id == "") do
    @moduletag skip: "set DISCORD_BOT_TOKEN and DISCORD_TEST_CHANNEL_ID when RUN_LIVE_DISCORD_TESTS=true"
  end

  setup_all do
    previous_env = Application.get_all_env(:nostrum)

    Application.put_env(:nostrum, :token, @token)
    Application.put_env(:nostrum, :ffmpeg, nil)
    Application.put_env(:nostrum, :youtubedl, nil)
    Application.put_env(:nostrum, :streamlink, nil)

    {:ok, _started} = Application.ensure_all_started(:nostrum)

    on_exit(fn ->
      Application.stop(:nostrum)
      restore_app_env(:nostrum, previous_env)
    end)

    {:ok, channel_id: @channel_id}
  end

  test "send/edit/delete message against live Discord API", ctx do
    text = "jido discord live #{System.system_time(:millisecond)}"

    assert {:ok, sent} = Adapter.send_message(ctx.channel_id, text)
    message_id = sent.external_message_id || sent.message_id
    assert is_binary(message_id)

    assert {:ok, fetched} = Adapter.fetch_message(ctx.channel_id, message_id)
    assert fetched.external_message_id == message_id
    assert fetched.external_room_id == to_string(ctx.channel_id)

    assert {:ok, edited} = Adapter.edit_message(ctx.channel_id, message_id, text <> " (edited)")
    assert edited.external_message_id == message_id

    assert :ok = Adapter.delete_message(ctx.channel_id, message_id)
  end

  test "typing and metadata calls succeed against live Discord API", ctx do
    assert :ok = Adapter.start_typing(ctx.channel_id)

    assert {:ok, info} = Adapter.fetch_metadata(ctx.channel_id)
    assert info.id == to_string(ctx.channel_id)
  end

  test "stream fallback edits a visible draft and leaves the final content", ctx do
    parts = [
      "jido",
      " discord",
      " streaming",
      " fallback",
      " should",
      " be",
      " visible"
    ]

    chunk_stream =
      Stream.concat([
        [hd(parts)],
        Stream.map(tl(parts), fn chunk ->
          Process.sleep(500)
          chunk
        end)
      ])

    assert {:ok, sent} =
             ChatAdapter.stream(
               Adapter,
               ctx.channel_id,
               chunk_stream,
               placeholder_text: "jido discord draft...",
               update_every: 1
             )

    message_id = sent.external_message_id || sent.message_id
    assert is_binary(message_id)

    Process.sleep(1_000)

    assert {:ok, fetched} = Adapter.fetch_message(ctx.channel_id, message_id)
    assert fetched.external_message_id == message_id
    assert fetched.text == Enum.join(parts)

    assert :ok = Adapter.delete_message(ctx.channel_id, message_id)
  end

  test "reply continuity preserves Discord message_reference metadata", ctx do
    root_text = "jido discord reply root #{System.system_time(:millisecond)}"
    reply_text = "jido discord reply child #{System.system_time(:millisecond)}"

    assert {:ok, root} = Adapter.send_message(ctx.channel_id, root_text)
    root_id = root.external_message_id || root.message_id

    on_exit(fn ->
      cleanup_delete(fn ->
        Adapter.delete_message(ctx.channel_id, root_id)
      end)
    end)

    assert {:ok, reply} = Adapter.send_message(ctx.channel_id, reply_text, reply_to_id: root_id)
    reply_id = reply.external_message_id || reply.message_id

    on_exit(fn ->
      cleanup_delete(fn ->
        Adapter.delete_message(ctx.channel_id, reply_id)
      end)
    end)

    assert {:ok, fetched} = Adapter.fetch_message(ctx.channel_id, reply_id)

    message_reference = map_get(fetched.raw, [:message_reference, "message_reference"])
    assert is_map(message_reference)
    assert to_string(map_get(message_reference, [:message_id, "message_id"])) == root_id
    assert fetched.external_room_id == to_string(ctx.channel_id)
  end

  test "reaction flow succeeds against live Discord API", ctx do
    assert {:ok, sent} =
             Adapter.send_message(
               ctx.channel_id,
               "jido discord reaction target #{System.system_time(:millisecond)}"
             )

    message_id = sent.external_message_id || sent.message_id

    on_exit(fn ->
      cleanup_delete(fn ->
        Adapter.delete_message(ctx.channel_id, message_id)
      end)
    end)

    case Adapter.add_reaction(ctx.channel_id, message_id, @reaction) do
      :ok ->
        Process.sleep(500)
        assert :ok = Adapter.remove_reaction(ctx.channel_id, message_id, @reaction)

      {:error, %Nostrum.Error.ApiError{status_code: 400} = error} ->
        assert error.status_code == 400
    end
  end

  test "send_file/3 uploads a local file against live Discord API", ctx do
    path =
      write_temp_file(
        "jido-discord-live-",
        ".txt",
        "discord live file #{System.system_time(:millisecond)}\n"
      )

    on_exit(fn ->
      File.rm(path)
    end)

    assert {:ok, sent} =
             Adapter.send_file(
               ctx.channel_id,
               FileUpload.new(%{
                 kind: :file,
                 path: path,
                 filename: Path.basename(path)
               })
             )

    message_id = sent.external_message_id || sent.message_id
    assert is_binary(message_id)
    assert :ok = Adapter.delete_message(ctx.channel_id, message_id)
  end

  test "send_file accepts raw bytes and core post_message uses canonical file fallback", ctx do
    assert {:ok, bytes_sent} =
             Adapter.send_file(
               ctx.channel_id,
               FileUpload.new(%{
                 kind: :file,
                 data: "discord live bytes #{System.system_time(:millisecond)}\n",
                 filename: "discord-live-bytes.txt",
                 media_type: "text/plain"
               })
             )

    bytes_message_id = bytes_sent.external_message_id || bytes_sent.message_id

    on_exit(fn ->
      cleanup_delete(fn ->
        Adapter.delete_message(ctx.channel_id, bytes_message_id)
      end)
    end)

    assert {:ok, bytes_fetched} = Adapter.fetch_message(ctx.channel_id, bytes_message_id)
    assert length(bytes_fetched.attachments) == 1

    payload =
      PostPayload.new(%{
        text: "jido discord canonical file #{System.system_time(:millisecond)}",
        files: [
          %{
            kind: :file,
            data: "discord canonical bytes #{System.system_time(:millisecond)}\n",
            filename: "discord-canonical.txt",
            media_type: "text/plain"
          }
        ]
      })

    assert {:ok, canonical_sent} = ChatAdapter.post_message(Adapter, ctx.channel_id, payload)
    canonical_message_id = canonical_sent.external_message_id || canonical_sent.message_id

    on_exit(fn ->
      cleanup_delete(fn ->
        Adapter.delete_message(ctx.channel_id, canonical_message_id)
      end)
    end)

    assert {:ok, canonical_fetched} = Adapter.fetch_message(ctx.channel_id, canonical_message_id)
    assert length(canonical_fetched.attachments) == 1
  end

  if @user_id not in [nil, ""] do
    test "open_dm/2 returns a DM channel when DISCORD_TEST_USER_ID is provided" do
      assert {:ok, dm_channel_id} = Adapter.open_dm(@user_id)
      assert is_integer(dm_channel_id) or is_binary(dm_channel_id)
    end
  else
    test "open_dm/2 live test requires DISCORD_TEST_USER_ID" do
      assert is_nil(@user_id) or @user_id == ""
    end
  end

  defp restore_app_env(app, previous_env) do
    current_keys =
      app
      |> Application.get_all_env()
      |> Keyword.keys()

    previous_keys = Keyword.keys(previous_env)

    Enum.each(current_keys -- previous_keys, fn key ->
      Application.delete_env(app, key)
    end)

    Enum.each(previous_env, fn {key, value} ->
      Application.put_env(app, key, value)
    end)
  end

  defp write_temp_file(prefix, suffix, contents) do
    path =
      Path.join(
        System.tmp_dir!(),
        "#{prefix}#{System.unique_integer([:positive])}#{suffix}"
      )

    File.write!(path, contents)
    path
  end

  defp cleanup_delete(fun) when is_function(fun, 0) do
    case fun.() do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp map_get(nil, _keys), do: nil

  defp map_get(map, keys) when is_list(keys) do
    Enum.find_value(keys, fn key ->
      cond do
        is_map(map) -> Map.get(map, key)
        true -> nil
      end
    end)
  end
end
