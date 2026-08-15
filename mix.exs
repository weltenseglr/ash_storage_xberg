defmodule AshStorageXberg.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/weltenseglr/ash_storage_xberg"
  @authors ["AshStorageXberg contributors"]

  def project do
    [
      app: :ash_storage_xberg,
      name: "AshStorageXberg",
      version: @version,
      elixir: "~> 1.15",
      source_url: @source_url,
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description:
        "AshStorage analyzers and variants backed by the xberg document intelligence sidecar",
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # NOTE: a git dependency makes this package unpublishable to Hex
      # (`mix hex.publish` rejects non-Hex deps). Swap for a version
      # requirement once ash_storage has a Hex release.
      {:ash_storage, github: "ash-project/ash_storage"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:xberg, "~> 1.0", optional: true},
      {:plug, "~> 1.16", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: @source_url,
      authors: @authors,
      extras: extras(),
      groups_for_extras: groups_for_extras(),
      groups_for_modules: [
        Analyzers: [
          AshStorageXberg.Analyzers.Audio,
          AshStorageXberg.Analyzers.ContentType,
          AshStorageXberg.Analyzers.Document,
          AshStorageXberg.Analyzers.Image,
          AshStorageXberg.Analyzers.Text
        ],
        Variants: [
          AshStorageXberg.Variants.ExtractedText,
          AshStorageXberg.Variants.PageThumbnail,
          AshStorageXberg.Variants.Transcript
        ],
        "Xberg client": [
          AshStorageXberg.Xberg,
          AshStorageXberg.XbergApi,
          AshStorageXberg.Formats
        ]
      ]
    ]
  end

  defp extras do
    [
      {"README.md", title: "README"},
      {"CHANGELOG.md", title: "Changelog"},
      {"LICENSE", title: "License"}
    ]
  end

  defp groups_for_extras do
    [
      Guides: ~w(README.md),
      Reference: ~w(CHANGELOG.md LICENSE)
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url}
    ]
  end
end
