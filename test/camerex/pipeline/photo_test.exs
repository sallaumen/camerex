defmodule Camerex.Pipeline.PhotoTest do
  use ExUnit.Case, async: true

  alias Camerex.Pipeline.Photo

  defp gray_scene(h, w), do: Nx.broadcast(Nx.u8(127), {h, w, 3})

  # rótulos: bloco de roupa (4) em cima, bloco de cabelo (2) embaixo
  defp blocks_labels do
    rows = Nx.iota({40, 40}, axis: 0)
    cols = Nx.iota({40, 40}, axis: 1)
    band = fn r0, r1 -> Nx.logical_and(Nx.greater_equal(rows, r0), Nx.less(rows, r1)) end
    mid_cols = Nx.logical_and(Nx.greater_equal(cols, 8), Nx.less(cols, 32))

    cloth = Nx.logical_and(band.(6, 16), mid_cols)
    hair = Nx.logical_and(band.(24, 34), mid_cols)
    Nx.select(cloth, 4, Nx.select(hair, 2, 0)) |> Nx.as_type(:u8)
  end

  defp chan_max(t, ch), do: t[[.., .., ch]] |> Nx.reduce_max() |> Nx.to_number()

  describe "render_layered/2 (cor-por-parte — único modo)" do
    test "render_layered via parser devolve {h,w,3} (wiring parse→render)" do
      {:ok, layered} = Photo.render_layered(gray_scene(60, 40), [])
      assert Nx.shape(layered) == {60, 40, 3}
    end

    test "render_with_labels com partes que têm borda é não-vazio" do
      out = Photo.render_with_labels(gray_scene(40, 40), blocks_labels(), [])
      assert out |> Nx.sum() |> Nx.to_number() > 0
    end

    test "campo mesclado: roupa fria (teal, verde>vermelho), cabelo quente" do
      layered = Photo.render_with_labels(gray_scene(40, 40), blocks_labels(), [])

      cloth = layered[[6..15, 8..31, ..]]
      hair = layered[[24..33, 8..31, ..]]

      # teal {43,196,178}: verde domina o vermelho
      assert chan_max(cloth, 1) > chan_max(cloth, 0)
      # laranja {255,90,30}: vermelho domina o azul
      assert chan_max(hair, 0) > chan_max(hair, 2)
    end

    test "layer_colors sobrescreve a cor de uma camada (roupa azul)" do
      layered =
        Photo.render_with_labels(gray_scene(40, 40), blocks_labels(),
          layer_colors: %{clothing: {0, 0, 255}}
        )

      cloth = layered[[6..15, 8..31, ..]]
      assert chan_max(cloth, 2) > chan_max(cloth, 0)
    end

    test "preenchimento acende o INTERIOR das partes (que fica escuro sem fill)" do
      labels = blocks_labels()
      sem = Photo.render_with_labels(gray_scene(40, 40), labels, fill: false)

      com =
        Photo.render_with_labels(gray_scene(40, 40), labels,
          fill: true,
          fill_color: 0.6,
          fill_texture: 0.15
        )

      miolo = fn out -> out[[9..12, 14..25, ..]] |> Nx.sum() |> Nx.to_number() end
      assert miolo.(com) > miolo.(sem)
    end

    test "floor: true anexa o piso (mais alto); floor: false não muda as dims" do
      labels = blocks_labels()
      flat = Photo.render_with_labels(gray_scene(40, 40), labels, floor: false)
      floored = Photo.render_with_labels(gray_scene(40, 40), labels, floor: true)

      assert Nx.shape(flat) == {40, 40, 3}
      assert {floored_h, 40, 3} = Nx.shape(floored)
      assert floored_h > 40
    end

    test "bg_opacity acende o fundo com o original atenuado" do
      labels = blocks_labels()
      scene = gray_scene(40, 40)
      canto = fn out -> out[[0..2, 0..2, ..]] |> Nx.sum() |> Nx.to_number() end

      sem = Photo.render_with_labels(scene, labels, bg_opacity: 0.0)
      com = Photo.render_with_labels(scene, labels, bg_opacity: 0.5)

      assert canto.(com) > canto.(sem)
    end

    test "transparent_bg devolve RGBA: traço opaco, fundo bem mais transparente" do
      out = Photo.render_with_labels(gray_scene(40, 40), blocks_labels(), transparent_bg: true)
      assert Nx.shape(out) == {40, 40, 4}

      alpha = out[[.., .., 3]]
      assert Nx.to_number(Nx.reduce_max(alpha)) > 200
      assert Nx.to_number(out[0][0][3]) < 200
    end
  end
end
