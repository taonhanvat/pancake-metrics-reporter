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
      {:telemetry_metrics, "~> 0.6"},
      {:plug, "~> 1.6"},
      {:plug_cowboy, "~> 2.0"},
      {:jason, "~> 1.0"}
    ]
  end
end
