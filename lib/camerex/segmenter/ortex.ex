defmodule Camerex.Segmenter.Ortex do
  @moduledoc """
  Adapter Ortex do `Camerex.Segmenter`. O GenServer é apenas um **registry**
  de modelos (load lazy, um por id); a inferência roda no processo
  **chamador** — sessions do ONNX Runtime são thread-safe, então jobs do
  pool processam segmentações de verdade em paralelo.
  """

  @behaviour Camerex.Segmenter

  use GenServer

  alias Camerex.Segmenter.U2Net

  # isnet-general-use: SOD class-agnostic (rembg, Apache) robusto a pose — usado
  # pra preencher os buracos que o ATR deixa em pose aérea (ver Parser.PersonFill)
  @valid_models ~w(u2net u2netp isnet-general-use)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Camerex.Segmenter
  @spec segment(Nx.Tensor.t(), keyword()) :: {:ok, Nx.Tensor.t()} | {:error, term()}
  def segment(rgb, opts \\ []) do
    model_id = Keyword.get(opts, :model, "u2net")

    if model_id in @valid_models do
      with {:ok, model} <- GenServer.call(__MODULE__, {:fetch_model, model_id}, :infinity) do
        run_inference(model, model_id, rgb)
      end
    else
      {:error, {:unknown_model, model_id}}
    end
  end

  @impl GenServer
  def init(_opts) do
    # lazy: nenhum modelo no boot (u2net tem 176 MB); o primeiro
    # segment/2 de cada id paga o load
    {:ok, %{models: %{}}}
  end

  @impl GenServer
  def handle_call({:fetch_model, model_id}, _from, state) do
    case fetch_model(state, model_id) do
      {:ok, model, state} -> {:reply, {:ok, model}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp fetch_model(%{models: models} = state, model_id) do
    case models do
      %{^model_id => model} ->
        {:ok, model, state}

      _ ->
        path =
          :camerex
          |> Application.fetch_env!(:models_dir)
          |> Path.join("#{model_id}.onnx")

        if File.exists?(path) do
          model = Ortex.load(path)
          {:ok, model, put_in(state.models[model_id], model)}
        else
          {:error, {:model_not_found, path}}
        end
    end
  end

  # roda fora do GenServer: inferências concorrentes entre jobs do pool
  defp run_inference(model, model_id, rgb) do
    {h, w, 3} = Nx.shape(rgb)

    d0 =
      model
      |> Ortex.run(preprocess_for(model_id, rgb))
      |> elem(0)
      |> Nx.backend_transfer()

    {:ok, d0 |> U2Net.postprocess({h, w}) |> U2Net.binarize()}
    # fronteira de inferência: catch-all INTENCIONAL — falha nativa (Ortex/Nx) vira
    # o contrato {:error, _} pras with-chains tratarem com graça. Não é silêncio: o
    # item fica "failed" com a mensagem da exceção (bug inclusive).
  rescue
    e -> {:error, e}
  end

  # isnet-general-use roda em 1024² com mean 0.5 / std 1.0 (rembg ISNetSession);
  # u2net/u2netp no default 320² ImageNet
  defp preprocess_for("isnet-general-use", rgb),
    do: U2Net.preprocess(rgb, size: 1024, mean: [0.5, 0.5, 0.5], std: [1.0, 1.0, 1.0])

  defp preprocess_for(_u2net, rgb), do: U2Net.preprocess(rgb)
end
