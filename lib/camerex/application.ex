defmodule Camerex.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # ordem normativa do contrato §4: PubSub → Ortex → TaskSupervisor →
    # Jobs → Endpoint. O Ortex carrega modelos lazy: subir sem os .onnx
    # presentes não quebra o boot (o Doctor avisa na UI).
    children = [
      CamerexWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:camerex, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Camerex.PubSub},
      Camerex.Segmenter.Ortex,
      Camerex.Parser.Segformer,
      {Task.Supervisor, name: Camerex.TaskSupervisor},
      Camerex.Jobs,
      CamerexWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Camerex.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    CamerexWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
