defmodule Camerex.Segmenter.Fixture do
  @moduledoc """
  Segmenter de teste (contrato §4): devolve o PNG configurado em
  `config :camerex, :fixture_mask_path` redimensionado ao tamanho do input
  (NEAREST, para continuar binário), ou — sem config — um retângulo
  central `h/2 × w/2`.
  """

  @behaviour Camerex.Segmenter

  @impl Camerex.Segmenter
  def segment(rgb, _opts \\ []) do
    {h, w, 3} = Nx.shape(rgb)

    mask =
      case Application.get_env(:camerex, :fixture_mask_path) do
        nil -> centered_rectangle(h, w)
        path -> from_png(path, h, w)
      end

    {:ok, mask}
  end

  defp centered_rectangle(h, w) do
    top = div(h, 4)
    left = div(w, 4)

    rows = Nx.iota({h, 1})
    cols = Nx.iota({1, w})

    in_rows =
      Nx.logical_and(Nx.greater_equal(rows, top), Nx.less(rows, top + div(h, 2)))

    in_cols =
      Nx.logical_and(Nx.greater_equal(cols, left), Nx.less(cols, left + div(w, 2)))

    in_rows
    |> Nx.logical_and(in_cols)
    |> Nx.multiply(255)
    |> Nx.as_type(:u8)
  end

  defp from_png(path, h, w) do
    path
    |> Evision.imread(flags: Evision.Constant.cv_IMREAD_GRAYSCALE())
    |> Evision.resize({w, h}, interpolation: Evision.Constant.cv_INTER_NEAREST())
    |> Evision.Mat.to_nx(Nx.BinaryBackend)
  end
end
