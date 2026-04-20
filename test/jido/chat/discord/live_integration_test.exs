defmodule Jido.Chat.Discord.LiveIntegrationTest do
  use ExUnit.Case, async: false

  alias Jido.Chat.Discord.Adapter
  alias Jido.Chat.FileUpload

  @run_live System.get_env("RUN_LIVE_DISCORD_TESTS") in ["1", "true", "TRUE", "yes", "on"]
  @token System.get_env("DISCORD_BOT_TOKEN")
  @channel_id System.get_env("DISCORD_TEST_CHANNEL_ID")
  @user_id System.get_env("DISCORD_TEST_USER_ID")

  @moduletag :live
  @moduletag :discord_live

  if not @run_live do
    @moduletag skip: "set RUN_LIVE_DISCORD_TESTS=true to run live Discord integration tests"
  end

  if @run_live and (is_nil(@token) or @token == "" or is_nil(@channel_id) or @channel_id == "") do
    @moduletag skip:
                 "set DISCORD_BOT_TOKEN and DISCORD_TEST_CHANNEL_ID when RUN_LIVE_DISCORD_TESTS=true"
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
end
