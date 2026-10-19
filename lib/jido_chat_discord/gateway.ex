defmodule Jido.Chat.Discord.Gateway do
  @moduledoc false
  @doc "Open a verified TLS Gateway socket."
  def open(url, _opts) do
    uri = URI.parse(url)

    :gun.open(String.to_charlist(uri.host), uri.port || 443, %{
      transport: :tls,
      protocols: [:http],
      retry: 0,
      event_handler: {Jido.Chat.Discord.GatewayEvents, nil},
      tls_opts: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        server_name_indication: String.to_charlist(uri.host)
      ]
    })
  end

  @doc "Request the Discord JSON WebSocket protocol."
  def upgrade(pid), do: :gun.ws_upgrade(pid, "/?v=10&encoding=json")
  @doc "Send an encoded Gateway protocol frame."
  def send_frame(pid, stream, data), do: :gun.ws_send(pid, stream, {:text, Jason.encode!(data)})
  @doc "Close the owned Gateway socket."
  def close(pid), do: :gun.close(pid)
end
