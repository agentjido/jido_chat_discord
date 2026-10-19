defmodule Jido.Chat.Discord.GatewayEvents do
  @moduledoc false
  @behaviour :gun_event
  @impl true
  def init(_, state) do
    Process.flag(:sensitive, true)
    state
  end

  @impl true
  def domain_lookup_start(_, state), do: state
  @impl true
  def domain_lookup_end(_, state), do: state
  @impl true
  def connect_start(_, state), do: state
  @impl true
  def connect_end(_, state), do: state
  @impl true
  def tls_handshake_start(_, state), do: state
  @impl true
  def tls_handshake_end(_, state), do: state
  @impl true
  def request_start(_, state), do: state
  @impl true
  def request_headers(_, state), do: state
  @impl true
  def request_end(_, state), do: state
  @impl true
  def push_promise_start(_, state), do: state
  @impl true
  def push_promise_end(_, state), do: state
  @impl true
  def response_start(_, state), do: state
  @impl true
  def response_inform(_, state), do: state
  @impl true
  def response_headers(_, state), do: state
  @impl true
  def response_trailers(_, state), do: state
  @impl true
  def response_end(_, state), do: state
  @impl true
  def ws_upgrade(_, state), do: state
  @impl true
  def ws_recv_frame_start(_, state), do: state
  @impl true
  def ws_recv_frame_header(_, state), do: state
  @impl true
  def ws_recv_frame_end(_, state), do: state
  @impl true
  def ws_send_frame_start(_, state), do: state
  @impl true
  def ws_send_frame_end(_, state), do: state
  @impl true
  def protocol_changed(_, state), do: state
  @impl true
  def origin_changed(_, state), do: state
  @impl true
  def cancel(_, state), do: state
  @impl true
  def disconnect(_, state), do: state
  @impl true
  def terminate(_, state), do: state
end
