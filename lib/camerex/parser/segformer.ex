defmodule Camerex.Parser.Segformer do
  @moduledoc """
  Adapter Ortex do `Camerex.Parser` (SegFormer treinado no ATR, 18 classes).
  Registry com load lazy do `segformer_b2_clothes.onnx`; a inferência roda no
  processo **chamador** (sessions ONNX são thread-safe), igual ao
  `Camerex.Segmenter.Ortex`. Pré-processamento fiel ao SegformerImageProcessor:
  resize 512², `/255`, normalização ImageNet, NCHW.
  """

  @behaviour Camerex.Parser

  use GenServer

  @model_file "segformer_b2_clothes.onnx"
  @input 512
  @mean [0.485, 0.456, 0.406]
  @std [0.229, 0.224, 0.225]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl Camerex.Parser
  def parse(rgb, _opts \\ []) do
    with {:ok, model} <- GenServer.call(__MODULE__, :fetch_model, :infinity) do
      run_inference(model, rgb)
    end
  end

  @impl GenServer
  def init(_opts), do: {:ok, %{model: nil}}

  @impl GenServer
  def handle_call(:fetch_model, _from, state) do
    case load(state) do
      {:ok, model, state} -> {:reply, {:ok, model}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp load(%{model: model} = state) when model != nil, do: {:ok, model, state}

  defp load(state) do
    path = :camerex |> Application.fetch_env!(:models_dir) |> Path.join(@model_file)

    if File.exists?(path) do
      model = Ortex.load(path)
      {:ok, model, %{state | model: model}}
    else
      {:error, {:model_not_found, path}}
    end
  end

  defp run_inference(model, rgb) do
    {h, w, 3} = Nx.shape(rgb)

    labels =
      model
      |> Ortex.run(preprocess(rgb))
      |> elem(0)
      |> Nx.backend_transfer()
      |> then(& &1[0])
      |> Nx.argmax(axis: 0)
      |> Nx.as_type(:u8)

    {:ok, upsample(labels, {h, w})}
  rescue
    e -> {:error, e}
  end

  defp preprocess(rgb) do
    rgb
    |> Evision.Mat.from_nx_2d()
    |> Evision.resize({@input, @input}, interpolation: Evision.Constant.cv_INTER_AREA())
    |> Evision.Mat.to_nx(Nx.BinaryBackend)
    |> Nx.as_type(:f32)
    |> Nx.divide(255.0)
    |> Nx.subtract(Nx.tensor(@mean))
    |> Nx.divide(Nx.tensor(@std))
    |> Nx.transpose(axes: [2, 0, 1])
    |> Nx.new_axis(0)
  end

  defp upsample(labels, {h, w}) do
    labels
    |> Evision.Mat.from_nx()
    |> Evision.resize({w, h}, interpolation: Evision.Constant.cv_INTER_NEAREST())
    |> Evision.Mat.to_nx(Nx.BinaryBackend)
  end
end
