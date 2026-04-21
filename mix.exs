defmodule Jido.Chat.Discord.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/agentjido/jido_chat_discord"

  def project do
    [
      app: :jido_chat_discord,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      name: "Jido Chat Discord",
      description: "Discord adapter package for Jido.Chat",
      source_url: @source_url,
      homepage_url: @source_url
    ]
  end

  def cli do
    [preferred_envs: [quality: :test, q: :test]]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:jido_chat, github: "agentjido/jido_chat", branch: "main"},
      {:nostrum, "~> 0.10", runtime: false},
      {:dotenvy, "~> 1.1", only: [:test]}
    ]
  end

  defp aliases do
    [
      q: ["quality"],
      quality: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "test"
      ]
    ]
  end
end
