defmodule Camerex.Pipeline.PhotoLayeredModelTest do
  # caminho cor-por-parte (único modo) ponta a ponta com o PARSER REAL
  # (Segformer/ATR) — valida o pipeline real, não os núcleos sintéticos.
  # Precisa do modelo em priv/models — corre com `mix test --include model`.
  use ExUnit.Case, async: false

  @moduletag :model

  alias Camerex.Parser.Layers
  alias Camerex.Pipeline.Photo

  @casal Path.expand("exemplos/entrada/casal.jpg")

  setup do
    prev = Application.fetch_env!(:camerex, :parser)
    Application.put_env(:camerex, :parser, Camerex.Parser.Segformer)
    on_exit(fn -> Application.put_env(:camerex, :parser, prev) end)

    unless Process.whereis(Camerex.Parser.Segformer) do
      start_supervised!(Camerex.Parser.Segformer)
    end

    :ok
  end

  test "render_layered com o parser real: casal.jpg → {h,w,3} não-vazio" do
    rgb =
      @casal
      |> Evision.imread()
      |> Evision.cvtColor(Evision.Constant.cv_COLOR_BGR2RGB())
      |> Evision.Mat.to_nx(Nx.BinaryBackend)

    {h, w, 3} = Nx.shape(rgb)

    assert {:ok, out} = Photo.render_layered(rgb, layer_colors: Layers.default_colors())

    # mesma resolução da entrada, RGB, e o ATR achou partes (saída acende)
    assert Nx.shape(out) == {h, w, 3}
    assert out |> Nx.sum() |> Nx.to_number() > 0
  end

  test "transparent_bg com o parser real devolve PNG RGBA ({h,w,4})" do
    rgb =
      @casal
      |> Evision.imread()
      |> Evision.cvtColor(Evision.Constant.cv_COLOR_BGR2RGB())
      |> Evision.Mat.to_nx(Nx.BinaryBackend)

    {h, w, 3} = Nx.shape(rgb)

    assert {:ok, out} = Photo.render_layered(rgb, transparent_bg: true)
    assert Nx.shape(out) == {h, w, 4}
  end
end
