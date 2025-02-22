defmodule MetricsCake.MixProject do
  use Mix.Project

  def project do
    [
      app: :pancake_metrics_reporter,
      version: "0.1.0",
      elixir: "~> 1.6",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:telemetry_metrics, "~> 0.5.0"},
      {:plug, "~> 1.7.0"},
      {:plug_cowboy, "~> 1.0"},
      {:plug_crypto, "~> 1.1.2"},
      {:jason, "~> 1.0"}
    ]
  end
end
