defmodule Camerex.Pipeline.PhotoGoldenTest do
  use ExUnit.Case, async: false

  import Camerex.GoldenHelpers

  alias Camerex.Pipeline.Photo

  @moduletag :model
  @moduletag :golden

  @casal Path.expand("exemplos/entrada/casal.jpg")
  @golden_teal Path.expand("exemplos/golden/casal_neon_teal.png")

  setup do
    prev = Application.fetch_env!(:camerex, :segmenter)
    Application.put_env(:camerex, :segmenter, Camerex.Segmenter.Ortex)
    on_exit(fn -> Application.put_env(:camerex, :segmenter, prev) end)

    start_supervised!(Camerex.Segmenter.Ortex)
    :ok
  end

  test "ponta a ponta: casal.jpg → neon teal próximo do golden Python" do
    rgb =
      @casal
      |> Evision.imread()
      |> Evision.cvtColor(Evision.Constant.cv_COLOR_BGR2RGB())
      |> Evision.Mat.to_nx(Nx.BinaryBackend)

    assert {:ok, out} = Photo.render(rgb, preset: "forro-teal")

    # Tolerância E2E mais frouxa que as por etapa (o contrato §6 só define
    # critérios por etapa): a máscara Elixir difere da rembg dentro da
    # própria tolerância dela, e cada pixel de borda deslocado vira diff de
    # escala cheia na linha composta. Os gates estritos de paridade são os
    # goldens por etapa (Tasks 1.2, 1.7, 1.8); este teste prova a
    # integração segment → largest → trace → compose com o modelo real.
    assert_close_to_golden(out, @golden_teal, 2.0 / 255.0, 0.03)
  end
end
