defmodule Gavel.MixProject do
  use Mix.Project

  @source_url "https://github.com/an21p/gavel"

  def project do
    [
      app: :gavel,
      version: "0.1.0",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      description: description(),
      package: package(),
      source_url: @source_url,
      deps: deps(),
      docs: docs(),
      test_coverage: [tool: ExCoveralls],
      dialyzer: [plt_add_apps: [:ex_unit]]
    ]
  end

  defp description do
    "A multi-format auction library for Elixir (English, Dutch, Vickrey, " <>
      "sealed first-price, reverse, Japanese): a pure functional core plus an " <>
      "opt-in OTP runtime."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md LICENSE docs/design.md)
    ]
  end

  def cli do
    [preferred_envs: [coveralls: :test, "coveralls.html": :test]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Gavel.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp docs do
    [
      main: "Gavel",
      source_url: @source_url,
      extras: ["README.md", "docs/design.md", "LICENSE"],
      groups_for_modules: [
        Core: [Gavel.Auction, Gavel.Bid, Gavel.Type],
        Formats: [
          Gavel.Types.English,
          Gavel.Types.Dutch,
          Gavel.Types.Vickrey,
          Gavel.Types.SealedFirstPrice,
          Gavel.Types.Reverse,
          Gavel.Types.Japanese
        ],
        Runtime: [Gavel, Gavel.Server, Gavel.Store, Gavel.Store.ETS, Gavel.Store.DETS]
      ]
    ]
  end

  defp deps do
    [
      {:decimal, "~> 2.0"},
      {:phoenix_pubsub, "~> 2.1", optional: true},
      {:stream_data, "~> 1.1", only: [:dev, :test]},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test}
    ]
  end
end
