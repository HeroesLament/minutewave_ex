defmodule Minutewave.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/HeroesLament/minutewave_ex"

  def project do
    [
      app: :minutewave,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      description: description(),
      package: package(),
      docs: docs(),
      source_url: @source_url,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {Minutewave.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp description do
    "BEAM-side protocol stack for MIL-STD HF radio (188-110D, ALE, MELPe-600 over 110D). Brand-agnostic library."
  end

  defp package do
    [
      maintainers: ["HeroesLament"],
      licenses: ["MIT OR Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md LICENSE-MIT LICENSE-APACHE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      source_url: @source_url,
      source_ref: "v#{@version}"
    ]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end
end
