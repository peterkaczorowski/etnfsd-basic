defmodule Etnfsd.MixProject do
  use Mix.Project

  def project do
    [
      app: :etnfsd,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_options: [warnings_as_errors: true],
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  def application do
    [
      # `:os_mon` is used for one thing only: `:disksup` knows how to ask each
      # platform for filesystem size, which SIZE/FREE need and `:file` cannot
      # answer. It is part of OTP, not an external dependency.
      extra_applications: [:logger, :crypto, :os_mon],
      mod: {Tnfs.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      # Standard BEAM instrumentation interface. Needed because metrics must be
      # emitted asynchronously off the request path (handoff 7.4).
      {:telemetry, "~> 1.3"}
    ]
  end
end
