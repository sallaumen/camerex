defmodule Camerex.Parser.Schp do
  @moduledoc """
  Adapter Ortex do SCHP (Self-Correction Human Parsing, treinado no LIP, 20
  classes). Segunda opinião de parsing pro `Camerex.Parser.HeadFusion`: o LIP
  tem distribuição de pose mais ampla que o ATR (SegFormer), então recupera a
  CABEÇA em pose aérea/invertida onde o ATR cega (provado no pixel — tecido-2:
  ATR 0px de cabelo, SCHP 4279px).

  Registry com load lazy do `schp-lip-20-int8.onnx`; a inferência roda no
  processo **chamador** (sessions ONNX são thread-safe), igual ao `Segformer`.
  Entrada fixa 473²: **BGR**, `/255`, normalização própria do SCHP (ordem BGR),
  NCHW. Saída logits `{20, 473, 473}` → upsample bilinear → argmax.

  Classes LIP relevantes: 2 = cabelo, 13 = rosto, 14/15 = braços, 16/17 = pernas.
  """

  use GenServer

  @model_file "schp-lip-20-int8.onnx"
  @input 473
  # normalização do SCHP, aplicada na ordem dos canais BGR (cv2 lê BGR)
  @mean [0.406, 0.456, 0.485]
  @std [0.225, 0.224, 0.229]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Parseia `{h,w,3}` u8 RGB → `{:ok, {h,w}}` u8 com a classe LIP (0..19) por pixel."
  @spec parse(Nx.Tensor.t()) :: {:ok, Nx.Tensor.t()} | {:error, term()}
  def parse(rgb) do
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

    logits =
      model
      |> Ortex.run(preprocess(rgb))
      |> elem(0)
      |> Nx.backend_transfer()
      |> then(& &1[0])

    {:ok, upsampled_argmax(logits, {h, w})}
    # fronteira de inferência: catch-all INTENCIONAL — falha nativa vira {:error, _}
    # pras with-chains tratarem com graça (idem Segformer/Ortex).
  rescue
    e -> {:error, e}
  end

  defp preprocess(rgb) do
    rgb
    # RGB → BGR (o SCHP foi treinado com imagens cv2 BGR)
    |> Nx.reverse(axes: [2])
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

  # logits {20,473,473} → upsample bilinear pra {h,w} → argmax por classe
  defp upsampled_argmax(logits, {h, w}) do
    logits
    |> Nx.transpose(axes: [1, 2, 0])
    |> Evision.Mat.from_nx_2d()
    |> Evision.resize({w, h}, interpolation: Evision.Constant.cv_INTER_LINEAR())
    |> Evision.Mat.to_nx(Nx.BinaryBackend)
    |> Nx.argmax(axis: -1)
    |> Nx.as_type(:u8)
  end
end
